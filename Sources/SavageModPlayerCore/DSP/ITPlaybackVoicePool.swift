// Vorallozierter IT-Stimmenverwalter. Die eigentliche DSP-Stimme bleibt ein
// DSPChannel; dieser Pool trennt ihre Lebensdauer vom logischen Pattern-Kanal.
// Alle Scans laufen über feste Arrays und allozieren im Audio-Thread nichts.
public final class ITPlaybackVoicePool: Sendable {
    public static let voiceCapacity = 256

    public let logicalChannelCount: Int
    public let patternChannels: [ITPatternChannelState]
    public let usesBackgroundVoices: Bool

    private let linearMode: Bool
    private let instrumentMode: Bool
    private let samplePool: [Sample?]
    nonisolated(unsafe) private var nextGeneration: UInt64 = 1
    // Feste Aktivliste statt eines 256er-Scans pro Audio-Frame. Beide Arrays
    // werden beim Pool-Aufbau angelegt und im Echtzeitpfad nur überschrieben.
    nonisolated(unsafe) private var activeVoiceIndices: [Int]
    nonisolated(unsafe) private var voiceIsActive: [Bool]
    nonisolated(unsafe) public private(set) var activeVoiceCount: Int = 0

    public init(mod: Mod) {
        self.logicalChannelCount = max(1, min(64, mod.channelCount))
        self.linearMode = mod.linearFrequency
        self.instrumentMode = mod.itProperties?.usesInstruments ?? false
        self.usesBackgroundVoices = mod.itProperties?.usesInstruments ?? false
        self.samplePool = mod.samplePool
        self.activeVoiceIndices = [Int](repeating: 0, count: Self.voiceCapacity)
        self.voiceIsActive = [Bool](repeating: false, count: Self.voiceCapacity)
        self.patternChannels = (0..<logicalChannelCount).map { channel in
            ITPatternChannelState(
                channelIndex: channel,
                channelVolume: channel < mod.channelVolumes.count ? mod.channelVolumes[channel] : 64,
                channelPanning: channel < mod.channelPannings.count ? mod.channelPannings[channel] : 0.5,
                foregroundVoiceIndex: channel,
                isMuted: channel < mod.channelDisabled.count ? mod.channelDisabled[channel] : false
            )
        }
    }

    // Wird ausschließlich vor dem Audiostart beziehungsweise nach reset()
    // aufgerufen. Die ersten 64 Slots sind die stabilen Kanal-Anker; weitere
    // Slots werden erst bei NNA-Bedarf einem Besitzer zugewiesen.
    public func configure(voices: [DSPChannel]) {
        activeVoiceCount = 0
        for index in voiceIsActive.indices { voiceIsActive[index] = false }
        for (index, voice) in voices.enumerated() {
            configureBase(voice)
            if index < logicalChannelCount {
                let state = patternChannels[index]
                state.foregroundVoiceIndex = index
                voice.itPatternState = state
                voice.panning = state.channelPanning
            }
        }
    }

    // Die Aufrufer iterieren per Index über die feste Aktivliste; dadurch
    // entstehen weder Iterator- noch Closure-Allokationen im Renderpfad.
    @inline(__always)
    public func activeVoiceIndex(at position: Int) -> Int {
        activeVoiceIndices[position]
    }

    @inline(__always)
    private func markActive(_ index: Int) {
        guard index >= 0, index < voiceIsActive.count, !voiceIsActive[index] else { return }
        voiceIsActive[index] = true
        activeVoiceIndices[activeVoiceCount] = index
        activeVoiceCount += 1
    }

    // Abgestorbene One-Shots und geschnittene Stimmen werden einmal pro Tick
    // in-place entfernt. Verzögerte Noten bleiben bis zu ihrem Start erhalten.
    @inline(__always)
    public func compactActiveVoices(_ voices: [DSPChannel]) {
        var write = 0
        for position in 0..<activeVoiceCount {
            let index = activeVoiceIndices[position]
            let voice = voices[index]
            if voice.playing || voice.delayNote >= 0 {
                activeVoiceIndices[write] = index
                write += 1
            } else {
                voiceIsActive[index] = false
            }
        }
        activeVoiceCount = write
    }

    @inline(__always)
    private func configureBase(_ voice: DSPChannel) {
        voice.itMode = true
        voice.itLinearMode = linearMode
        voice.itInstrumentMode = instrumentMode
        voice.itSamplePool = samplePool
        voice.itVoicePool = self
        voice.periodScale = 4
        voice.periodMin = 1
        voice.periodMax = linearMode ? 7680 : 65_535
    }

