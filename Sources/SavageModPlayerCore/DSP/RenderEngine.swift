import Foundation

// Plattformneutraler Renderkern.
//
// Enthält alles, was Live-Wiedergabe, Offline-Render (Quick Look, WAV-Export)
// und CLI gemeinsam nutzen: die Echtzeit-Zustands- und Puffertypen sowie die
// zustandslosen Render- und Sequencer-Helfer. Bewusst frei von AVFoundation und
// Combine, damit derselbe Code unter Linux baut.
//
// Vorher lagen diese Teile in ModPlayerCoordinator.swift und hingen damit an der
// @MainActor/ObservableObject-Klasse und an AVFoundation. Es bleibt EINE Engine:
// ModPlayerCoordinator ruft dieselben Helfer, Live- und Offlinepfad können nicht
// semantisch auseinanderlaufen.

// Haelt den verbleibenden Frame-Zaehler der laufenden Instrument-Vorschau.
// Wird vom Preview-Render-Block (Audio-Thread) heruntergezaehlt — daher dieselbe
// nonisolated(unsafe)-Konvention wie RealtimePlaybackState.
public final class PreviewVoice: Sendable {
    nonisolated(unsafe) public var framesLeft: Int
    public init(framesLeft: Int) { self.framesLeft = framesLeft }
}

public final class RealtimePlaybackState: Sendable {
    // Der neutrale Vorstart steht direkt vor Zeile 0 der ersten Position. Ein
    // festes rowIndex=63 funktionierte nur zufaellig mit klassischen
    // 64-Zeilen-Patterns und spielte bei OpenMPT-Patterns ab 65 Zeilen erst den
    // Pattern-Schwanz und danach dasselbe Pattern noch einmal vollstaendig.
    nonisolated(unsafe) public var position: Int = 0
    nonisolated(unsafe) public var rowIndex: Int = -1
    nonisolated(unsafe) public var tick: Int = 5
    nonisolated(unsafe) public var ticksPerRow: Int = 6
    nonisolated(unsafe) public var bpm: Int = 125
    nonisolated(unsafe) public var outputsPerTick: Double = 0.0
    nonisolated(unsafe) public var outputsUntilNextTick: Double = 0.0
    // OpenMPT kann neben dem klassischen Tracker-Timing auch alternative und
    // moderne BPM-Semantik speichern. MOD/S3M/XM bleiben beim Classic-Default.
    nonisolated(unsafe) public var tempoMode: ITTempoMode = .classic
    nonisolated(unsafe) public var rowsPerBeat: Int = 4
    nonisolated(unsafe) public var restartPosition: Int = 0
    // IT T0x/T1x verändert das Tempo auf den Folgeticks einer Zeile.
    nonisolated(unsafe) public var tempoSlide: Int = 0
    // Wxy verändert die globale IT-Lautstärke auf Folgeticks.
    nonisolated(unsafe) public var globalVolumeSlide: Int = 0
    // S6x verlängert ausschließlich die aktuelle Zeile um x Ticks.
    nonisolated(unsafe) public var rowTickDelay: Int = 0
    
    nonisolated(unsafe) public var positionJump: Int = -1
    nonisolated(unsafe) public var patternBreak: Int = -1
    nonisolated(unsafe) public var patternLoopRow: Int = -1
    nonisolated(unsafe) public var patternDelay: Int = 0
    nonisolated(unsafe) public var patternDelayCounter: Int = 0
    nonisolated(unsafe) public var patternDelaySeen: Bool = false
    
    // New parameters for user controls
    nonisolated(unsafe) public var stereoSeparation: Float = 0.8
    nonisolated(unsafe) public var useInterpolation: Bool = true
    nonisolated(unsafe) public var palClock: Bool = true

    // Globale Lautstärke: 0...64 für MOD/S3M/XM, 0...128 für IT.
    nonisolated(unsafe) public var globalVolume: Float = 64

    // S3M rechnet Perioden gegen die feste ST3-Clock (14317056 Hz) statt
    // gegen die Amiga-Paula-Clock. 0 = kein Override (PAL/NTSC-Schalter gilt).
    nonisolated(unsafe) public var clockRateOverride: Double = 0
    
