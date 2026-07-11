import Foundation

public final class DSPChannel: Sendable {
    public let channelIndex: Int

    // ProTracker-Sinustabelle (32 Eintraege, Betrag der ersten Halbwelle, Peak 255).
    // Vibrato/Tremolo nutzen sie wie das Original: Index 0..63, untere 5 Bit
    // adressieren die Tabelle, ab Index 32 wird das Vorzeichen invertiert.
    // Vibrato-Delta = tabelle*depth/128 (Period), Tremolo = tabelle*depth/64 (Volume).
    static let ptSineTable: [Float] = [
        0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
        255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24
    ]

    // ScreamTracker-3-Periodentabelle für Oktave 0 (Index = Halbton C..B).
    // Die Werte sind 4x so fein wie Amiga-Perioden; höhere Oktaven halbieren.
    static let s3mPeriodTable: [Double] = [
        1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907
    ]

    // ST3-Periodenformel: Halbton-Key (Oktave*12 + Note) + Instrument-C2Spd
    // -> Period. Abspielfrequenz ist später 14317056 / Period (ST3-Clock).
    public static func s3mPeriod(key: Int, c2spd: Int) -> Float {
        guard key >= 0, key < 120, c2spd > 0 else { return 0 }
        let base = s3mPeriodTable[key % 12] * 16.0
        let octaveDivisor = Double(1 << (key / 12))
        return Float(8363.0 * (base / octaveDivisor) / Double(c2spd))
    }

    // XM lineare Periode: realNote (0-basiert, C-4 = 48) + signed Finetune
    // (-128..127). period = 7680 - realNote*64 - finetune/2. Abspielfrequenz ist
    // später 8363 * 2^((4608 - period) / 768) (siehe performTick, xmLinearMode).
    // Verifiziert: realNote 48, finetune 0 -> period 4608 -> 8363 Hz (C-4).
    public static func xmLinearPeriod(realNote: Int, finetune: Int) -> Float {
        return Float(7680 - realNote * 64) - Float(finetune) / 2.0
    }

    // IT linear: 64 Periodeneinheiten pro Halbton, C-5 liegt bei 3840. Die
    // Sample-C5Speed fließt erst bei der Frequenzberechnung ein.
    public static func itLinearPeriod(key: Int) -> Float {
        guard key >= 0, key < 120 else { return 0 }
        return Float(7680 - key * 64)
    }

    // IT Amiga-Slides arbeiten auf echten Perioden. Aus C5Speed und Zielnote
    // entsteht die Periode gegen die IT/ST3-Clock von 14.317056 MHz.
    public static func itAmigaPeriod(key: Int, c5Speed: Int) -> Float {
        guard key >= 0, key < 120, c5Speed > 0 else { return 0 }
        let frequency = Double(c5Speed) * pow(2.0, Double(key - 60) / 12.0)
        return Float(14_317_056.0 / frequency)
    }

    // Nonisolated unsafe to bypass strict concurrency warnings inside lock-free real-time audio thread
    // instrument = aktuelles Instrument (für XM-Hüllkurven/Fadeout/Auto-Vibrato).
    // sample = das gerade klingende Sample (PCM/Loop/Tuning) — bei XM per Keymap
    // aus dem Instrument gewählt, bei MOD/S3M immer dessen einziges Sample.
    nonisolated(unsafe) public var instrument: Instrument?
    nonisolated(unsafe) public var sample: Sample?
    nonisolated(unsafe) public var playing: Bool = false
    nonisolated(unsafe) public var period: Float = 0
    nonisolated(unsafe) public var currentPeriod: Float = 0
    nonisolated(unsafe) public var portamentoSpeed: Float = 0
    nonisolated(unsafe) public var periodDelta: Float = 0
    
    // Vibrato
    nonisolated(unsafe) public var vibrato: Bool = false
    nonisolated(unsafe) public var vibratoDepth: Float = 0
    nonisolated(unsafe) public var vibratoSpeed: Float = 0
    nonisolated(unsafe) public var vibratoIndex: Float = 0
    
    // Tremolo
    nonisolated(unsafe) public var tremolo: Bool = false
    nonisolated(unsafe) public var tremoloDepth: Float = 0
    nonisolated(unsafe) public var tremoloSpeed: Float = 0
    nonisolated(unsafe) public var tremoloIndex: Float = 0
    
    // Volumesteuerung
    nonisolated(unsafe) public var volume: Float = 64
    nonisolated(unsafe) public var currentVolume: Float = 64
    nonisolated(unsafe) public var volumeSlide: Float = 0
    // XM-Volume-Column Volume-Slide pro Tick (getrennt vom Effekt-Spalten-Slide).
    nonisolated(unsafe) public var volColVolSlide: Float = 0
    // XM Panning-Slide pro Tick in 0..255-Einheiten (Volume-Column D/E oder Pxy).
    nonisolated(unsafe) public var panSlide: Float = 0
    
    // Custom Panning (0..1.0, 0.5 = Center)
    nonisolated(unsafe) public var panning: Float = 0.5
    
    // Sample Playback
    nonisolated(unsafe) public var sampleIndex: Double = 0.0
    nonisolated(unsafe) public var sampleSpeed: Double = 0.0
    // 9xx-Offset-Memory: 900 (ohne Parameter) wiederholt den letzten Offset.
    nonisolated(unsafe) public var sampleOffsetMemory: Double = 0.0
    
    // ProTracker loop / delay states
    nonisolated(unsafe) public var patternLoopStartRow: Int = 0
    nonisolated(unsafe) public var patternLoopCount: Int = -1
    nonisolated(unsafe) public var cutNoteTick: Int = -1
    // XM Kxx: Key-Off soll auf diesem Tick ausgelöst werden (-1 = inaktiv).
    nonisolated(unsafe) public var keyOffTick: Int = -1
    nonisolated(unsafe) public var retrigger: Int = 0
    // IT Qxy verändert bei jedem Retrigger zusätzlich die Lautstärke über x.
    nonisolated(unsafe) public var retriggerVolumeMode: Int = 0
    // -1 bedeutet: kein EDx-Delay aktiv. 0 ist ein echter Tick und darf
    // leere Rows nicht versehentlich wie eine verzögerte Note auslösen.
    nonisolated(unsafe) public var delayNote: Int = -1
    // Arpeggio als Skalare statt [Int]? — eine Array-Allokation pro 0xy-Note lief
    // sonst direkt im Echtzeit-Audio-Thread (verboten laut AGENTS.md).
    nonisolated(unsafe) public var arpActive: Bool = false
    nonisolated(unsafe) public var arpX: Int = 0
    nonisolated(unsafe) public var arpY: Int = 0
    
    // Mute and Solo
    nonisolated(unsafe) public var isMuted: Bool = false
    nonisolated(unsafe) public var isSoloed: Bool = false

    // ---- Format-Konfiguration (vom Coordinator pro Modul gesetzt) ----
    // S3M-Modus: Perioden aus Key+C2Spd, Effekt-Memory, ST3-Clock.
    nonisolated(unsafe) public var s3mMode: Bool = false
    // XM-Modus mit linearer Frequenztabelle: Periode aus Halbton (Key +
    // relativeNote) + Finetune, Frequenz exponentiell statt clockRate/Periode.
    nonisolated(unsafe) public var xmLinearMode: Bool = false
    // IT benutzt einen eigenen logischen Kanalzustand. `itLinearMode` wählt
    // zwischen logarithmischer linearer Periode und klassischer Amiga-Periode.
    nonisolated(unsafe) public var itMode: Bool = false
    nonisolated(unsafe) public var itLinearMode: Bool = false
    nonisolated(unsafe) public var itInstrumentMode: Bool = false
    nonisolated(unsafe) public var itPatternState: ITPatternChannelState?
    nonisolated(unsafe) public var itVoicePool: ITPlaybackVoicePool?
    nonisolated(unsafe) public var itIsBackgroundVoice: Bool = false
    nonisolated(unsafe) public var itTriggerNote: Int = -1
    nonisolated(unsafe) public var itTriggerSampleID: Int = 0
    nonisolated(unsafe) public var itTriggerInstrumentID: Int = 0
    nonisolated(unsafe) public var itVoiceGeneration: UInt64 = 0
    nonisolated(unsafe) public var itNNAOverride: NewNoteAction?
    // IT-Instrumente referenzieren Samples global per 1-basierter ID. Alle
    // Kanäle teilen den vorab aufgebauten Array-Puffer per Swift-COW.
    nonisolated(unsafe) public var itSamplePool: [Sample?] = []
    // XM/IT: Note wurde losgelassen. Gibt den Sustain-Bereich frei.
    nonisolated(unsafe) public var keyReleased: Bool = false
    // IT wertet Key-Off für Hüllkurven mit dem Zustand des vorherigen Ticks aus.
    nonisolated(unsafe) public var itEnvelopeReleased: Bool = false
    // IT Note Fade läuft unabhängig vom Key-Off: Fade gibt den Sustain nicht frei.
    nonisolated(unsafe) public var noteFadeActive: Bool = false

