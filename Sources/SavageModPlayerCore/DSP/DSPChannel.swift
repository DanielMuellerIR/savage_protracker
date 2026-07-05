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

    // Nonisolated unsafe to bypass strict concurrency warnings inside lock-free real-time audio thread
    nonisolated(unsafe) public var instrument: Instrument?
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
    nonisolated(unsafe) public var retrigger: Int = 0
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
    // Skaliert Vibrato-Deltas: S3M-Perioden sind 4x feiner als Amiga-Perioden.
    nonisolated(unsafe) public var periodScale: Float = 1
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
    
    // Temp-Zustände für Ticks
    nonisolated(unsafe) public var setInstrument: Instrument?
    nonisolated(unsafe) public var setVolume: Float?
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
        sampleIndex = 0.0
        sampleSpeed = 0.0
        sampleOffsetMemory = 0.0
        patternLoopStartRow = 0
        patternLoopCount = -1
        cutNoteTick = -1
        retrigger = 0
        delayNote = -1
        arpActive = false
        arpX = 0
        arpY = 0
        isMuted = false
        isSoloed = false

        s3mMode = false
        periodScale = 1
        periodMin = 113
        periodMax = 856
        tremorActive = false
        tremorOn = 1
        tremorOff = 1
        tremorCount = 0
        s3mEffectMemory = 0

        setInstrument = nil
        setVolume = nil
        setPeriod = nil
        setCurrentPeriod = false
        setSampleIndex = nil
        portamento = false
    }
    
    @inline(__always)
    public func getNearestSample(from bytes: [Int8], index: Double) -> Float {
        let size = bytes.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }
        
        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }
        return Float(bytes[idx]) / 256.0
    }
    
    @inline(__always)
    public func getInterpolatedSample(from bytes: [Int8], index: Double) -> Float {
        let size = bytes.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }
        
        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }
        
        let sampleCurrent = Float(bytes[idx]) / 256.0
        let frac = Float(index - Double(idx))
        
        let nextIdx = idx + 1
        if nextIdx < size {
            let sampleNext = Float(bytes[nextIdx]) / 256.0
            return sampleCurrent + frac * (sampleNext - sampleCurrent)
        } else {
            return sampleCurrent
        }
    }
    
    @inline(__always)
    public func getInterpolatedSampleLooped(from bytes: [Int8], index: Double, repeatOffset: Int, repeatLength: Int) -> Float {
        let size = bytes.count
        guard size > 0, index.isFinite, !index.isNaN else { return 0.0 }
        
        let idx = Int(index)
        guard idx >= 0 && idx < size else { return 0.0 }
        
        let sampleCurrent = Float(bytes[idx]) / 256.0
        let frac = Float(index - Double(idx))
        
        var nextIdx = idx + 1
        let loopEnd = repeatOffset + repeatLength
        if nextIdx >= loopEnd {
            nextIdx = repeatOffset
        }
        
        if nextIdx >= 0 && nextIdx < size {
            let sampleNext = Float(bytes[nextIdx]) / 256.0
            return sampleCurrent + frac * (sampleNext - sampleCurrent)
        } else {
            return sampleCurrent
        }
    }
    
    public func playNote(_ note: Note, instruments: [Instrument?]) {
        self.setInstrument = nil
        self.setVolume = nil
        self.setPeriod = nil
        self.delayNote = -1
        self.cutNoteTick = -1
        
        var hasSetInstrument = false
        if note.instrument > 0 {
            hasSetInstrument = true
            if note.instrument < instruments.count, let inst = instruments[note.instrument] {
                self.setInstrument = inst
                self.setVolume = Float(inst.volume)
            } else {
                self.setInstrument = nil
                self.setVolume = 0
            }
        }
        
        self.setSampleIndex = nil
        self.setCurrentPeriod = false

        if note.key == Note.keyCut {
            // S3M-Note-Cut (^^): Sample sofort stoppen.
            self.playing = false
        } else if note.period > 0 {
            let activeInst = self.setInstrument ?? self.instrument
            let finetune = Float(activeInst?.finetune ?? 0)
            // Gleiche Finetune-Näherung wie im HTML-Worklet: Period minus
            // signed nibble. Das hält Swift und Browser klanglich synchron.
            self.setPeriod = Float(note.period) - finetune
            self.setCurrentPeriod = true
            self.setSampleIndex = 0.0
        } else if note.key >= 0 {
            // S3M: Period aus Halbton-Key + C2Spd des (neuen oder laufenden)
            // Instruments berechnen.
            let activeInst = self.setInstrument ?? self.instrument
            self.setPeriod = DSPChannel.s3mPeriod(key: note.key, c2spd: activeInst?.c2spd ?? 8363)
            self.setCurrentPeriod = true
            self.setSampleIndex = 0.0
        }

        // S3M-Volume-Column überschreibt die Instrument-Default-Lautstärke.
        if note.volume >= 0 {
            self.setVolume = Float(min(64, note.volume))
        }

        self.applyEffect(note: note)
        
        if self.delayNote > 0 {
            return
        }
        
        if hasSetInstrument {
            self.instrument = self.setInstrument
        }
        
        if let vol = self.setVolume {
            self.volume = vol
            self.currentVolume = vol
        }
        
        if let per = self.setPeriod {
            self.period = per
        }
        
        if self.setCurrentPeriod {
            self.currentPeriod = self.period
        }
        
        if let idx = self.setSampleIndex {
            self.sampleIndex = idx
            self.playing = true
        }
    }
    
    public func applyEffect(note: Note) {
        self.volumeSlide = 0
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
        
        switch effectId {
        case 0x00: // ARPEGGIO
            if effectData > 0 {
                self.arpActive = true
                self.arpX = effectHigh
                self.arpY = effectLow
            }
        case 0x01: // SLIDE_UP
            self.periodDelta = -Float(effectData)
        case 0x02: // SLIDE_DOWN
            self.periodDelta = Float(effectData)
        case 0x03: // TONE_PORTAMENTO
            self.portamento = true
            if effectData > 0 {
                // S3M-Perioden sind 4x feiner -> Gxx slidet mit 4-fachem Schritt.
                self.portamentoSpeed = Float(effectData) * (s3mMode ? 4.0 : 1.0)
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
            if s3mMode {
                // S3M Lxy: Volume-Slide-Teil mit voller Dxy-Semantik (Memory,
                // Fine-Slides).
                applyS3MVolumeSlide(param: effectData)
            } else if effectHigh > 0 {
                self.volumeSlide = Float(effectHigh)
            } else if effectLow > 0 {
                self.volumeSlide = -Float(effectLow)
            }
        case 0x06: // VIBRATO_WITH_VOLUME_SLIDE
            self.vibrato = true
            if s3mMode {
                // S3M Kxy: analog zu Lxy.
                applyS3MVolumeSlide(param: effectData)
            } else if effectHigh > 0 {
                self.volumeSlide = Float(effectHigh)
            } else if effectLow > 0 {
                self.volumeSlide = -Float(effectLow)
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
            } else if effectHigh > 0 {
                self.volumeSlide = Float(effectHigh)
            } else if effectLow > 0 {
                self.volumeSlide = -Float(effectLow)
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
        default:
            break
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
            self.currentPeriod = self.period / Float(pow(2.0, Double(Float(semis) / 12.0)))
        }
        else if self.retrigger > 0 && (tick % self.retrigger) == 0 {
            self.sampleIndex = 0.0
        }
        else if self.delayNote >= 0 && self.delayNote == tick {
            self.instrument = self.setInstrument
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

        if self.currentPeriod < self.periodMin { self.currentPeriod = self.periodMin }
        if self.currentPeriod > self.periodMax { self.currentPeriod = self.periodMax }
        
        if self.currentPeriod > 0, sampleRate > 0 {
            let paulaHz = clockRate / Double(self.currentPeriod)
            let speed = paulaHz / sampleRate
            self.sampleSpeed = speed.isNaN || speed.isInfinite ? 0.0 : speed
        } else {
            self.sampleSpeed = 0.0
        }
        
        if self.cutNoteTick == tick {
            self.currentVolume = 0.0
        }
    }
}