    // Elapsed frames for timing calculation
    nonisolated(unsafe) public var elapsedFrames: UInt64 = 0
    nonisolated(unsafe) public var waveWriteIndex: Int = 0
    // Eigener, ueber Callback-Grenzen rollender Index fuer das Master-Oszilloskop.
    // (Frueher mit dem Callback-lokalen frame & 127 indiziert — bei Buffern < 128
    // Frames blieb das Ende des Scopes stehen und es ruckelte zwischen Callbacks.)
    nonisolated(unsafe) public var masterWaveWriteIndex: Int = 0
    // Wird im Renderblock gesetzt, wenn der Song hinter die letzte Position laeuft
    // (Wrap auf 0). Der MainActor-Poller liest das Flag und meldet das Songende,
    // damit die UI den loopMode (none/track/playlist) auswerten kann.
    nonisolated(unsafe) public var endReached: Bool = false
    // Exakter Frame der ersten Endtransition. Offline-Renderer koennen damit
    // den letzten 1024er Block auf die musikalische Songlaenge kuerzen.
    nonisolated(unsafe) public var endReachedFrame: UInt64 = .max

    public init() {}
}

public final class RealtimeVUBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<Float>
    public init(pointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
    }
}

public final class RealtimeWaveBuffer: @unchecked Sendable {
    public let channelWavesPointer: UnsafeMutablePointer<Float>
    public let masterWavesPointer: UnsafeMutablePointer<Float>

    public init(channelWaves: UnsafeMutablePointer<Float>, masterWaves: UnsafeMutablePointer<Float>) {
        self.channelWavesPointer = channelWaves
        self.masterWavesPointer = masterWaves
    }
}

// Vorallozierte Capture-Pointer fuer genau EINEN Renderblock. Die Pointer
// werden vor dem Audio-Callback vom Offline-Renderer bereitgestellt und nach
// dessen Rueckkehr synchron in RenderCaptureBlock kopiert.
struct RenderCapture: @unchecked Sendable {
    let stereoLeftPointer: UnsafeMutablePointer<Float>
    let stereoRightPointer: UnsafeMutablePointer<Float>
    let stemsPointer: UnsafeMutablePointer<Float>
    let frameCapacity: Int
    let channelCount: Int
}

// Wertkopie eines fertigen Blocks fuer den Offline-Consumer. Diese Arrays
// entstehen erst nach dem Callback und sind deshalb kein Echtzeit-Arbeitsschritt.
struct RenderCaptureBlock: Sendable {
    let frameCount: Int
    let channelCount: Int
    let stereoLeft: [Float]
    let stereoRight: [Float]
    // Kanal-major: stems[channel * frameCount + frame].
    let stems: [Float]
}

// Stack-Wert eines einzelnen Voice-Frames. Mono-Voices tragen links/rechts
// denselben Wert; Stereo-IT-Samples behalten beide PCM-Seiten bis zum Mixer.
private struct RenderedVoiceFrame {
    let left: Float
    let right: Float
    let mono: Float
    let isStereo: Bool
}

// Wertkopie des Sequencer-Zustands an einer festen Frame-Grenze. Sie enthaelt
// bewusst keine Referenz auf den laufenden Zustand und kein endReached: Die
// Probe setzt dieses Live-/Offline-Abbruchsignal heute nicht.
struct SequencerTraceSnapshot: Sendable, Equatable {
    let frame: Int
    let position: Int
    let pattern: Int
    let row: Int
    let tick: Int
    let speed: Int
    let tempo: Int
    let globalVolume: Float
    let positionJump: Int
    let patternBreak: Int
    let patternLoopRow: Int
    let patternDelay: Int
    let patternDelayCounter: Int
    let tempoSlide: Int
    let globalVolumeSlide: Int
    let rowTickDelay: Int
    let patternDelaySeen: Bool

    init(frame: Int, state: RealtimePlaybackState, mod: Mod) {
        self.frame = frame
        self.position = state.position
        if mod.patternTable.isEmpty {
            self.pattern = -1
        } else {
            let positionIndex = max(0, min(mod.patternTable.count - 1, state.position))
            self.pattern = mod.patternTable[positionIndex]
        }
        self.row = state.rowIndex
        self.tick = state.tick
        self.speed = state.ticksPerRow
        self.tempo = state.bpm
        self.globalVolume = state.globalVolume
        self.positionJump = state.positionJump
        self.patternBreak = state.patternBreak
        self.patternLoopRow = state.patternLoopRow
        self.patternDelay = state.patternDelay
        self.patternDelayCounter = state.patternDelayCounter
        self.tempoSlide = state.tempoSlide
        self.globalVolumeSlide = state.globalVolumeSlide
        self.rowTickDelay = state.rowTickDelay
        self.patternDelaySeen = state.patternDelaySeen
    }
}

struct RenderProbeSample: Sendable {
    let frame: Int
    let position: Int
    let row: Int
    let channelOutputs: [Float]
    let trace: SequencerTraceSnapshot