    // ---- Instrument-Voice-Zustand (Hüllkurven / Fadeout / Auto-Vibrato) ----
    // Volume-/Panning-Envelope-Position (x-Achse = Ticks ab Note-Start).
    nonisolated(unsafe) public var volEnvPos: Int = 0
    nonisolated(unsafe) public var panEnvPos: Int = 0
    nonisolated(unsafe) public var pitchEnvPos: Int = 0
    // Aktueller Envelope-Volume-Faktor 0..1 (1 wenn keine Volume-Hüllkurve).
    nonisolated(unsafe) public var envVolumeFactor: Float = 1.0
    // Aktueller Panning-Envelope-Wert 0..64 (32 = neutral/Mitte).
    nonisolated(unsafe) public var panEnvValue: Float = 32
    // IT-Pitch-Hüllkurve: 32 ist neutral, 0...64 entspricht -32...+32.
    nonisolated(unsafe) public var pitchEnvValue: Float = 32
    // Ob das aktive Instrument eine Panning-Hüllkurve hat (steuert effectivePanning).
    nonisolated(unsafe) public var hasPanEnvelope: Bool = false
    // Fade-Volume 0..65536. Sinkt nach Key-Off pro Tick um instrument.fadeout.
    nonisolated(unsafe) public var fadeVolume: Int = 65536
    // Auto-Vibrato-Zustand (Phase 0..255, Amplitude als depth<<8, Sweep-Schritt).
    nonisolated(unsafe) public var autoVibPos: Int = 0
    nonisolated(unsafe) public var autoVibAmp: Int = 0
    nonisolated(unsafe) public var autoVibSweepStep: Int = 0
    // Ping-Pong-Sample-Richtung: +1 vorwärts, -1 rückwärts.
    nonisolated(unsafe) public var sampleDirection: Double = 1.0

    // Render-Skalierung der Instrument-Voice: Envelope-Volume * Fadeout. Der
    // historische Name bleibt API-kompatibel für die XM-Tests.
    public var xmVolumeScale: Float {
        (xmLinearMode || (itMode && itInstrumentMode))
            ? envVolumeFactor * (Float(fadeVolume) / 65536.0)
            : 1.0
    }

    // IT-Sample-Global-Volume und Channel Volume sind unabhängig von der
    // normalen 0...64-Voice-Lautstärke. Andere Formate bleiben exakt bei 1.
    public var itVolumeScale: Float {
        guard itMode else { return 1.0 }
        let sampleGlobal = Float(sample?.itProperties?.globalVolume ?? 64) / 64.0
        let instrumentGlobal = Float(instrument?.itProperties?.globalVolume ?? 128) / 128.0
        let channelGlobal = (itPatternState?.channelVolume ?? 64) / 64.0
        return sampleGlobal * instrumentGlobal * channelGlobal
    }

    // Effektives Panning inkl. XM-/IT-Panning-Hüllkurve. Ohne Instrument-
    // Hüllkurve bleibt das rohe Kanal-Panning unverändert.
    public var effectivePanning: Float {
        guard (xmLinearMode || (itMode && itInstrumentMode)), hasPanEnvelope else { return panning }
        if itMode, itInstrumentMode {
            let pan = panning * 256.0
            let displacement = panEnvValue - 32.0
            let finalPan = pan >= 128.0
                ? pan + displacement * (256.0 - pan) / 32.0
                : pan + displacement * pan / 32.0
            return max(0.0, min(1.0, finalPan / 256.0))
        }
        let pan = panning * 255.0
        let finalPan = pan + (panEnvValue - 32.0) * (128.0 - abs(pan - 128.0)) / 32.0
        return max(0.0, min(1.0, finalPan / 255.0))
    }
    // Skaliert Vibrato-Deltas: S3M-Perioden sind 4x feiner als Amiga-Perioden.
    nonisolated(unsafe) public var periodScale: Float = 1
    // Skaliert den Portamento-Slide-Schritt (1xx/2xx/3xx). Amiga (MOD) = 1;
    // S3M und XM haben 4x feinere Perioden (64 Einheiten/Halbton) -> ×4.
    // Getrennt von periodScale gehalten (Vibrato-Skalierung ist separat/ungeklärt).
    private var portaScale: Float { (s3mMode || xmLinearMode || itMode) ? 4.0 : 1.0 }
    // Perioden-Klemmgrenzen (Amiga: 113..856, S3M: 64..32767).
    nonisolated(unsafe) public var periodMin: Float = 113
    nonisolated(unsafe) public var periodMax: Float = 856

    // ---- S3M-spezifische Effektzustände ----
    // Tremor (Ixy): tremorOn Ticks hörbar, dann tremorOff Ticks stumm.
    nonisolated(unsafe) public var tremorActive: Bool = false
    nonisolated(unsafe) public var tremorOn: Int = 1
    nonisolated(unsafe) public var tremorOff: Int = 1
    nonisolated(unsafe) public var tremorCount: Int = 0
    // ST3 teilt EIN Parameter-Memory pro Kanal über D/E/F/I (Parameter 0 =
    // letzten Wert wiederholen).
    nonisolated(unsafe) public var s3mEffectMemory: Int = 0
    // FT2/XM-Effekt-Memory pro Kanal: 100/200/A00/500/600 wiederholen den
    // letzten passenden Nicht-Null-Parameter. Starfish nutzt 105,100,100,100
    // als Pitch-Rampe am Ende des ersten Patterns.
    nonisolated(unsafe) public var xmPortaUpMemory: Int = 0
    nonisolated(unsafe) public var xmPortaDownMemory: Int = 0
    nonisolated(unsafe) public var xmVolumeSlideMemory: Int = 0
    
    // Temp-Zustände für Ticks
    nonisolated(unsafe) public var setInstrument: Instrument?
    nonisolated(unsafe) public var setSample: Sample?
    nonisolated(unsafe) public var setVolume: Float?
    nonisolated(unsafe) public var setPanning: Float?
    nonisolated(unsafe) public var setPeriod: Float?
    nonisolated(unsafe) public var setCurrentPeriod: Bool = false
    nonisolated(unsafe) public var setSampleIndex: Double?
    nonisolated(unsafe) public var portamento: Bool = false
    
    public init(index: Int) {
        self.channelIndex = index
        // Amiga Standard-Panning LRRL (0 = Left, 1.0 = Right)
        // Kanal 1 und 4 sind links (0.1), 2 und 3 sind rechts (0.9) mit etwas Bleed
        self.panning = (index == 1 || index == 4) ? 0.1 : 0.9
    }
    