    @inline(__always)
    private func prepareFreshVoice(
        _ voice: DSPChannel,
        index: Int,
        owner: ITPatternChannelState
    ) {
        voice.reset()
        configureBase(voice)
        voice.itPatternState = owner
        voice.itIsBackgroundVoice = false
        voice.panning = owner.channelPanning
        owner.foregroundVoiceIndex = index
    }

    // Verarbeitet eine Pattern-Zelle für einen logischen Kanal. Sample-Modus,
    // Spezialnoten, instrumentlose Rows und Tone-Portamento bleiben auf der
    // bestehenden Eins-zu-eins-Semantik.
    @inline(__always)
    public func process(
        note: Note,
        logicalChannel: Int,
        voices: [DSPChannel],
        instruments: [Instrument?]
    ) {
        guard logicalChannel >= 0,
              logicalChannel < patternChannels.count,
              !voices.isEmpty else { return }
        let state = patternChannels[logicalChannel]
        let foregroundIndex = max(0, min(voices.count - 1, state.foregroundVoiceIndex))
        let foreground = voices[foregroundIndex]

        applyS7OverrideIfNeeded(
            note: note,
            owner: state,
            foregroundIndex: foregroundIndex,
            voices: voices
        )

        guard instrumentMode,
              note.key >= 0, note.key < 120,
              !isTonePortamento(note) else {
            foreground.playNote(note, instruments: instruments)
            return
        }

        let candidate = note.instrument > 0 && note.instrument < instruments.count
            ? instruments[note.instrument]
            : foreground.instrument
        guard let instrument = candidate,
              let mapping = instrument.noteSampleMapping?.entry(forSourceNote: note.key),
              mapping.sampleID > 0,
              samplePool.indices.contains(mapping.sampleID),
              samplePool[mapping.sampleID] != nil else {
            // Ein leerer IT-Map-Slot ist ein No-Op; playNote hält zugleich die
            // Row-lokalen Effektzustände konsistent.
            foreground.playNote(note, instruments: instruments)
            return
        }

        // Das physische Vordergrundobjekt kann bei NNA wechseln. Carry und eine
        // instrumentlose Folgenoten-Zuordnung gehören jedoch zum logischen
        // Pattern-Kanal und müssen den Objektwechsel überleben.
        let previousInstrumentIndex = foreground.instrument?.index
        let previousVolEnvPos = foreground.volEnvPos
        let previousPanEnvPos = foreground.panEnvPos
        let previousPitchEnvPos = foreground.pitchEnvPos

        applyDuplicateCheck(
            owner: state,
            sourceNote: note.key,
            sampleID: mapping.sampleID,
            instrument: instrument,
            voices: voices
        )

        var targetIndex = foregroundIndex
        if foreground.playing {
            let action = foreground.itNNAOverride
                ?? foreground.instrument?.itProperties?.newNoteAction
                ?? .cut
            if action == .cut {
                foreground.applyITVoiceAction(.cut)
            } else {
                foreground.itIsBackgroundVoice = true
                foreground.detachFromPatternEffects()
                foreground.applyITVoiceAction(action)
                targetIndex = selectVoiceIndex(
                    owner: state,
                    excluding: foregroundIndex,
                    voices: voices
                )
            }
        }

        let target = voices[targetIndex]
        prepareFreshVoice(target, index: targetIndex, owner: state)
        if note.instrument == 0 {
            target.instrument = instrument
        }
        target.playNote(note, instruments: instruments)
        if target.instrument?.index == previousInstrumentIndex {
            if target.instrument?.volumeEnvelope?.carryEnabled == true {
                target.volEnvPos = previousVolEnvPos
            }
            if target.instrument?.panningEnvelope?.carryEnabled == true {
                target.panEnvPos = previousPanEnvPos
            }
            if target.instrument?.pitchEnvelope?.carryEnabled == true {
                target.pitchEnvPos = previousPitchEnvPos
            }
        }
        target.itTriggerNote = note.key
        target.itTriggerSampleID = mapping.sampleID
        target.itTriggerInstrumentID = instrument.index
        target.itVoiceGeneration = nextGeneration
        target.itNNAOverride = nil
        markActive(targetIndex)
        nextGeneration &+= 1
    }