    init(frame: Int, position: Int, row: Int, channelOutputs: [Float], trace: SequencerTraceSnapshot) {
        self.frame = frame
        self.position = position
        self.row = row
        self.channelOutputs = channelOutputs
        self.trace = trace
    }
}

public enum RenderEngine {
    // Obergrenze der unterstützten Kanäle — bestimmt die Größe der
    // vorallozierten VU-/Waveform-Puffer (S3M erlaubt bis zu 32 Kanäle).
    // IT-Patterns besitzen bis zu 64 logische Kanäle. Die zugehörigen
    // VU-/Scope-Puffer werden wie zuvor einmalig vor dem Audiostart reserviert.
    nonisolated public static let maxChannels = 64

    nonisolated public static let itVoiceCapacity = ITPlaybackVoicePool.voiceCapacity

    // Format-abhängige Kanal-Konfiguration: Panning aus dem Modul, bei S3M
    // zusätzlich das ScreamTracker-Periodenmodell (feinere Perioden, weitere
    // Klemmgrenzen, Effekt-Memory). Muss nach jedem DSPChannel.reset() erneut
    // angewandt werden (reset() stellt die MOD-Defaults wieder her).
    nonisolated static func configure(channels: [DSPChannel], for mod: Mod) {
        if mod.format == .it {
            ITPlaybackVoicePool(mod: mod).configure(voices: channels)
            return
        }
        for (i, ch) in channels.enumerated() {
            if i < mod.channelPannings.count {
                ch.panning = mod.channelPannings[i]
            }
            if mod.format == .s3m {
                ch.s3mMode = true
                ch.periodScale = 4
                ch.periodMin = 64
                ch.periodMax = 32767
            } else if mod.format == .xm {
                // Lineares XM-Frequenzmodell. Perioden reichen bis ~7680 (tiefste
                // Note), darum weite Klemmgrenzen. Amiga-Frequenz-XMs (selten,
                // mod.linearFrequency == false) werden vorerst über dasselbe
                // lineare Modell approximiert — echte Amiga-Periodentabelle ist
                // ein späterer Feinschliff (TODO).
                ch.xmLinearMode = true
                ch.periodMin = 1
                ch.periodMax = 7680
            }
        }
    }

    // Ermittelt Speed/Tempo/Global-Volume an einem Sprungziel (position,row): wendet
    // alle Set-Speed/Tempo/Global-Volume-Befehle vom Songanfang bis dorthin der
    // Reihe nach an. Damit klingt ein Sprung mitten in den Song im RICHTIGEN Tempo
    // (z.B. Starfish: Speed 8 wird in Pattern-Pos 0, Zeile 0 gesetzt). Folgt bewusst
    // KEINEN Pattern-Spruengen (Bxx/Dxx) und rekonstruiert KEINE Per-Kanal-Slides —
    // fuer den linearen Normalfall und Test-Spruenge gedacht.
    nonisolated static func reconstructGlobalParams(_ mod: Mod, toPosition: Int, row: Int)
        -> (speed: Int, bpm: Int, globalVolume: Int) {
        var speed = mod.initialSpeed
        var bpm = mod.initialTempo
        var gvol = mod.initialGlobalVolume
        func scan(_ r: Row) {
            for n in r.notes where n.hasEffect {
                if n.effectId > ModuleEffect.impulseTrackerCommandBase,
                   n.effectId <= ModuleEffect.impulseTrackerCommandBase + 26 {
                    switch n.effectId - ModuleEffect.impulseTrackerCommandBase {
                    case 1:
                        if n.effectData > 0 { speed = n.effectData }
                    case 20:
                        if n.effectData >= 0x20 { bpm = n.effectData }
                    case 22:
                        if n.effectData <= 128 { gvol = n.effectData }
                    default:
                        break
                    }
                } else if n.effectId == 0x0F {
                    if n.effectData >= 1 && n.effectData <= 31 { speed = n.effectData }
                    else if n.effectData >= 32 { bpm = n.effectData }
                } else if n.effectId == ModuleEffect.setSpeed {
                    if n.effectData > 0 { speed = n.effectData }
                } else if n.effectId == ModuleEffect.setTempo {
                    if n.effectData >= 32 { bpm = n.effectData }
                } else if n.effectId == ModuleEffect.globalVolume {
                    gvol = min(64, max(0, n.effectData))
                }
            }
        }
        let lastPos = max(0, min(mod.length - 1, toPosition))
        for p in 0...lastPos {
            let posIndex = max(0, min(mod.patternTable.count - 1, p))
            let patternIndex = mod.patternTable[posIndex]
            guard patternIndex >= 0 && patternIndex < mod.patterns.count else { continue }
            let rows = mod.patterns[patternIndex].rows
            let maxRow = (p == lastPos) ? min(row, rows.count - 1) : rows.count - 1
            guard maxRow >= 0 else { continue }
            for r in 0...maxRow { scan(rows[r]) }
        }
        return (speed, bpm, gvol)
    }