    public func reset() {
        instrument = nil
        sample = nil
        playing = false
        period = 0
        currentPeriod = 0
        portamentoSpeed = 0
        periodDelta = 0
        vibrato = false
        vibratoDepth = 0
        vibratoSpeed = 0
        vibratoIndex = 0
        tremolo = false
        tremoloDepth = 0
        tremoloSpeed = 0
        tremoloIndex = 0
        volume = 64
        currentVolume = 64
        volumeSlide = 0
        volColVolSlide = 0
        panSlide = 0
        sampleIndex = 0.0
        sampleSpeed = 0.0
        sampleOffsetMemory = 0.0
        patternLoopStartRow = 0
        patternLoopCount = -1
        cutNoteTick = -1
        keyOffTick = -1
        retrigger = 0
        retriggerVolumeMode = 0
        delayNote = -1
        arpActive = false
        arpX = 0
        arpY = 0
        isMuted = false
        isSoloed = false

        s3mMode = false
        xmLinearMode = false
        itMode = false
        itLinearMode = false
        itInstrumentMode = false
        itPatternState = nil
        itVoicePool = nil
        itIsBackgroundVoice = false
        itTriggerNote = -1
        itTriggerSampleID = 0
        itTriggerInstrumentID = 0
        itVoiceGeneration = 0
        itNNAOverride = nil
        itSamplePool = []
        keyReleased = false
        itEnvelopeReleased = false
        noteFadeActive = false
        volEnvPos = 0
        panEnvPos = 0
        pitchEnvPos = 0
        envVolumeFactor = 1.0
        panEnvValue = 32
        pitchEnvValue = 32
        hasPanEnvelope = false
        fadeVolume = 65536
        autoVibPos = 0
        autoVibAmp = 0
        autoVibSweepStep = 0
        sampleDirection = 1.0
        periodScale = 1
        periodMin = 113
        periodMax = 856
        tremorActive = false
        tremorOn = 1
        tremorOff = 1
        tremorCount = 0
        s3mEffectMemory = 0
        xmPortaUpMemory = 0
        xmPortaDownMemory = 0
        xmVolumeSlideMemory = 0

        setInstrument = nil
        setSample = nil
        setVolume = nil
        setPanning = nil
        setPeriod = nil
        setCurrentPeriod = false
        setSampleIndex = nil
        portamento = false
    }
    
