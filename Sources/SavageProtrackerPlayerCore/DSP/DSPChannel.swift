import Foundation

public final class DSPChannel: Sendable {
    public let channelIndex: Int
    
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
    
    // ProTracker loop / delay states
    nonisolated(unsafe) public var patternLoopStartRow: Int = 0
    nonisolated(unsafe) public var patternLoopCount: Int = -1
    nonisolated(unsafe) public var cutNoteTick: Int = -1
    nonisolated(unsafe) public var retrigger: Int = 0
    nonisolated(unsafe) public var delayNote: Int = 0
    nonisolated(unsafe) public var arpeggio: [Int]?
    
    // Mute, Solo and Interpolation
    nonisolated(unsafe) public var isMuted: Bool = false
    nonisolated(unsafe) public var isSoloed: Bool = false
    nonisolated(unsafe) public var useInterpolation: Bool = true
    
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
        patternLoopStartRow = 0
        patternLoopCount = -1
        cutNoteTick = -1
        retrigger = 0
        delayNote = 0
        arpeggio = nil
        isMuted = false
        isSoloed = false
        useInterpolation = true
        
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
        self.delayNote = 0
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
        
        if note.period > 0 {
            let activeInst = self.setInstrument ?? self.instrument
            let finetune = Float(activeInst?.finetune ?? 0)
            // Gleiche Finetune-Näherung wie im HTML-Worklet: Period minus
            // signed nibble. Das hält Swift und Browser klanglich synchron.
            self.setPeriod = Float(note.period) - finetune
            self.setCurrentPeriod = true
            self.setSampleIndex = 0.0
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
        self.arpeggio = nil
        self.retrigger = 0
        self.delayNote = 0
        
        guard note.hasEffect else { return }
        
        let effectId = note.effectId
        let effectData = note.effectData
        let effectHigh = note.effectHigh
        let effectLow = note.effectLow
        
        switch effectId {
        case 0x00: // ARPEGGIO
            if effectData > 0 {
                self.arpeggio = [0, effectHigh, effectLow]
            }
        case 0x01: // SLIDE_UP
            self.periodDelta = -Float(effectData)
        case 0x02: // SLIDE_DOWN
            self.periodDelta = Float(effectData)
        case 0x03: // TONE_PORTAMENTO
            self.portamento = true
            if effectData > 0 {
                self.portamentoSpeed = Float(effectData)
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
            if effectHigh > 0 {
                self.volumeSlide = Float(effectHigh)
            } else if effectLow > 0 {
                self.volumeSlide = -Float(effectLow)
            }
        case 0x06: // VIBRATO_WITH_VOLUME_SLIDE
            self.vibrato = true
            if effectHigh > 0 {
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
            self.setSampleIndex = Double(effectData) * 256.0
        case 0x0A: // VOLUME_SLIDE
            if effectHigh > 0 {
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
        default:
            break
        }
    }
    
    public func performTick(tick: Int, sampleRate: Double, clockRate: Double) {
        if self.volumeSlide != 0 && tick > 0 {
            self.currentVolume += self.volumeSlide
            if self.currentVolume < 0 { self.currentVolume = 0 }
            if self.currentVolume > 64 { self.currentVolume = 64 }
        }
        
        if self.vibrato {
            self.vibratoIndex = (self.vibratoIndex + self.vibratoSpeed).truncatingRemainder(dividingBy: 64)
            let sineVal = sin(self.vibratoIndex / 64.0 * .pi * 2.0)
            self.currentPeriod = self.period + Float(sineVal) * self.vibratoDepth
        }
        else if self.tremolo {
            self.tremoloIndex = (self.tremoloIndex + self.tremoloSpeed).truncatingRemainder(dividingBy: 64)
            let sineVal = sin(self.tremoloIndex / 64.0 * .pi * 2.0)
            let volDelta = Float(sineVal) * self.tremoloDepth
            self.currentVolume = max(0.0, min(64.0, self.volume + volDelta))
        }
        else if self.periodDelta != 0 {
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
        else if let arp = self.arpeggio, arp.count > 0 {
            let index = tick % arp.count
            let halfNotes = Float(arp[index])
            self.currentPeriod = self.period / Float(pow(2.0, Double(halfNotes / 12.0)))
        }
        else if self.retrigger > 0 && (tick % self.retrigger) == 0 {
            self.sampleIndex = 0.0
        }
        else if self.delayNote == tick {
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
            self.delayNote = 0
        }
        
        if self.currentPeriod < 113 { self.currentPeriod = 113 }
        if self.currentPeriod > 856 { self.currentPeriod = 856 }
        
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