    // internal statt private: ModuleRenderer (WAV-Offline-Render für Export
    // und Quick-Look) nutzt denselben Render-Block wie die Live-Wiedergabe.
    nonisolated static func createRenderBlock(
        state: RealtimePlaybackState,
        vuBuffer: RealtimeVUBuffer,
        waveBuffer: RealtimeWaveBuffer,
        dspChannels: [DSPChannel],
        mod: Mod,
        sampleRate: Double,
        capture: RenderCapture? = nil
    ) -> ModuleRenderBlock {
        // Kanalzahl und Mix-Gain einmalig ableiten: Mehr als 4 Kanäle laufen
        // sonst deutlich heißer in den tanh-Limiter als das klassische
        // 4-Kanal-Bild. Equal-Power-Skalierung sqrt(4/N) statt linearem 4/N:
        // unkorrelierte Kanäle addieren sich in Leistung, nicht in Amplitude —
        // lineares 4/N machte 16-Kanal-S3Ms ~12 dB zu leise (praktisch stumm).
        // Rest-Spitzen fängt der tanh-Limiter weich ab.
        let voiceCount = dspChannels.count
        let logicalChannelCount = mod.format == .it
            ? max(1, min(Self.maxChannels, mod.channelCount))
            : voiceCount
        let itVoicePool = mod.format == .it ? dspChannels.first?.itVoicePool : nil
        let mixGain: Float
        if mod.format == .it {
            // ITs reservieren stets 64 logische Kanäle; deren Zahl darf den Mix
            // nicht pauschal absenken. Stattdessen ist das Headerfeld Mixing
            // Volume (0...128, 64 = neutral) der vorgesehene Masterfaktor.
            let samplePreamp = mod.itProperties?.openMPTExtensions?.samplePreamp
                ?? mod.itProperties?.mixVolume
                ?? 64
            mixGain = Float(samplePreamp) / 64.0
        } else {
            mixGain = voiceCount > 4 ? (4.0 / Float(voiceCount)).squareRoot() : 1.0
        }
        let globalVolumeScale = Float(mod.globalVolumeScale.rawValue)

        return { (frameCount, left, right) in
            let safeFrameCount = Int(frameCount)

            for frame in 0..<safeFrameCount {
                SequencerCore.advanceIfNeeded(
                    state: state,
                    channels: dspChannels,
                    mod: mod,
                    sampleRate: sampleRate
                )

                state.outputsUntilNextTick -= 1.0
                state.elapsedFrames += 1

                // Mischen der Kanäle
                var outL: Float = 0.0
                var outR: Float = 0.0

                var hasSolo = false
                if let itVoicePool {
                    for channel in 0..<itVoicePool.logicalChannelCount {
                        if itVoicePool.patternChannels[channel].isSoloed {
                            hasSolo = true
                            break
                        }
                    }
                } else {
                    for channel in 0..<logicalChannelCount where dspChannels[channel].isSoloed {
                        hasSolo = true
                        break
                    }
                }
                // Globale Lautstärke (S3M Vxx) wirkt auf alle Kanäle gleich.
                let globalGain = state.globalVolume / globalVolumeScale
                let captureStems = capture?.stemsPointer
                let captureFrameCapacity = capture?.frameCapacity ?? 0

                // Roll the wave sample write index
                state.waveWriteIndex = (state.waveWriteIndex + 1) % 32
                let wIdx = state.waveWriteIndex

                // Der sichtbare Kanalpuffer und die Capture-Stems gehören den
                // logischen Kanälen, nicht den bis zu 256 physischen Stimmen.
                for channel in 0..<logicalChannelCount {
                    waveBuffer.channelWavesPointer[channel * 32 + wIdx] = 0.0
                    if let captureStems {
                        captureStems[channel * captureFrameCapacity + frame] = 0.0
                    }
                }

                let renderedVoiceCount = itVoicePool?.usesBackgroundVoices == true
                    ? itVoicePool!.activeVoiceCount
                    : voiceCount
                for renderPosition in 0..<renderedVoiceCount {
                    let voiceIndex = itVoicePool?.usesBackgroundVoices == true
                        ? itVoicePool!.activeVoiceIndex(at: renderPosition)
                        : renderPosition
                    let ch = dspChannels[voiceIndex]
                    let ownerIndex = itVoicePool == nil
                        ? voiceIndex
                        : (ch.itPatternState?.channelIndex ?? -1)
                    guard ownerIndex >= 0, ownerIndex < logicalChannelCount else { continue }
                    let voiceFrame = Self.renderChannelFrame(
                        channel: ch,
                        useInterpolation: state.useInterpolation
                    )
                    let outputSample = voiceFrame.mono * globalGain

                    // Roh-Stem vor Panning, Mix-Gain und Limiter. Bei Capture=nil
                    // bleibt dies nur ein einfacher optionaler Pointer-Check.
                    if let captureStems {
                        captureStems[ownerIndex * captureFrameCapacity + frame] += outputSample
                    }

                    // Mute / Solo logic
                    let ownerState = ch.itPatternState
                    var isChannelMuted = ownerState?.isMuted ?? ch.isMuted
                    if hasSolo && !(ownerState?.isSoloed ?? ch.isSoloed) {
                        isChannelMuted = true
                    }

                    if isChannelMuted {
                        continue
                    }

                    // Alle Vorder-/Hintergrundstimmen eines Besitzers addieren.
                    waveBuffer.channelWavesPointer[ownerIndex * 32 + wIdx] += outputSample

                    // Panning LRRL mit Separation (XM: inkl. Panning-Hüllkurve)
                    let p = ch.effectivePanning
                    let separation = state.stereoSeparation
                    let pEffective = max(0.0, min(1.0, 0.5 + (p - 0.5) * separation))
                    let lGain = 1.0 - pEffective
                    let rGain = pEffective

                    if ch.itSurround {
                        let surround = voiceFrame.isStereo
                            ? (voiceFrame.left + voiceFrame.right) * 0.25 * globalGain
                            : outputSample * 0.5
                        outL += surround * mixGain
                        outR -= surround * mixGain
                    } else {
                        outL += voiceFrame.left * globalGain * lGain * mixGain
                        outR += voiceFrame.right * globalGain * rGain * mixGain
                    }

                }

                for channel in 0..<logicalChannelCount {
                    let absVal = abs(waveBuffer.channelWavesPointer[channel * 32 + wIdx])
                    if absVal > vuBuffer.pointer[channel] {
                        vuBuffer.pointer[channel] = absVal
                    }
                }

                // Float-Stereo unmittelbar vor dem tanh-Limiter sichern.
                if let capture {
                    capture.stereoLeftPointer[frame] = outL
                    capture.stereoRightPointer[frame] = outR
                }
                
                // Soft Limiter (Hyperbolic Tangent) gegen Clipping
                let limitedL = tanh(outL)
                let limitedR = tanh(outR)
                left[frame] = limitedL
                right[frame] = limitedR
                // Master-Scope als echter, ueber Callbacks rollender Ringpuffer
                // (wie waveWriteIndex oben), damit alle 128 Slots stetig gefuellt
                // werden — kein stehender/ruckelnder Tail bei kleinen Buffern.
                state.masterWaveWriteIndex = (state.masterWaveWriteIndex + 1) & 127
                waveBuffer.masterWavesPointer[state.masterWaveWriteIndex] = (limitedL + limitedR) * 0.5
            }
        }
    }

