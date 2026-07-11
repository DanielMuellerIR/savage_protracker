// Gemeinsamer, allokationsfreier Sequencer fuer Live-, Offline- und Probe-
// Wiedergabe. Alle Funktionen sind statisch dispatcht; der Audio-Thread bekommt
// nur bereits vorhandene Zustands-, Kanal- und Modulwerte uebergeben.
enum SequencerCore {

    // Prueft pro Audio-Frame zuerst die Tick-Grenze. Wenn ein Tick faellig ist,
    // bleibt die historische Reihenfolge erhalten: Tick/Delay, Row, globale
    // Effekte, playNote, performTick und zuletzt die naechste Tick-Frist.
    @inline(__always)
    static func advanceIfNeeded(
        state: RealtimePlaybackState,
        channels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) {
        guard state.outputsUntilNextTick <= 0 else { return }
        state.tick += 1
        if state.tick >= state.ticksPerRow {
            if state.patternDelayCounter > 0 {
                state.patternDelayCounter -= 1
                state.tick = 0
            } else if state.patternDelay > 0 {
                state.patternDelayCounter = state.patternDelay
                state.patternDelay = 0
                state.tick = 0
            } else {
                state.tick = 0
                advanceRow(state: state, channels: channels, mod: mod, sampleRate: sampleRate)
            }
        }

        // IT-Tempo-Slides wirken nur auf den Folgeticks der aktuellen Zeile.
        if mod.format == .it, state.tempoSlide != 0, state.tick > 0 {
            state.bpm = max(32, min(255, state.bpm + state.tempoSlide))
            state.outputsPerTick = sampleRate * 60.0 / (Double(state.bpm) * 24.0)
        }

        let clockRate = state.clockRateOverride > 0
            ? state.clockRateOverride
            : (state.palClock ? 3546894.6 : 3579545.25)
        if let pool = channels.first?.itVoicePool, pool.usesBackgroundVoices {
            pool.compactActiveVoices(channels)
            for position in 0..<pool.activeVoiceCount {
                let index = pool.activeVoiceIndex(at: position)
                channels[index].performTick(
                    tick: state.tick,
                    sampleRate: sampleRate,
                    clockRate: clockRate
                )
            }
        } else {
            for i in 0..<channels.count {
                channels[i].performTick(tick: state.tick, sampleRate: sampleRate, clockRate: clockRate)
            }
        }
        state.outputsUntilNextTick += state.outputsPerTick
    }

    @inline(__always)
    static func patternRowCount(_ mod: Mod, at position: Int) -> Int {
        let positionIndex = max(0, min(mod.patternTable.count - 1, position))
        let patternIndex = mod.patternTable[positionIndex]
        guard patternIndex >= 0 && patternIndex < mod.patterns.count else { return 64 }
        return mod.patterns[patternIndex].rows.count
    }

    @inline(__always)
    private static func advanceRow(
        state: RealtimePlaybackState,
        channels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) {
        var targetPosition = state.position
        var targetRow = state.rowIndex + 1

        if state.patternLoopRow >= 0 {
            targetRow = state.patternLoopRow
            state.patternLoopRow = -1
        } else {
            if state.positionJump >= 0 {
                targetPosition = state.positionJump
                targetRow = 0
                state.positionJump = -1
            }
            if state.patternBreak >= 0 {
                if targetPosition == state.position {
                    targetPosition = state.position + 1
                }
                targetRow = state.patternBreak
                state.patternBreak = -1
            } else if targetRow >= patternRowCount(mod, at: state.position) {
                targetRow = 0
                targetPosition = state.position + 1
            }
        }

        if mod.format == .it {
            let rowCount = max(1, patternRowCount(mod, at: targetPosition))
            targetRow = max(0, min(rowCount - 1, targetRow))
        }

        state.position = targetPosition
        state.rowIndex = targetRow

        // Live/Offline werten das Signal aus. Die Probe behaelt es lediglich im
        // Zustand und laeuft wie bisher bis zum festen Frame-Limit weiter.
        if state.position >= mod.length {
            state.endReached = true
            state.position = 0
        }

        let positionIndex = max(0, min(mod.patternTable.count - 1, state.position))
        let patternIndex = mod.patternTable[positionIndex]
        guard patternIndex >= 0 && patternIndex < mod.patterns.count else { return }
        let pattern = mod.patterns[patternIndex]
        guard state.rowIndex >= 0 && state.rowIndex < pattern.rows.count else { return }
        let row = pattern.rows[state.rowIndex]
        let logicalChannelCount = min(mod.channelCount, row.notes.count)
        guard logicalChannelCount > 0 else { return }

        if mod.format == .it { state.tempoSlide = 0 }
        for i in 0..<logicalChannelCount {
            let note = row.notes[i]
            let channel: DSPChannel
            if mod.format == .it,
               let pool = channels.first?.itVoicePool,
               i < pool.patternChannels.count {
                let voiceIndex = max(
                    0,
                    min(channels.count - 1, pool.patternChannels[i].foregroundVoiceIndex)
                )
                channel = channels[voiceIndex]
            } else {
                channel = channels[i]
            }
            applyGlobalEffect(
                note,
                channel: channel,
                state: state,
                sampleRate: sampleRate
            )
            if mod.format == .it, let pool = channels.first?.itVoicePool {
                pool.process(
                    note: note,
                    logicalChannel: i,
                    voices: channels,
                    instruments: mod.instruments
                )
            } else {
                channel.playNote(note, instruments: mod.instruments)
            }
        }
    }