    // PCM ist bereits normalisiert (int8/256 bzw. int16/65536), daher hier kein
    // /256 mehr — direkt lesen. Signatur [Float] statt [Int8] (Float-Engine).
    @inline(__always)
    public func getNearestSample(from pcm: [Float], index: Double) -> Float {
        let size = pcm.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }

        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }
        return pcm[idx]
    }

    @inline(__always)
    public func getInterpolatedSample(from pcm: [Float], index: Double) -> Float {
        let size = pcm.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }

        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }

        let sampleCurrent = pcm[idx]
        let frac = Float(index - Double(idx))

        let nextIdx = idx + 1
        if nextIdx < size {
            let sampleNext = pcm[nextIdx]
            return sampleCurrent + frac * (sampleNext - sampleCurrent)
        } else {
            return sampleCurrent
        }
    }

    @inline(__always)
    public func getInterpolatedSampleLooped(from pcm: [Float], index: Double, repeatOffset: Int, repeatLength: Int) -> Float {
        let size = pcm.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }

        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }

        let sampleCurrent = pcm[idx]
        let frac = Float(index - Double(idx))

        var nextIdx = idx + 1
        let loopEnd = repeatOffset + repeatLength
        if nextIdx >= loopEnd {
            nextIdx = repeatOffset
        }

        if nextIdx >= 0 && nextIdx < size {
            let sampleNext = pcm[nextIdx]
            return sampleCurrent + frac * (sampleNext - sampleCurrent)
        } else {
            return sampleCurrent
        }
    }
    
    public func playNote(_ note: Note, instruments: [Instrument?]) {
        let previousInstrumentIndex = self.instrument?.index
        self.setInstrument = nil
        self.setSample = nil
        self.setVolume = nil
        self.setPanning = nil
        self.setPeriod = nil
        self.delayNote = -1
        self.cutNoteTick = -1
        self.keyOffTick = -1

        var hasSetInstrument = false
        var hasSetSample = false
        var playbackKey = note.key
        if note.instrument > 0 {
            hasSetInstrument = true
            if note.instrument < instruments.count, let inst = instruments[note.instrument] {
                self.setInstrument = inst
                if !(itMode && itInstrumentMode) {
                    // XM wählt hier über seine 96er-Keymap; Ein-Sample-Formate
                    // greifen unverändert auf Sample 0 zu.
                    let noteForMap = (note.key >= 0 && note.key < 96) ? note.key : 0
                    self.setSample = inst.sample(forNote: noteForMap)
                    hasSetSample = true
                    self.setVolume = Float(self.setSample?.volume ?? 0)
                    if itMode, let defaultPan = self.setSample?.itProperties?.defaultPanning {
                        self.setPanning = Float(defaultPan) / 64.0
                    }
                }
            } else {
                self.setInstrument = nil
                self.setSample = nil
                self.setVolume = 0
            }
        }

        // IT-Instrumente besitzen eine globale 120er Notemap. Die Zielnote kann
        // transponieren; Sample 0 bedeutet ausdrücklich „kein Sample“.
        if itMode, itInstrumentMode, note.key >= 0, note.key < 120 {
            let mappedInstrument = self.setInstrument ?? self.instrument
            if let inst = mappedInstrument,
               let entry = inst.noteSampleMapping?.entry(forSourceNote: note.key) {
                let sampleID = entry.sampleID
                if sampleID > 0,
                   itSamplePool.indices.contains(sampleID),
                   let mappedSample = itSamplePool[sampleID] {
                    playbackKey = entry.targetNote
                    hasSetSample = true
                    self.setSample = mappedSample
                    self.setVolume = Float(mappedSample.volume)
                    if let defaultPan = inst.itProperties?.defaultPanning {
                        self.setPanning = Float(defaultPan) / 64.0
                    } else if let defaultPan = self.setSample?.itProperties?.defaultPanning {
                        self.setPanning = Float(defaultPan) / 64.0
                    }
                } else {
                    // Leere/ungültige Map-Slots sind in IT-Instrument-Modus
                    // echte No-Ops: die laufende Vordergrundstimme bleibt stehen.
                    playbackKey = -1
                    hasSetInstrument = false
                    self.setInstrument = nil
                    self.setSample = nil
                    self.setVolume = nil
                    self.setPanning = nil
                }
            } else {
                playbackKey = -1
                hasSetInstrument = false
                self.setSample = nil
                self.setVolume = nil
            }
        }

        self.setSampleIndex = nil
        self.setCurrentPeriod = false

        if note.key == Note.keyCut {
            // Note Cut stoppt die Stimme ohne Release oder Fadeout.
            self.playing = false
            if itMode, itInstrumentMode { self.fadeVolume = 0 }
        } else if note.key == Note.keyFade {
            // Im Sample-Modus wirkungslos; Instrument-Modus startet den Fade,
            // ohne den Sustain-Bereich freizugeben.
            if itMode, itInstrumentMode { self.noteFadeActive = true }
        } else if note.key == Note.keyOff {
            self.keyReleased = true
            if itMode, itInstrumentMode {
                // IT startet den Instrument-Fade sofort ohne Volume-Envelope;
                // bei geloopter Volume-Envelope ebenfalls ab dem Release.
                if self.instrument?.volumeEnvelope == nil
                    || (self.instrument?.volumeEnvelope?.loopEnabled == true
                        && (self.instrument?.fadeout ?? 0) > 0) {
                    self.noteFadeActive = true
                }
            } else if self.instrument?.volumeEnvelope == nil {
                // FT2-Quirk: Ohne aktive Volume-Hüllkurve stoppt Key-Off sofort.
                self.playing = false
            }
        } else if note.period > 0 {
            // Finetune vom aktiven Sample (neu getriggert oder laufend).
            let activeSample = self.setSample ?? self.sample
            let finetune = Float(activeSample?.finetune ?? 0)
            // Gleiche Finetune-Näherung wie im HTML-Worklet: Period minus
            // signed nibble. Das hält Swift und Browser klanglich synchron.
            self.setPeriod = Float(note.period) - finetune
            self.setCurrentPeriod = true
            self.setSampleIndex = 0.0
            self.keyReleased = false
            self.noteFadeActive = false
        } else if playbackKey >= 0 {
            let activeSample = self.setSample ?? self.sample
            if itLinearMode {
                self.setPeriod = DSPChannel.itLinearPeriod(key: playbackKey)
            } else if itMode {
                self.setPeriod = DSPChannel.itAmigaPeriod(
                    key: playbackKey,
                    c5Speed: activeSample?.itProperties?.c5Speed ?? activeSample?.c2spd ?? 8363
                )
            } else if xmLinearMode {
                // XM: Periode aus (Key + Sample-relativeNote) + Sample-Finetune,
                // lineares Modell.
                let realNote = playbackKey + (activeSample?.relativeNote ?? 0)
                self.setPeriod = DSPChannel.xmLinearPeriod(realNote: realNote, finetune: activeSample?.finetune ?? 0)
            } else {
                // S3M: Period aus Halbton-Key + C2Spd des (neuen oder laufenden)
                // Samples berechnen.
                self.setPeriod = DSPChannel.s3mPeriod(key: playbackKey, c2spd: activeSample?.c2spd ?? 8363)
            }
            self.setCurrentPeriod = true
            self.setSampleIndex = 0.0
            self.keyReleased = false
            self.noteFadeActive = false
        }

        // S3M-Volume-Column überschreibt die Instrument-Default-Lautstärke.
        if note.volume >= 0, !itMode {
            self.setVolume = Float(min(64, note.volume))
        }

        self.applyEffect(note: note)

        // XM-Volume-Column (zweite Effektspalte) NACH dem Haupteffekt auswerten,
        // damit sie bei Lautstärke/Panning Vorrang hat (FT2-Verhalten).
        if xmLinearMode { self.applyXMVolumeColumn(note.volCmd) }
        if itMode { self.applyITVolumeColumn(note.volume) }

        if self.delayNote > 0 {
            return
        }
        
        if hasSetInstrument {
            self.instrument = self.setInstrument
        }
        if hasSetSample || (hasSetInstrument && !(itMode && itInstrumentMode)) {
            self.sample = self.setSample
        }

        if let vol = self.setVolume {
            self.volume = vol
            self.currentVolume = vol
        }
        if let pan = self.setPanning {
            self.panning = max(0, min(1, pan))
            if itMode { self.itPatternState?.channelPanning = self.panning }
        }
        
        if let per = self.setPeriod {
            self.period = per
        }
        
        if self.setCurrentPeriod {
            self.currentPeriod = self.period
        }
        
        if let idx = self.setSampleIndex {
            self.sampleIndex = idx
            self.playing = !(itMode && itInstrumentMode) || self.sample != nil
        }

        // Bei echtem Retrigger die Instrument-Voice initialisieren. IT-Carry
        // erhält die jeweilige Envelope-Position nur beim selben Instrument.
        if (xmLinearMode || (itMode && itInstrumentMode)), self.setSampleIndex != nil {
            let mayCarry = itMode && itInstrumentMode
                && previousInstrumentIndex == self.instrument?.index
            initInstrumentVoice(preserveCarry: mayCarry)
        }
    }

    // Eine NNA-Hintergrundstimme behält Sample, Envelope, Fade und Filter,
    // erhält aber ab jetzt keine Pattern-Effekte mehr.
    @inline(__always)
    public func detachFromPatternEffects() {
        volumeSlide = 0
        volColVolSlide = 0
        panSlide = 0
        periodDelta = 0
        portamento = false
        vibrato = false
        tremolo = false
        arpActive = false
        retrigger = 0
        delayNote = -1
        cutNoteTick = -1
        keyOffTick = -1
        tremorActive = false
    }

    @inline(__always)
    public func applyITVoiceAction(_ action: NewNoteAction) {
        switch action {
        case .cut:
            playing = false
            fadeVolume = 0
        case .continuePlaying:
            break
        case .noteOff:
            keyReleased = true
            if instrument?.volumeEnvelope == nil
                || (instrument?.volumeEnvelope?.loopEnabled == true
                    && (instrument?.fadeout ?? 0) > 0) {
                noteFadeActive = true
            }
        case .noteFade:
            noteFadeActive = true
        }
    }

    @inline(__always)
    public func applyITDuplicateAction(_ action: DuplicateCheckAction) {
        switch action {
        case .cut: applyITVoiceAction(.cut)
        case .noteOff: applyITVoiceAction(.noteOff)
        case .noteFade: applyITVoiceAction(.noteFade)
        }
    }

    // XM-/IT-Voice bei Note-Trigger initialisieren. IT-Carry kann einzelne
    // Envelope-Positionen erhalten; XM setzt wie bisher alles auf Tick 0.
    private func initInstrumentVoice(preserveCarry: Bool) {
        if !(preserveCarry && instrument?.volumeEnvelope?.carryEnabled == true) {
            volEnvPos = 0
        }
        if !(preserveCarry && instrument?.panningEnvelope?.carryEnabled == true) {
            panEnvPos = 0
        }
        if !(preserveCarry && instrument?.pitchEnvelope?.carryEnabled == true) {
            pitchEnvPos = 0
        }
        fadeVolume = 65536
        noteFadeActive = false
        keyReleased = false
        itEnvelopeReleased = false
        sampleDirection = 1.0
        hasPanEnvelope = instrument?.panningEnvelope != nil
        // Startwerte für Tick 0 sofort setzen (sonst erst ab dem ersten Tick).
        if let env = instrument?.volumeEnvelope {
            envVolumeFactor = envelopeValue(env, at: volEnvPos) / 64.0
        } else {
            envVolumeFactor = 1.0
        }
        if let env = instrument?.panningEnvelope {
            panEnvValue = envelopeValue(env, at: panEnvPos)
        } else {
            panEnvValue = 32
        }
        if let env = instrument?.pitchEnvelope, env.valueMode == .pitch {
            pitchEnvValue = envelopeValue(env, at: pitchEnvPos)
        } else {
            pitchEnvValue = 32
        }
        autoVibPos = 0
        if let av = instrument?.autoVibrato, av.depth > 0 {
            if av.sweep > 0 {
                autoVibAmp = 0
                autoVibSweepStep = (av.depth << 8) / av.sweep
            } else {
                autoVibAmp = av.depth << 8
                autoVibSweepStep = 0
            }
        } else {
            autoVibAmp = 0
            autoVibSweepStep = 0
        }
    }

    // Linear interpolierten Envelope-Wert (0..64) an Tick-Position `pos` lesen.
    // Vor dem ersten Punkt = erster Wert, hinter dem letzten = letzter Wert.
    private func envelopeValue(_ env: Envelope, at pos: Int) -> Float {
        let pts = env.points
        guard let first = pts.first, let last = pts.last else { return 64 }
        if pos <= first.frame { return Float(first.value) }
        if pos >= last.frame { return Float(last.value) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if pos >= a.frame && pos <= b.frame {
                let dx = b.frame - a.frame
                if dx <= 0 { return Float(a.value) }
                let t = Float(pos - a.frame) / Float(dx)
                return Float(a.value) + t * Float(b.value - a.value)
            }
        }
        return Float(last.value)
    }

    // Envelope-Position einen Tick weiterschieben. XM hält an einem einzelnen
    // Sustain-Punkt; IT schleift den vollständigen Sustain-Bereich inklusiv.
    // Der Rückgabewert meldet das Ende einer nicht geloopten IT-Hüllkurve.
    @discardableResult
    private func stepEnvelope(
        _ env: Envelope,
        pos: inout Int,
        released: Bool,
        itStyle: Bool = false
    ) -> Bool {
        let pts = env.points
        guard pts.count > 1 else { return false }
        if itStyle {
            pos += 1
            if env.sustainEnabled, !released,
               env.sustainStart >= 0, env.sustainStart < pts.count,
               env.sustainEnd >= env.sustainStart, env.sustainEnd < pts.count,
               pos > pts[env.sustainEnd].frame {
                pos = pts[env.sustainStart].frame
                return false
            }
            if env.loopEnabled,
               env.loopStart >= 0, env.loopStart < pts.count,
               env.loopEnd >= env.loopStart, env.loopEnd < pts.count,
               pos > pts[env.loopEnd].frame {
                pos = pts[env.loopStart].frame
                return false
            }
            if let last = pts.last, pos > last.frame {
                pos = last.frame
                return true
            }
            return false
        }
        if env.sustainEnabled, !released,
           env.sustainPoint >= 0, env.sustainPoint < pts.count,
           pos == pts[env.sustainPoint].frame {
            return false // am Sustain-Punkt halten
        }
        pos += 1
        if env.loopEnabled,
           env.loopEnd >= 0, env.loopEnd < pts.count,
           pos >= pts[env.loopEnd].frame {
            pos = (env.loopStart >= 0 && env.loopStart < pts.count) ? pts[env.loopStart].frame : 0
        }
        return false
    }

    // Auto-Vibrato einen Tick weiterdrehen und das Perioden-Delta zurückgeben
    // (±~15 bei voller Tiefe). Sweep läuft nur, solange die Note nicht losgelassen ist.
    private func advanceAutoVibrato() -> Float {
        guard let av = instrument?.autoVibrato, av.depth > 0 else { return 0 }
        if autoVibSweepStep > 0, !keyReleased {
            autoVibAmp += autoVibSweepStep
            if (autoVibAmp >> 8) > av.depth {
                autoVibAmp = av.depth << 8
                autoVibSweepStep = 0
            }
        }
        autoVibPos = (autoVibPos + av.rate) & 0xFF
        let waveVal: Int
        switch av.type {
        case 1: waveVal = autoVibPos > 127 ? 64 : -64                 // Square
        case 2: waveVal = (((autoVibPos >> 1) + 64) & 127) - 64       // Ramp
        case 3: waveVal = (((-(autoVibPos >> 1)) + 64) & 127) - 64    // Ramp (invertiert)
        default:                                                       // Sine (±64)
            waveVal = Int((sin(Double(autoVibPos) / 256.0 * 2.0 * Double.pi) * 64.0).rounded())
        }
        return Float((waveVal * autoVibAmp) >> 14)
    }

    public func applyEffect(note: Note) {
        self.volumeSlide = 0
        // XM-Volume-Column-/Panning-Slides pro Row zurücksetzen (auch wenn die
        // Zeile gar keinen Haupteffekt hat — daher vor dem hasEffect-Guard).
        self.volColVolSlide = 0
        self.panSlide = 0
        self.periodDelta = 0
        self.portamento = false
        self.vibrato = false
        self.tremolo = false
        self.arpActive = false
        self.retrigger = 0
        self.delayNote = -1
        // Tremor gilt nur auf Rows mit Ixy; der Zähler läuft aber über
        // Row-Grenzen weiter (ST3-Verhalten), darum hier kein tremorCount-Reset.
        self.tremorActive = false

        guard note.hasEffect else { return }
        
        let effectId = note.effectId
        let effectData = note.effectData
        let effectHigh = note.effectHigh
        let effectLow = note.effectLow

        if itMode,
           effectId > ModuleEffect.impulseTrackerCommandBase,
           effectId <= ModuleEffect.impulseTrackerCommandBase + 26 {
            applyITEffect(
                command: effectId - ModuleEffect.impulseTrackerCommandBase,
                parameter: effectData
            )
            return
        }
        
        switch effectId {
        case 0x00: // ARPEGGIO
            if effectData > 0 {
                self.arpActive = true
                self.arpX = effectHigh
                self.arpY = effectLow
            }
        case 0x01: // SLIDE_UP
            let p = xmLinearMode
                ? xmRememberedParam(effectData, memory: &xmPortaUpMemory)
                : effectData
            self.periodDelta = -Float(p) * portaScale
        case 0x02: // SLIDE_DOWN
            let p = xmLinearMode
                ? xmRememberedParam(effectData, memory: &xmPortaDownMemory)
                : effectData
            self.periodDelta = Float(p) * portaScale
        case 0x03: // TONE_PORTAMENTO
            self.portamento = true
            if effectData > 0 {
                // S3M- UND XM-Perioden sind 4x feiner als Amiga-Perioden (64
                // Einheiten = 1 Halbton) -> der Slide-Schritt muss ×4, sonst
                // erreicht die Note ihr Porta-Ziel nie (klingt dissonant). Für
                // XM ist param*4 die libopenmpt-Semantik.
                self.portamentoSpeed = Float(effectData) * portaScale
            }
            self.periodDelta = self.portamentoSpeed
            self.setCurrentPeriod = false
            self.setSampleIndex = nil
        case 0x04: // VIBRATO
            if effectHigh > 0 { self.vibratoSpeed = Float(effectHigh) }
            if effectLow > 0 { self.vibratoDepth = Float(effectLow) }
            self.vibrato = true
        case 0x05: // TONE_PORTAMENTO_WITH_VOLUME_SLIDE
            self.portamento = true
            self.setCurrentPeriod = false
            self.setSampleIndex = nil
            self.periodDelta = self.portamentoSpeed
            let slideParam = xmLinearMode
                ? xmRememberedParam(effectData, memory: &xmVolumeSlideMemory)
                : effectData
            if s3mMode {
                // S3M Lxy: Volume-Slide-Teil mit voller Dxy-Semantik (Memory,
                // Fine-Slides).
                applyS3MVolumeSlide(param: slideParam)
            } else {
                applyStandardVolumeSlide(param: slideParam)
            }
        case 0x06: // VIBRATO_WITH_VOLUME_SLIDE
            self.vibrato = true
            let slideParam = xmLinearMode
                ? xmRememberedParam(effectData, memory: &xmVolumeSlideMemory)
                : effectData
            if s3mMode {
                // S3M Kxy: analog zu Lxy.
                applyS3MVolumeSlide(param: slideParam)
            } else {
                applyStandardVolumeSlide(param: slideParam)
            }
        case 0x07: // TREMOLO
            if effectHigh > 0 { self.tremoloSpeed = Float(effectHigh) }
            if effectLow > 0 { self.tremoloDepth = Float(effectLow) }
            self.tremolo = true
        case 0x08: // PANNING
            self.panning = Float(effectData) / 255.0
        case 0x09: // SAMPLE_OFFSET
            // 900 ohne Parameter wiederholt den letzten Offset (PT-Memory).
            if effectData > 0 {
                self.sampleOffsetMemory = Double(effectData) * 256.0
            }
            self.setSampleIndex = self.sampleOffsetMemory
        case 0x0A: // VOLUME_SLIDE
            if s3mMode {
                applyS3MVolumeSlide(param: effectData)
            } else {
                let p = xmLinearMode
                    ? xmRememberedParam(effectData, memory: &xmVolumeSlideMemory)
                    : effectData
                applyStandardVolumeSlide(param: p)
            }
        case 0x0B: // POSITION_JUMP
            // Handled at PlayerCoordinator level
            break
        case 0x0C: // SET_VOLUME
            self.setVolume = Float(effectData)
        case 0x0D: // PATTERN_BREAK
            // Handled at PlayerCoordinator level
            break
        case 0x0F: // SET_SPEED
            // Handled at PlayerCoordinator level
            break
        case 0xE1: // PORTA_UP_FINE
            if let per = self.setPeriod {
                self.setPeriod = per - Float(effectData)
            } else {
                self.setPeriod = self.period - Float(effectData)
            }
        case 0xE2: // PORTA_DOWN_FINE
            if let per = self.setPeriod {
                self.setPeriod = per + Float(effectData)
            } else {
                self.setPeriod = self.period + Float(effectData)
            }
        case 0xE6: // PATTERN_LOOP
            // Handled at PlayerCoordinator level
            break
        case 0xE8: // EXTENDED_PANNING
            self.panning = Float(effectLow * 17) / 255.0
        case 0xE9: // RETRIGGER_NOTE
            self.retrigger = effectData
        case 0xEA: // VOLUME_SLIDE_UP_FINE
            if let vol = self.setVolume {
                self.setVolume = min(64.0, vol + Float(effectData))
            } else {
                self.setVolume = min(64.0, self.volume + Float(effectData))
            }
        case 0xEB: // VOLUME_SLIDE_DOWN_FINE
            if let vol = self.setVolume {
                self.setVolume = max(0.0, vol - Float(effectData))
            } else {
                self.setVolume = max(0.0, self.volume - Float(effectData))
            }
        case 0xEC: // CUT_NOTE
            self.cutNoteTick = effectLow
        case 0xED: // DELAY_NOTE
            self.delayNote = effectLow
        case 0xEE: // PATTERN_DELAY
            // Handled at PlayerCoordinator level
            break
        case ModuleEffect.volumeSlideS3M: // S3M Dxy
            applyS3MVolumeSlide(param: effectData)
        case ModuleEffect.portaDownS3M: // S3M Exx (Period steigt)
            applyS3MPorta(param: effectData, direction: 1.0)
        case ModuleEffect.portaUpS3M: // S3M Fxx (Period sinkt)
            applyS3MPorta(param: effectData, direction: -1.0)
        case ModuleEffect.tremor: // S3M Ixy
            var p = effectData
            if p == 0 { p = s3mEffectMemory } else { s3mEffectMemory = p }
            self.tremorOn = ((p >> 4) & 0x0F) + 1
            self.tremorOff = (p & 0x0F) + 1
            self.tremorActive = true
        case ModuleEffect.fineVibrato: // S3M Uxy: Vibrato mit 1/4-Tiefe
            if effectHigh > 0 { self.vibratoSpeed = Float(effectHigh) }
            if effectLow > 0 { self.vibratoDepth = Float(effectLow) / 4.0 }
            self.vibrato = true
        case ModuleEffect.keyOff: // XM Kxx: Key-Off (sofort bei 0, sonst auf Tick xx)
            if effectData == 0 {
                self.triggerKeyOff()
            } else {
                self.keyOffTick = effectData
            }
        case ModuleEffect.setEnvelopePos: // XM Lxx: Envelope-Position setzen
            self.volEnvPos = effectData
            self.panEnvPos = effectData
        case ModuleEffect.panSlide: // XM Pxy: x = nach rechts, y = nach links (pro Tick)
            if effectHigh > 0 {
                self.panSlide = Float(effectHigh)
            } else if effectLow > 0 {
                self.panSlide = -Float(effectLow)
            }
        case ModuleEffect.extraFinePortaUp: // XM X1x: einmalig Periode -x (höher)
            applyFinePeriod(delta: -Float(effectData))
        case ModuleEffect.extraFinePortaDown: // XM X2x: einmalig Periode +x (tiefer)
            applyFinePeriod(delta: Float(effectData))
        default:
            break
        }
    }

    // XM-Key-Off auslösen: Sustain freigeben (Fadeout startet); ohne aktive
    // Volume-Hüllkurve stoppt der Ton sofort (FT2-Quirk).
    private func triggerKeyOff() {
        self.keyReleased = true
        if self.instrument?.volumeEnvelope == nil {
            self.playing = false
        }
    }

    // XM-Volume-Column (rohes Byte 0x00..0xFF) auswerten. Tick-0-Sofortwerte
    // (Set Volume/Panning, Fine-Slides, Vibrato-Parameter, Tone-Porta) direkt,
    // die laufenden Slides über volColVolSlide/panSlide (in performTick pro Tick).
    private func applyXMVolumeColumn(_ v: Int) {
        switch v {
        case 0x00:
            break                                   // nichts
        case 0x10...0x50:
            self.setVolume = Float(v - 0x10)        // Set Volume 0..64
        case 0x60...0x6F:
            self.volColVolSlide = -Float(v & 0x0F)  // Vol-Slide down/Tick
        case 0x70...0x7F:
            self.volColVolSlide = Float(v & 0x0F)   // Vol-Slide up/Tick
        case 0x80...0x8F:
            applyFineVolume(delta: -Float(v & 0x0F)) // Fine Vol down (einmalig)
        case 0x90...0x9F:
            applyFineVolume(delta: Float(v & 0x0F))  // Fine Vol up (einmalig)
        case 0xA0...0xAF:
            self.vibratoSpeed = Float(v & 0x0F)     // Set Vibrato Speed
        case 0xB0...0xBF:
            self.vibratoDepth = Float(v & 0x0F)     // Vibrato (Depth)
            self.vibrato = true
        case 0xC0...0xCF:
            self.panning = Float((v & 0x0F) << 4) / 255.0  // Set Panning (0,16,…,240)
        case 0xD0...0xDF:
            self.panSlide = -Float(v & 0x0F)        // Panning-Slide links/Tick
        case 0xE0...0xEF:
            self.panSlide = Float(v & 0x0F)         // Panning-Slide rechts/Tick
        case 0xF0...0xFF:                            // Tone Portamento (Speed = y<<4)
            self.portamento = true
            let speed = (v & 0x0F) << 4
            if speed > 0 { self.portamentoSpeed = Float(speed) }
            self.periodDelta = self.portamentoSpeed
            self.setCurrentPeriod = false           // nicht snappen, nicht retriggern
            self.setSampleIndex = nil
        default:
            break
        }
    }

    // IT-Buchstabeneffekte im Sample-Modus. Globale Befehle (A/B/C/T/V)
    // verarbeitet der Sequencer; hier bleiben die kanalbezogenen Familien.
    private func applyITEffect(command: Int, parameter: Int) {
        guard let state = itPatternState else { return }
        switch command {
        case 4: // Dxy: Volume Slide, Memory wird später auch von K/L genutzt.
            applyITVolumeSlide(state.remembered(command: command, parameter: parameter))
        case 5: // Exx: Portamento down
            applyITPorta(
                state.remembered(command: command, parameter: parameter),
                direction: 1
            )
        case 6: // Fxx: Portamento up
            applyITPorta(
                state.remembered(command: command, parameter: parameter),
                direction: -1
            )
        case 7: // Gxx: Tone Portamento
            let value = state.remembered(command: command, parameter: parameter)
            portamento = true
            if value > 0 { portamentoSpeed = Float(value) * portaScale }
            periodDelta = portamentoSpeed
            setCurrentPeriod = false
            setSampleIndex = nil
        case 8: // Hxy: Vibrato
            let value = state.remembered(command: command, parameter: parameter)
            if value >> 4 > 0 { vibratoSpeed = Float(value >> 4) }
            if value & 0x0F > 0 { vibratoDepth = Float(value & 0x0F) }
            vibrato = true
        case 9: // Ixy: Tremor
            let value = state.remembered(command: command, parameter: parameter)
            tremorOn = ((value >> 4) & 0x0F) + 1
            tremorOff = (value & 0x0F) + 1
            tremorActive = true
        case 10: // Jxy: Arpeggio
            let value = state.remembered(command: command, parameter: parameter)
            arpX = (value >> 4) & 0x0F
            arpY = value & 0x0F
            arpActive = value != 0
        case 11: // Kxy: Vibrato + Dxy-Memory
            vibrato = true
            applyITVolumeSlide(state.remembered(
                command: command, parameter: parameter, memoryCommand: 4
            ))
        case 12: // Lxy: Tone Portamento + Dxy-Memory
            portamento = true
            periodDelta = portamentoSpeed
            setCurrentPeriod = false
            setSampleIndex = nil
            applyITVolumeSlide(state.remembered(
                command: command, parameter: parameter, memoryCommand: 4
            ))
        case 15: // Oxx: Sample Offset
            let value = state.remembered(command: command, parameter: parameter)
            sampleOffsetMemory = Double(value) * 256.0
            setSampleIndex = sampleOffsetMemory
        case 17: // Qxy: Retrigger mit Lautstärkemodus x alle y Ticks
            let value = state.remembered(command: command, parameter: parameter)
            retriggerVolumeMode = (value >> 4) & 0x0F
            retrigger = value & 0x0F
        case 18: // Rxy: Tremolo
            let value = state.remembered(command: command, parameter: parameter)
            if value >> 4 > 0 { tremoloSpeed = Float(value >> 4) }
            if value & 0x0F > 0 { tremoloDepth = Float(value & 0x0F) }
            tremolo = true
        case 21: // Uxy: Fine Vibrato; H/U teilen Phase und Parameterzustand.
            let value = state.remembered(command: command, parameter: parameter, memoryCommand: 8)
            if value >> 4 > 0 { vibratoSpeed = Float(value >> 4) }
            if value & 0x0F > 0 { vibratoDepth = Float(value & 0x0F) / 4.0 }
            vibrato = true
        case 24: // Xxx: absolutes Panning 0...255
            setPanning = Float(parameter) / 255.0
        default:
            break
        }
    }

    // IT-Volume-Column bleibt roh im Patternmodell. Die Bereiche entsprechen
    // ITTECH/OpenMPT; 213...222 sind reserviert und werden ignoriert.
    private func applyITVolumeColumn(_ value: Int) {
        guard value >= 0 else { return }
        switch value {
        case 0...64:
            setVolume = Float(value)
        case 65...74:
            applyFineVolume(delta: Float(value - 65))
        case 75...84:
            applyFineVolume(delta: -Float(value - 75))
        case 85...94:
            volColVolSlide = Float(value - 85)
        case 95...104:
            volColVolSlide = -Float(value - 95)
        case 105...114:
            periodDelta = Float(value - 105) * portaScale
        case 115...124:
            periodDelta = -Float(value - 115) * portaScale
        case 128...192:
            setPanning = Float(value - 128) / 64.0
        case 193...202:
            // Feste Zuordnung ohne lokales Array: playNote läuft im Audio-Thread.
            let speed: Int
            switch value - 193 {
            case 1: speed = 1
            case 2: speed = 4
            case 3: speed = 8
            case 4: speed = 16
            case 5: speed = 32
            case 6: speed = 64
            case 7: speed = 96
            case 8: speed = 128
            default: speed = 0
            }
            portamento = true
            if speed > 0 { portamentoSpeed = Float(speed) }
            periodDelta = portamentoSpeed
            setCurrentPeriod = false
            setSampleIndex = nil
        case 203...212:
            let depth = value - 203
            if depth > 0 { vibratoDepth = Float(depth) }
            vibrato = true
        case 223...232:
            setSampleIndex = Double(value - 223) * 256.0
        default:
            break
        }
    }

    // IT Dxy: reguläre Slides auf Tick > 0, Fine-/Extra-Fine-Formen einmalig
    // auf Tick 0. Exakte Old-Effects-Abweichungen folgen gesammelt in M8.
    private func applyITVolumeSlide(_ parameter: Int) {
        let high = (parameter >> 4) & 0x0F
        let low = parameter & 0x0F
        if low == 0x0F, high > 0 {
            applyFineVolume(delta: Float(high))
        } else if high == 0x0F, low > 0 {
            applyFineVolume(delta: -Float(low))
        } else if low == 0x0E, high > 0 {
            applyFineVolume(delta: Float(high))
        } else if high == 0x0E, low > 0 {
            applyFineVolume(delta: -Float(low))
        } else if high > 0 {
            volumeSlide = Float(high)
        } else if low > 0 {
            volumeSlide = -Float(low)
        }
    }

    // IT E/F: normale Portamenti laufen pro Tick, F-/E-Highnibble sind
    // Fine/Extra-Fine und wirken sofort auf die aktuelle Zielperiode.
    private func applyITPorta(_ parameter: Int, direction: Float) {
        let high = (parameter >> 4) & 0x0F
        let low = parameter & 0x0F
        if high == 0x0F {
            applyFinePeriod(delta: direction * Float(low) * portaScale)
        } else if high == 0x0E {
            applyFinePeriod(delta: direction * Float(low))
        } else {
            periodDelta = direction * Float(parameter) * portaScale
        }
    }

    // S3M Dxy inkl. Fine-Slides (DxF/DFy) und geteiltem Memory (Param 0 =
    // letzten Wert wiederholen). Fine-Slides wirken einmalig auf Tick 0,
    // normale Slides pro Tick > 0 (volumeSlide).
    private func applyS3MVolumeSlide(param: Int) {
        var p = param
        if p == 0 { p = s3mEffectMemory } else { s3mEffectMemory = p }
        let x = (p >> 4) & 0x0F
        let y = p & 0x0F
        if y == 0x0F && x > 0 {
            applyFineVolume(delta: Float(x))       // DxF: Fine-Slide up
        } else if x == 0x0F && y > 0 {
            applyFineVolume(delta: -Float(y))      // DFy: Fine-Slide down
        } else if x > 0 {
            self.volumeSlide = Float(x)
        } else if y > 0 {
            self.volumeSlide = -Float(y)
        }
    }

    // FT2/XM: Parameter 0 wiederholt den letzten Nicht-Null-Parameter dieses
    // Effekt-Typs. Ohne gespeicherten Wert bleibt der Effekt wirkungslos.
    private func xmRememberedParam(_ param: Int, memory: inout Int) -> Int {
        if param != 0 {
            memory = param
            return param
        }
        return memory
    }

    // Gemeinsame ProTracker/XM-Volume-Slide-Auswertung für Axy/5xy/6xy.
    // XM ruft diese Funktion bereits mit aufgelöstem Effekt-Memory auf.
    private func applyStandardVolumeSlide(param: Int) {
        let high = (param >> 4) & 0x0F
        let low = param & 0x0F
        if high > 0 {
            self.volumeSlide = Float(high)
        } else if low > 0 {
            self.volumeSlide = -Float(low)
        }
    }

    // Einmalige Lautstärke-Korrektur auf Tick 0 — gleiche Mechanik wie die
    // ProTracker-Fine-Slides 0xEA/0xEB (über setVolume, damit die Reihenfolge
    // mit Instrument-Default und Volume-Column stimmt).
    private func applyFineVolume(delta: Float) {
        if let vol = self.setVolume {
            self.setVolume = max(0.0, min(64.0, vol + delta))
        } else {
            self.setVolume = max(0.0, min(64.0, self.volume + delta))
        }
    }

    // S3M Exx/Fxx: normal = 4*Param pro Tick, Fxx-Nibble 0xF = Fine (einmalig
    // 4*Low), 0xE = Extra-Fine (einmalig 1*Low). direction: +1 = Down (Period
    // steigt), -1 = Up.
    private func applyS3MPorta(param: Int, direction: Float) {
        var p = param
        if p == 0 { p = s3mEffectMemory } else { s3mEffectMemory = p }
        let hi = (p >> 4) & 0x0F
        let lo = p & 0x0F
        if hi == 0x0F {
            applyFinePeriod(delta: direction * Float(lo) * 4.0)
        } else if hi == 0x0E {
            applyFinePeriod(delta: direction * Float(lo))
        } else {
            self.periodDelta = direction * Float(p) * 4.0
        }
    }

    // Einmalige Perioden-Korrektur auf Tick 0 (S3M-Fine-/Extra-Fine-Porta).
    // Ohne anstehende Note muss die Korrektur sofort hörbar werden, darum
    // setCurrentPeriod aktivieren (Sample läuft weiter, kein Retrigger, weil
    // setSampleIndex nil bleibt).
    private func applyFinePeriod(delta: Float) {
        if let per = self.setPeriod {
            self.setPeriod = per + delta
        } else {
            self.setPeriod = self.period + delta
            self.setCurrentPeriod = true
        }
    }

    public func performTick(tick: Int, sampleRate: Double, clockRate: Double) {
        if self.volumeSlide != 0 && tick > 0 {
            self.currentVolume += self.volumeSlide
            if self.currentVolume < 0 { self.currentVolume = 0 }
            if self.currentVolume > 64 { self.currentVolume = 64 }
        }
        
        if self.vibrato {
            // ProTracker: Vibrato-Sinusindex erst ab Tick 1 weiterdrehen, nie auf
            // Tick 0. Sonst driftet der Index jede Row um einen Schritt (vgl. der
            // gleiche tick>0-Guard beim Volume-Slide oben und im HTML-Worklet).
            if tick > 0 {
                self.vibratoIndex = (self.vibratoIndex + self.vibratoSpeed).truncatingRemainder(dividingBy: 64)
                // PT-Sinustabelle statt sin(): korrekte Amplitude (depth*255/128,
                // ~doppelt so tief wie das alte sin()*depth) und Original-Wellenform.
                let p = Int(self.vibratoIndex) & 63
                let amp = DSPChannel.ptSineTable[p & 31]
                // periodScale: S3M-Perioden sind 4x feiner, das Vibrato-Delta
                // muss entsprechend groesser ausfallen (ST3-Verhalten).
                let delta = (p < 32 ? amp : -amp) * self.vibratoDepth / 128.0 * self.periodScale
                self.currentPeriod = self.period + delta
            }
        }
        else if self.tremolo {
            // Wie Vibrato: Tremolo-Index nur auf Tick > 0 fortschreiben.
            if tick > 0 {
                self.tremoloIndex = (self.tremoloIndex + self.tremoloSpeed).truncatingRemainder(dividingBy: 64)
                // PT-Sinustabelle: Amplitude depth*255/64 (~viermal so stark wie
                // das alte sin()*depth) und Original-Wellenform.
                let p = Int(self.tremoloIndex) & 63
                let amp = DSPChannel.ptSineTable[p & 31]
                let volDelta = (p < 32 ? amp : -amp) * self.tremoloDepth / 64.0
                self.currentVolume = max(0.0, min(64.0, self.volume + volDelta))
            }
        }
        else if self.periodDelta != 0 {
            // ProTracker: 1xx/2xx/3xx (Porta-Up/Down/Tone-Porta) sliden nur auf
            // Ticks > 0, NICHT auf Tick 0. Sonst macht jede Row einen Schritt zu
            // viel (6 statt 5 bei Speed 6). Spiegelt den Volume-Slide-Guard.
            if tick > 0 {
                if self.portamento {
                    if self.currentPeriod != self.period {
                        let sign: Float = self.period > self.currentPeriod ? 1.0 : -1.0
                        let distance = abs(self.currentPeriod - self.period)
                        let diff = min(distance, abs(self.periodDelta))
                        self.currentPeriod += sign * diff
                    }
                } else {
                    self.currentPeriod += self.periodDelta
                }
            }
        }
        else if self.arpActive {
            // Zyklus [0, x, y] ueber tick % 3 — ohne Array-Allokation.
            let semis: Int
            switch tick % 3 {
            case 0: semis = 0
            case 1: semis = self.arpX
            default: semis = self.arpY
            }
            if itLinearMode {
                self.currentPeriod = self.period - Float(semis * 64)
            } else {
                self.currentPeriod = self.period / Float(pow(2.0, Double(Float(semis) / 12.0)))
            }
        }
        else if self.retrigger > 0 && self.playing && tick > 0 && (tick % self.retrigger) == 0 {
            self.sampleIndex = 0.0
            if itMode { applyITRetriggerVolume() }
        }
        else if self.delayNote >= 0 && self.delayNote == tick {
            self.instrument = self.setInstrument
            self.sample = self.setSample
            if let vol = self.setVolume {
                self.volume = vol
                self.currentVolume = vol
            }
            if let per = self.setPeriod {
                self.period = per
                self.currentPeriod = per
            }
            self.sampleIndex = 0.0
            self.playing = true
            self.delayNote = -1
        }
        
        // Tremor (S3M Ixy): gated die Lautstärke im An/Aus-Raster. Läuft auf
        // jedem Tick weiter, auch über Row-Grenzen hinweg.
        if self.tremorActive {
            let cycle = max(1, self.tremorOn + self.tremorOff)
            let phase = self.tremorCount % cycle
            // In der An-Phase die Basis-Lautstärke wiederherstellen (die
            // Aus-Phase hat currentVolume zuvor auf 0 gezogen).
            self.currentVolume = phase < self.tremorOn ? self.volume : 0
            self.tremorCount += 1
        }

        // Instrument-Voice pro Tick: Hüllkurven und Fadeout bleiben strikt auf
        // XM beziehungsweise IT-Instrument-Modus begrenzt; MOD/S3M sind unberührt.
        var xmPeriodDelta: Float = 0
        var itPitchEnvelopeValue: Float = 32
        // XM und IT besitzen eine zweite Effektspalte. Deren Volume-Slide wirkt
        // wie die Hauptspalten-Slides erst ab Tick 1.
        if (xmLinearMode || itMode), self.volColVolSlide != 0, tick > 0 {
            self.currentVolume = max(0.0, min(64.0, self.currentVolume + self.volColVolSlide))
        }

        if xmLinearMode {
            // Panning-Slide der XM-Volume-Column (erst ab Tick 1).
            if self.panSlide != 0 && tick > 0 {
                self.panning = max(0.0, min(1.0, self.panning + self.panSlide / 255.0))
            }
            // XM Kxx: verzögerter Key-Off auf dem angegebenen Tick.
            if self.keyOffTick == tick { self.triggerKeyOff() }

            if let env = instrument?.volumeEnvelope {
                envVolumeFactor = envelopeValue(env, at: volEnvPos) / 64.0
                stepEnvelope(env, pos: &volEnvPos, released: keyReleased)
            }
            if let env = instrument?.panningEnvelope {
                panEnvValue = envelopeValue(env, at: panEnvPos)
                stepEnvelope(env, pos: &panEnvPos, released: keyReleased)
            }
            // Fadeout nur bei aktiver Volume-Hüllkurve (FT2-Verhalten).
            if keyReleased, let inst = instrument, inst.volumeEnvelope != nil, inst.fadeout > 0 {
                fadeVolume -= inst.fadeout
                if fadeVolume < 0 { fadeVolume = 0 }
            }
            xmPeriodDelta = advanceAutoVibrato()
        } else if itMode, itInstrumentMode {
            let envelopeReleased = itEnvelopeReleased
            if let env = instrument?.volumeEnvelope {
                envVolumeFactor = envelopeValue(env, at: volEnvPos) / 64.0
                let ended = stepEnvelope(
                    env, pos: &volEnvPos, released: envelopeReleased, itStyle: true
                )
                if ended {
                    noteFadeActive = true
                    if env.points.last?.value == 0 {
                        fadeVolume = 0
                        playing = false
                    }
                }
            } else {
                envVolumeFactor = 1.0
            }
            if let env = instrument?.panningEnvelope {
                panEnvValue = envelopeValue(env, at: panEnvPos)
                stepEnvelope(env, pos: &panEnvPos, released: envelopeReleased, itStyle: true)
            }
            if let env = instrument?.pitchEnvelope, env.valueMode == .pitch {
                pitchEnvValue = envelopeValue(env, at: pitchEnvPos)
                itPitchEnvelopeValue = pitchEnvValue
                stepEnvelope(env, pos: &pitchEnvPos, released: envelopeReleased, itStyle: true)
            } else {
                pitchEnvValue = 32
            }

            if noteFadeActive, let inst = instrument, inst.fadeout > 0 {
                fadeVolume = max(0, fadeVolume - inst.fadeout * 2)
                if fadeVolume == 0 { playing = false }
            }
            itEnvelopeReleased = keyReleased
        }

        if self.currentPeriod < self.periodMin { self.currentPeriod = self.periodMin }
        if self.currentPeriod > self.periodMax { self.currentPeriod = self.periodMax }

        // Auto-Vibrato-Delta nur für die Frequenzberechnung addieren (nicht clampen
        // in currentPeriod, damit es sich nicht aufsummiert). MOD/S3M: Delta 0.
        var effPeriod = self.currentPeriod + xmPeriodDelta
        if itMode, itInstrumentMode, itPitchEnvelopeValue != 32 {
            let signedValue = itPitchEnvelopeValue - 32
            if itLinearMode {
                // IT-Pitch-Envelope: eine rohe Einheit entspricht einem halben
                // Halbton, also 32 linearen Periodeneinheiten.
                effPeriod -= signedValue * 32
            } else {
                effPeriod *= Float(pow(2.0, Double(-signedValue / 24.0)))
            }
        }
        if effPeriod > 0, sampleRate > 0 {
            // XM linear: Frequenz exponentiell aus der Periode. MOD/S3M: Paula-/
            // ST3-Clock geteilt durch die Periode. (pow ist alloc-frei — wie das
            // Arpeggio oben — und damit im Render-Block zulässig.)
            let hz: Double
            if itLinearMode {
                let c5Speed = sample?.itProperties?.c5Speed ?? sample?.c2spd ?? 8363
                hz = Double(c5Speed) * pow(2.0, (3840.0 - Double(effPeriod)) / 768.0)
            } else if xmLinearMode {
                hz = 8363.0 * pow(2.0, (4608.0 - Double(effPeriod)) / 768.0)
            } else {
                hz = clockRate / Double(effPeriod)
            }
            let speed = hz / sampleRate
            self.sampleSpeed = speed.isNaN || speed.isInfinite ? 0.0 : speed
        } else {
            self.sampleSpeed = 0.0
        }

        if self.cutNoteTick == tick {
            self.currentVolume = 0.0
        }
    }

    // Lautstärketabelle von IT Qxy. Der Wert bleibt wie alle Tracker-Volumes
    // im Bereich 0...64 und aktualisiert Basis- und aktuelle Lautstärke.
    private func applyITRetriggerVolume() {
        var value = currentVolume
        switch retriggerVolumeMode {
        case 0x1: value -= 1
        case 0x2: value -= 2
        case 0x3: value -= 4
        case 0x4: value -= 8
        case 0x5: value -= 16
        case 0x6: value *= 2.0 / 3.0
        case 0x7: value *= 0.5
        case 0x9: value += 1
        case 0xA: value += 2
        case 0xB: value += 4
        case 0xC: value += 8
        case 0xD: value += 16
        case 0xE: value *= 1.5
        case 0xF: value *= 2.0
        default: break
        }
        value = max(0, min(64, value))
        volume = value
        currentVolume = value
    }
}