    // IT-Samplevorschau in derselben Stimmung wie die Song-Engine. C-5 spielt
    // genau mit C5Speed; jede Oktave verdoppelt beziehungsweise halbiert die
    // Abspielrate. Der getrennte Helfer macht diese Regression hardwarefrei
    // testbar, obwohl previewInstrument selbst eine AVAudioEngine startet.
    nonisolated static func itPreviewSampleSpeed(
        sample: Sample,
        targetNote: Int,
        linearFrequency: Bool,
        sampleRate: Double
    ) -> Double {
        guard sampleRate > 0 else { return 0 }
        let c5Speed = sample.itProperties?.c5Speed ?? sample.c2spd
        guard c5Speed > 0 else { return 0 }
        if linearFrequency {
            return Double(c5Speed) * pow(2.0, Double(targetNote - 60) / 12.0) / sampleRate
        }
        let period = DSPChannel.itAmigaPeriod(key: targetNote, c5Speed: c5Speed)
        return period > 0 ? 14_317_056.0 / Double(period) / sampleRate : 0
    }

    // Minimaler Render-Block der Vorschau: genau EIN Kanal, mittig gepannt, ohne
    // Sequencer/Effekte. Nach Ablauf des Frame-Budgets gibt er Stille aus.
    nonisolated static func createPreviewRenderBlock(
        channel ch: DSPChannel,
        voice: PreviewVoice,
        useInterpolation: Bool
    ) -> ModuleRenderBlock {
        return { (frameCount, left, right) in
            for frame in 0..<Int(frameCount) {
                var rendered = RenderedVoiceFrame(
                    left: 0, right: 0, mono: 0, isStereo: false
                )
                if voice.framesLeft > 0 {
                    rendered = Self.renderChannelFrame(
                        channel: ch,
                        useInterpolation: useInterpolation
                    )
                    voice.framesLeft -= 1
                }
                // Stereo-Samples bleiben in der Instrumentvorschau räumlich
                // erhalten; tanh schützt wie zuvor weich gegen Clipping.
                left[frame] = tanh(rendered.left)
                right[frame] = tanh(rendered.right)
            }
        }
    }