    @inline(__always)
    private static func applyGlobalEffect(
        _ note: Note,
        channel: DSPChannel,
        state: RealtimePlaybackState,
        sampleRate: Double
    ) {
        if note.hasEffect,
           note.effectId > ModuleEffect.impulseTrackerCommandBase,
           note.effectId <= ModuleEffect.impulseTrackerCommandBase + 26 {
            let command = note.effectId - ModuleEffect.impulseTrackerCommandBase
            switch command {
            case 1: // Axx: Speed
                if note.effectData > 0 { state.ticksPerRow = note.effectData }
            case 2: // Bxx: Order-Sprung; Parser hat das Ziel bereits remappt.
                state.positionJump = note.effectData
            case 3: // Cxx: hexadezimale Zielzeile im nächsten Pattern.
                state.patternBreak = note.effectData
            case 20: // Txx: Tempo setzen oder pro Folgetick verschieben.
                let value = channel.itPatternState?.remembered(
                    command: command,
                    parameter: note.effectData
                ) ?? note.effectData
                if value >= 0x20 {
                    state.bpm = value
                    state.outputsPerTick = sampleRate * 60.0 / (Double(value) * 24.0)
                } else if value >= 0x10 {
                    state.tempoSlide = value & 0x0F
                } else {
                    state.tempoSlide = -(value & 0x0F)
                }
            case 22: // Vxx: IT Global Volume 0...128
                if note.effectData <= 128 {
                    state.globalVolume = Float(note.effectData)
                }
            default:
                break
            }
            return
        }

        if note.hasEffect && note.effectId == 0x0B {
            state.positionJump = note.effectData
        } else if note.hasEffect && note.effectId == 0x0D {
            // Ungueltige BCD-Zeilen oberhalb 63 bleiben wie bisher auf Row 0
            // geklemmt, damit der Sequencer nicht auf Phantom-Zeilen haengt.
            let row = note.effectHigh * 10 + note.effectLow
            state.patternBreak = row > 63 ? 0 : row
        } else if note.hasEffect && note.effectId == 0xE6 {
            if note.effectLow == 0 {
                channel.patternLoopStartRow = state.rowIndex
            } else {
                if channel.patternLoopCount < 0 {
                    channel.patternLoopCount = note.effectLow
                }
                if channel.patternLoopCount > 0 {
                    channel.patternLoopCount -= 1
                    state.patternLoopRow = channel.patternLoopStartRow
                } else {
                    channel.patternLoopCount = -1
                }
            }
        } else if note.hasEffect && note.effectId == 0xEE {
            if state.patternDelayCounter == 0 {
                state.patternDelay = note.effectLow
            }
        } else if note.hasEffect && note.effectId == 0x0F {
            if note.effectData >= 1 && note.effectData <= 31 {
                state.ticksPerRow = note.effectData
            } else if note.effectData > 0 {
                state.bpm = note.effectData
                state.outputsPerTick = sampleRate * 60.0 / (Double(note.effectData) * 24.0)
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.setSpeed {
            if note.effectData > 0 {
                state.ticksPerRow = note.effectData
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.setTempo {
            if note.effectData >= 32 {
                state.bpm = note.effectData
                state.outputsPerTick = sampleRate * 60.0 / (Double(note.effectData) * 24.0)
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.globalVolume {
            state.globalVolume = Float(min(64, max(0, note.effectData)))
        }
    }
}