    @inline(__always)
    private func isTonePortamento(_ note: Note) -> Bool {
        if note.volume >= 193 && note.volume <= 202 { return true }
        return note.hasEffect
            && note.effectId == ModuleEffect.impulseTrackerCommand(7)
    }

    @inline(__always)
    private func applyDuplicateCheck(
        owner: ITPatternChannelState,
        sourceNote: Int,
        sampleID: Int,
        instrument: Instrument,
        voices: [DSPChannel]
    ) {
        for position in 0..<activeVoiceCount {
            let voice = voices[activeVoiceIndices[position]]
            guard voice.playing, voice.itPatternState === owner else { continue }
            // IT wertet DCT/DCA je bereits klingender Stimme aus. Das ist bei
            // Instrumentwechseln relevant: Das alte Instrument bestimmt, ob
            // und wie seine eigene Stimme als Duplikat beendet wird.
            guard let properties = voice.instrument?.itProperties,
                  properties.duplicateCheckType != .off,
                  voice.itTriggerInstrumentID == instrument.index else { continue }
            let matches: Bool
            switch properties.duplicateCheckType {
            case .off:
                matches = false
            case .note:
                matches = voice.itTriggerNote == sourceNote
            case .sample:
                matches = voice.itTriggerSampleID == sampleID
            case .instrument:
                matches = voice.itTriggerInstrumentID == instrument.index
            }
            if matches {
                voice.applyITDuplicateAction(properties.duplicateCheckAction)
            }
        }
    }

    // Freie Stimmen gewinnen immer. Danach wird nur eine Hintergrundstimme
    // gestohlen: leiseste zuerst, bei Gleichstand älteste und dann kleinster Index.
    @inline(__always)
    func selectVoiceIndex(
        owner: ITPatternChannelState,
        excluding excludedIndex: Int,
        voices: [DSPChannel]
    ) -> Int {
        let anchor = owner.channelIndex
        if anchor < voices.count, anchor != excludedIndex, !voices[anchor].playing {
            return anchor
        }
        if voices.count > logicalChannelCount {
            for index in logicalChannelCount..<voices.count
            where index != excludedIndex && !voices[index].playing {
                return index
            }
        }

        var bestIndex = -1
        var bestLevel = Float.greatestFiniteMagnitude
        var bestGeneration = UInt64.max
        for index in 0..<voices.count where index != excludedIndex {
            let voice = voices[index]
            guard voice.itIsBackgroundVoice else { continue }
            let level = max(0, voice.currentVolume)
                * voice.xmVolumeScale
                * voice.itVolumeScale
                * voice.envVolumeFactor
                * (Float(voice.fadeVolume) / 65_536.0)
            if level < bestLevel
                || (level == bestLevel && voice.itVoiceGeneration < bestGeneration)
                || (level == bestLevel && voice.itVoiceGeneration == bestGeneration && index < bestIndex) {
                bestIndex = index
                bestLevel = level
                bestGeneration = voice.itVoiceGeneration
            }
        }
        if bestIndex >= 0 { return bestIndex }

        // Nur beim theoretisch vollständig mit Vordergrundstimmen belegten Pool:
        // deterministisch den ältesten nicht ausgeschlossenen Slot verwenden.
        var fallback = excludedIndex == 0 ? min(1, voices.count - 1) : 0
        var fallbackGeneration = voices[fallback].itVoiceGeneration
        for index in 0..<voices.count where index != excludedIndex {
            if voices[index].itVoiceGeneration < fallbackGeneration {
                fallback = index
                fallbackGeneration = voices[index].itVoiceGeneration
            }
        }
        return fallback
    }

    @inline(__always)
    private func applyS7OverrideIfNeeded(
        note: Note,
        owner: ITPatternChannelState,
        foregroundIndex: Int,
        voices: [DSPChannel]
    ) {
        guard note.hasEffect,
              note.effectId == ModuleEffect.impulseTrackerCommand(19),
              note.effectHigh == 7 else { return }
        switch note.effectLow {
        case 0...2:
            let action: NewNoteAction = note.effectLow == 0 ? .cut
                : (note.effectLow == 1 ? .noteOff : .noteFade)
            for (index, voice) in voices.enumerated()
            where index != foregroundIndex
                && voice.playing
                && voice.itPatternState === owner
                && voice.itIsBackgroundVoice {
                voice.applyITVoiceAction(action)
            }
        case 3...6:
            voices[foregroundIndex].itNNAOverride = NewNoteAction(rawValue: note.effectLow - 3)
        default:
            break
        }
    }
}