    // Frisch konfigurierte Offline-Render-Kanäle für ein Modul (Panning +
    // Format-Modell), z.B. für WAV-Export, Render-Probe und Quick-Look.
    nonisolated static func makeRenderChannels(for mod: Mod) -> [DSPChannel] {
        let logicalCount = max(1, min(Self.maxChannels, mod.channelCount))
        let count = mod.format == .it && mod.itProperties?.usesInstruments == true
            ? Self.itVoiceCapacity
            : logicalCount
        let renderChannels = (1...count).map { DSPChannel(index: $0) }
        configure(channels: renderChannels, for: mod)
        return renderChannels
    }

    // Startzustand des Sequencers für ein Modul (Header-Tempo, Global Volume,
    // S3M-Clock). Position 0 / Zeile -1 funktioniert fuer jede Pattern-Laenge;
    // der erste Frame laedt sofort Zeile 0.
    nonisolated static func makeRenderState(for mod: Mod, sampleRate: Double) -> RealtimePlaybackState {
        let state = RealtimePlaybackState()
        state.position = 0
        state.rowIndex = -1
        state.tick = mod.initialSpeed - 1
        state.ticksPerRow = mod.initialSpeed
        state.bpm = mod.initialTempo
        state.tempoMode = mod.itProperties?.openMPTExtensions?.tempoMode ?? .classic
        let headerRowsPerBeat = mod.itProperties.map { $0.patternHighlight & 0xFF } ?? 4
        state.rowsPerBeat = max(
            1,
            mod.itProperties?.openMPTExtensions?.rowsPerBeat
                ?? (headerRowsPerBeat > 0 ? headerRowsPerBeat : 4)
        )
        state.restartPosition = max(
            0,
            min(mod.length - 1, mod.itProperties?.openMPTExtensions?.restartPosition ?? 0)
        )
        SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        state.outputsUntilNextTick = 0.0
        state.globalVolume = Float(mod.initialGlobalVolume)
        state.clockRateOverride = (mod.format == .s3m || mod.format == .it) ? 14317056.0 : 0
        return state
    }

    // Berechnet die musikalische Dauer ueber echte Row-/Tick-Uebergaenge, ohne
    // Samples zu mischen. Statt Millionen einzelner Audioframes werden nur die
    // Tick-Grenzen besucht; der gerundete Frame-Schritt bildet denselben
    // Restwert-Akkumulator wie der Live-/Offline-Renderblock nach.
    nonisolated static func sequencedDuration(
        of mod: Mod,
        sampleRate: Double = 44_100,
        maximumSeconds: Double = 600
    ) -> Double {
        guard mod.length > 0, sampleRate > 0, maximumSeconds > 0 else { return 0 }
        let channels = makeRenderChannels(for: mod)
        let state = makeRenderState(for: mod, sampleRate: sampleRate)
        let maximumFrames = UInt64(sampleRate * maximumSeconds)

        while state.elapsedFrames < maximumFrames {
            SequencerCore.advanceIfNeeded(
                state: state,
                channels: channels,
                mod: mod,
                sampleRate: sampleRate
            )
            if state.endReached { break }

            let remaining = maximumFrames - state.elapsedFrames
            let frameStep = min(
                remaining,
                UInt64(max(1, Int(ceil(state.outputsUntilNextTick))))
            )
            state.outputsUntilNextTick -= Double(frameStep)
            state.elapsedFrames += frameStep
        }
        return Double(state.elapsedFrames) / sampleRate
    }

    // Reihenzahl des Patterns an der gegebenen Song-Position. XM-Patterns haben
    // variable Länge (1..256 Reihen); MOD/S3M sind immer 64. Wird beim Row-Wrap
    // gebraucht, damit ein kurzes Pattern nach seiner letzten echten Reihe
    // umbricht — nicht erst bei fixen 64 (sonst 34 leere Reihen bei 30-Reihen-
    // Patterns → Timing-Drift + weiterlaufende Volume-Slides). Allokationsfrei
    // (nur Array-Index-Zugriffe), damit im Echtzeit-Render-Block nutzbar.
    nonisolated static func patternRowCount(_ mod: Mod, at position: Int) -> Int {
        SequencerCore.patternRowCount(mod, at: position)
    }

    // Globaler Zeilen-Index: Summe der ECHTEN Pattern-Reihen aller Positionen vor
    // `position`, plus `row`. Ersetzt die frühere (position*64 + row)-Annahme, die
    // bei XM mit variablen Pattern-Längen die Elapsed-/Gesamtzeit und die
    // Positionsanzeige verfälschte (z.B. Starfish: 212s statt 178s angezeigt).
    // Nicht im Audio-Thread aufrufen (O(Positionen)); nur bei Seek/Zeitanzeige.
    nonisolated static func cumulativeRows(_ mod: Mod, upTo position: Int, row: Int = 0) -> Int {
        let clamped = max(0, min(mod.length, position))
        var total = 0
        for p in 0..<clamped { total += patternRowCount(mod, at: p) }
        return total + max(0, row)
    }

    // Umkehrung von `cumulativeRows`: globaler Zeilen-Index -> (Position, Zeile)
    // entlang der echten Pattern-Längen. Für den relativen Zeitsprung (+/- s).
    nonisolated static func positionAndRow(_ mod: Mod, forGlobalRow globalRow: Int) -> (position: Int, row: Int) {
        var remaining = max(0, globalRow)
        for p in 0..<max(0, mod.length) {
            let rows = patternRowCount(mod, at: p)
            if remaining < rows { return (p, remaining) }
            remaining -= rows
        }
        let last = max(0, mod.length - 1)
        return (last, max(0, patternRowCount(mod, at: last) - 1))
    }

    @inline(__always)
    nonisolated private static func renderChannelFrame(
        channel ch: DSPChannel,
        useInterpolation: Bool
    ) -> RenderedVoiceFrame {
        // Note-Cut, Key-Off und Stop setzen dieses Flag. Besonders geloopte
        // Samples wuerden ohne den Guard trotz gestoppter Stimme weiterklingen.
        guard ch.playing else { return RenderedVoiceFrame(left: 0, right: 0, mono: 0, isStereo: false) }
        guard let smp = ch.sample, smp.pcm.count > 0, ch.currentPeriod > 0 else {
            return RenderedVoiceFrame(left: 0, right: 0, mono: 0, isStereo: false)
        }
        guard ch.sampleIndex.isFinite, !ch.sampleIndex.isNaN else {
            return RenderedVoiceFrame(left: 0, right: 0, mono: 0, isStereo: false)
        }

        let loop = activeSampleLoop(channel: ch, sample: smp)
        if let loop {
            wrapLoopedSampleIndexIfNeeded(channel: ch, sample: smp, loop: loop)
        }

        let idx = Int(ch.sampleIndex)
        guard idx >= 0, idx < smp.pcm.count else {
            // Ein beendetes One-Shot bleibt beendet. Das ist insbesondere für
            // IT Qxy wichtig: sehr kurze Samples werden nicht später aus dem
            // Nichts erneut gestartet.
            if loop == nil { ch.playing = false }
            return RenderedVoiceFrame(
                left: 0,
                right: 0,
                mono: 0,
                isStereo: smp.rightPCM != nil
            )
        }

        let leftSample = readVoiceSample(
            pcm: smp.pcm,
            channel: ch,
            loop: loop,
            useInterpolation: useInterpolation
        )
        let rightSample: Float
        if let rightPCM = smp.rightPCM {
            rightSample = readVoiceSample(
                pcm: rightPCM,
                channel: ch,
                loop: loop,
                useInterpolation: useInterpolation
            )
        } else {
            rightSample = leftSample
        }

        // sampleDirection ist bei MOD/S3M immer +1 (unverändert); nur XM-Ping-Pong
        // dreht sie auf -1. xmVolumeScale ist bei MOD/S3M 1.0 (Envelope/Fadeout aus).
        ch.sampleIndex += ch.sampleSpeed * ch.sampleDirection
        if let loop {
            wrapLoopedSampleIndexIfNeeded(channel: ch, sample: smp, loop: loop)
        }

        let gain = ch.currentVolume / 64.0 * ch.xmVolumeScale * ch.itVolumeScale
        let filtered = ch.applyITFilter(left: leftSample * gain, right: rightSample * gain)
        return RenderedVoiceFrame(
            left: filtered.0,
            right: filtered.1,
            mono: (filtered.0 + filtered.1) * 0.5,
            isStereo: smp.rightPCM != nil
        )
    }

    @inline(__always)
    // internal statt private: renderProbe im ModPlayerCoordinator liegt seit dem
    // Split in einer anderen Datei, nutzt aber weiterhin denselben Sample-Renderer.
    nonisolated static func renderChannelSample(
        channel ch: DSPChannel,
        useInterpolation: Bool
    ) -> Float {
        renderChannelFrame(channel: ch, useInterpolation: useInterpolation).mono
    }

    // Schmale interne Testnaht für Loop-, Stereo- und Filterdetails. Der
    // Produktionsmixer verwendet weiterhin direkt den privaten Stack-Wert.
    nonisolated static func renderChannelStereoSampleForTesting(
        channel ch: DSPChannel,
        useInterpolation: Bool
    ) -> (left: Float, right: Float) {
        let frame = renderChannelFrame(channel: ch, useInterpolation: useInterpolation)
        return (frame.left, frame.right)
    }

    @inline(__always)
    nonisolated private static func readVoiceSample(
        pcm: [Float],
        channel ch: DSPChannel,
        loop: SampleLoop?,
        useInterpolation: Bool
    ) -> Float {
        if let loop, useInterpolation {
            return ch.getInterpolatedSampleLooped(
                from: pcm,
                index: ch.sampleIndex,
                repeatOffset: loop.start,
                repeatLength: loop.length
            )
        }
        if useInterpolation {
            return ch.getInterpolatedSample(from: pcm, index: ch.sampleIndex)
        }
        return ch.getNearestSample(from: pcm, index: ch.sampleIndex)
    }

    @inline(__always)
    nonisolated private static func activeSampleLoop(
        channel ch: DSPChannel,
        sample smp: Sample
    ) -> SampleLoop? {
        if ch.itMode, !ch.keyReleased,
           let sustain = smp.sustainLoop,
           sustain.type != .none,
           sustain.length > 0 {
            return sustain
        }
        // IT kennt auch absichtlich sehr kurze Loops. Die historische >2-
        // Schwelle des neutralen Modells bleibt für MOD/S3M-Sentinel-Loops
        // erhalten, wird für echte IT-Loopflags aber nicht übernommen.
        if ch.itMode, smp.loopType != .none, smp.loopLength > 0 {
            return SampleLoop(
                start: smp.loopStart,
                length: smp.loopLength,
                type: smp.loopType
            )
        }
        guard smp.isLooped else { return nil }
        return SampleLoop(start: smp.loopStart, length: smp.loopLength, type: smp.loopType)
    }

    nonisolated private static func wrapLoopedSampleIndexIfNeeded(
        channel ch: DSPChannel,
        sample smp: Sample,
        loop: SampleLoop
    ) {
        let frameCount = smp.pcm.count
        let loopStart = max(0, min(loop.start, frameCount - 1))
        let declaredLoopEnd = loop.start + loop.length
        let loopEnd = max(loopStart + 1, min(declaredLoopEnd, frameCount))
        guard loopEnd > loopStart else { return }

        let start = Double(loopStart)
        let end = Double(loopEnd)
        let length = end - start

        if loop.type == .pingpong {
            // Ping-Pong: an den Loop-Grenzen die Richtung umkehren und den
            // Überschuss zurückreflektieren. Spiegel um die Grenze (2·Grenze−pos)
            // OHNE Endpunkt-Duplizierung — wie openmpt/FT2. (Früher `end-1-over`:
            // spiegelte einen Sample zu tief und wiederholte den Endpunkt, was bei
            // langen gehaltenen Ping-Pong-Noten einen Timbre-Drift akkumulierte.)
            if ch.sampleDirection > 0, ch.sampleIndex >= end {
                let over = (ch.sampleIndex - end).truncatingRemainder(dividingBy: length)
                ch.sampleIndex = end - over
                ch.sampleDirection = -1
            } else if ch.sampleDirection < 0, ch.sampleIndex < start {
                let under = (start - ch.sampleIndex).truncatingRemainder(dividingBy: length)
                ch.sampleIndex = start + under
                ch.sampleDirection = 1
            }
        } else if ch.sampleIndex >= end {
            // Vorwärts-Loop: in den Repeat-Bereich zurückfalten. Der alte Swift-
            // Code setzte hart auf repeatOffset und konnte bei genauem Loop-Ende
            // kurzzeitig ausserhalb der gültigen Sampledaten landen.
            ch.sampleIndex = start + (ch.sampleIndex - start).truncatingRemainder(dividingBy: length)
        }
    }
}
