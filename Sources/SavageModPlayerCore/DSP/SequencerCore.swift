// Gemeinsamer, allokationsfreier Sequencer fuer Live-, Offline- und Probe-
// Wiedergabe. Alle Funktionen sind statisch dispatcht; der Audio-Thread bekommt
// nur bereits vorhandene Zustands-, Kanal- und Modulwerte uebergeben.
enum SequencerCore {

    // OpenMPT-Timingformeln: Classic = 2,5/BPM Sekunden pro Tick,
    // Alternative = 1/BPM und Modern = 60/(BPM*Speed*RowsPerBeat).
    @inline(__always)
    static func recalculateTickDuration(
        state: RealtimePlaybackState,
        sampleRate: Double
    ) {
        let tempo = Double(max(1, state.bpm))
        switch state.tempoMode {
        case .classic:
            state.outputsPerTick = sampleRate * 60.0 / (tempo * 24.0)
        case .alternative:
            state.outputsPerTick = sampleRate / tempo
        case .modern:
            state.outputsPerTick = sampleRate * 60.0
                / (tempo * Double(max(1, state.ticksPerRow)) * Double(max(1, state.rowsPerBeat)))
        }
    }

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
                channels.first?.itVoicePool?.beginPatternDelayRepeat()
            } else if state.patternDelay > 0 {
                // IT-SEx wiederholt die aktuelle Zeile genau x-mal; der
                // Übergang startet bereits die erste Wiederholung. MOD-EE2
                // behält den seit M0 eingefrorenen historischen Trace.
                state.patternDelayCounter = mod.format == .it
                    ? max(0, state.patternDelay - 1)
                    : state.patternDelay
                state.patternDelay = 0
                state.tick = 0
                channels.first?.itVoicePool?.beginPatternDelayRepeat()
            } else {
                state.tick = 0
                advanceRow(state: state, channels: channels, mod: mod, sampleRate: sampleRate)
            }
        }

        // IT-Tempo-Slides wirken nur auf den Folgeticks der aktuellen Zeile.
        if mod.format == .it, state.tempoSlide != 0, state.tick > 0 {
            state.bpm = max(32, min(255, state.bpm + state.tempoSlide))
            recalculateTickDuration(state: state, sampleRate: sampleRate)
        }
        if mod.format == .it, state.tick > 0 {
            var channelSlides = state.globalVolumeSlide
            if let patternStates = channels.first?.itVoicePool?.patternChannels {
                channelSlides = 0
                for patternState in patternStates {
                    channelSlides += patternState.globalVolumeSlide
                }
            }
            if channelSlides != 0 {
                state.globalVolume = max(
                    0,
                    min(128, state.globalVolume + Float(channelSlides))
                )
            }
        }
        // XM Hxy: globales Volume-Slide wirkt wie alle XM-Slides nur auf den
        // Folgeticks der Zeile; die XM-Skala ist 0...64 (IT nutzt 0...128).
        if mod.format == .xm, state.globalVolumeSlide != 0, state.tick > 0 {
            state.globalVolume = max(
                0,
                min(64, state.globalVolume + Float(state.globalVolumeSlide))
            )
        }

        let clockRate = state.clockRateOverride > 0
            ? state.clockRateOverride
            : (state.palClock ? 3546894.6 : 3579545.25)
        if let pool = channels.first?.itVoicePool, pool.usesBackgroundVoices {
            pool.performPatternChannelTick(tick: state.tick, voices: channels)
            pool.compactActiveVoices(channels)
            for position in 0..<pool.activeVoiceCount {
                let index = pool.activeVoiceIndex(at: position)
                channels[index].performTick(
                    tick: state.tick,
                    sampleRate: sampleRate,
                    clockRate: clockRate,
                    ticksPerRow: state.ticksPerRow
                )
            }
        } else {
            channels.first?.itVoicePool?.performPatternChannelTick(
                tick: state.tick,
                voices: channels
            )
            for i in 0..<channels.count {
                channels[i].performTick(
                    tick: state.tick,
                    sampleRate: sampleRate,
                    clockRate: clockRate,
                    ticksPerRow: state.ticksPerRow
                )
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
        if mod.format == .it, state.rowTickDelay > 0 {
            state.ticksPerRow = max(1, state.ticksPerRow - state.rowTickDelay)
            state.rowTickDelay = 0
        }
        var targetPosition = state.position
        var targetRow = state.rowIndex + 1
        let sourcePosition = state.position
        var followedBackwardJump = false

        if state.patternLoopRow >= 0 {
            targetRow = state.patternLoopRow
            state.patternLoopRow = -1
        } else {
            if state.positionJump >= 0 {
                targetPosition = state.positionJump
                followedBackwardJump = targetPosition <= sourcePosition
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

        // Ein Bxx-Sprung auf eine bereits erreichte Position markiert denselben
        // Subsong-Loop, an dem openmpt123 bei --repeat 0 endet. Der Zielzustand
        // wird wie beim natuerlichen Wrap noch geladen; Offline-Renderer und UI
        // erhalten danach das einheitliche Endsignal.
        if followedBackwardJump {
            state.endReached = true
            if state.endReachedFrame == .max { state.endReachedFrame = state.elapsedFrames }
        }

        // Live/Offline werten das Signal aus. Die Probe behaelt es lediglich im
        // Zustand und laeuft wie bisher bis zum festen Frame-Limit weiter.
        if state.position >= mod.length {
            state.endReached = true
            if state.endReachedFrame == .max { state.endReachedFrame = state.elapsedFrames }
            state.position = max(0, min(mod.length - 1, state.restartPosition))
        }

        let positionIndex = max(0, min(mod.patternTable.count - 1, state.position))
        let patternIndex = mod.patternTable[positionIndex]
        guard patternIndex >= 0 && patternIndex < mod.patterns.count else { return }
        let pattern = mod.patterns[patternIndex]
        guard state.rowIndex >= 0 && state.rowIndex < pattern.rows.count else { return }
        let row = pattern.rows[state.rowIndex]
        let logicalChannelCount = min(mod.channelCount, row.notes.count)
        guard logicalChannelCount > 0 else { return }

        if mod.format == .it {
            state.tempoSlide = 0
            state.globalVolumeSlide = 0
            state.patternDelaySeen = false
            channels.first?.itVoicePool?.resetPatternChannelRowEffects()
        }
        if mod.format == .xm {
            // Hxy gilt nur auf Zeilen mit H-Befehl; ohne neuen Befehl endet
            // der globale Slide am Zeilenende.
            state.globalVolumeSlide = 0
        }
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
                    recalculateTickDuration(state: state, sampleRate: sampleRate)
                } else if value >= 0x10 {
                    state.tempoSlide = value & 0x0F
                } else {
                    state.tempoSlide = -(value & 0x0F)
                }
            case 22: // Vxx: IT Global Volume 0...128
                if note.effectData <= 128 {
                    state.globalVolume = Float(note.effectData)
                }
            case 23: // Wxy: Global Volume Slide
                let value = channel.itPatternState?.remembered(
                    command: command,
                    parameter: note.effectData
                ) ?? note.effectData
                let slide = applyITGlobalVolumeSlide(value, state: state)
                if let patternState = channel.itPatternState {
                    patternState.globalVolumeSlide = slide
                    state.globalVolumeSlide = 0
                } else {
                    state.globalVolumeSlide = slide
                }
            case 19: // Sxy: globale Sequencer-Unterbefehle
                applyITSpecial(
                    note.effectData,
                    channel: channel,
                    state: state
                )
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
                recalculateTickDuration(state: state, sampleRate: sampleRate)
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.setSpeed {
            if note.effectData > 0 {
                state.ticksPerRow = note.effectData
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.setTempo {
            if note.effectData >= 32 {
                state.bpm = note.effectData
                recalculateTickDuration(state: state, sampleRate: sampleRate)
            }
        } else if note.hasEffect && note.effectId == ModuleEffect.globalVolume {
            state.globalVolume = Float(min(64, max(0, note.effectData)))
        } else if note.hasEffect && note.effectId == ModuleEffect.globalVolumeSlide {
            // XM Hxy: x hebt, y senkt die globale Lautstärke pro Folgetick;
            // wie in FT2 gewinnt das Up-Nibble, wenn beide gesetzt sind.
            // Parameter 0 nutzt den letzten Nicht-Null-Parameter des Kanals.
            var value = note.effectData
            if value == 0 {
                value = channel.xmGlobalVolumeSlideMemory
            } else {
                channel.xmGlobalVolumeSlideMemory = value
            }
            let high = (value >> 4) & 0x0F
            let low = value & 0x0F
            state.globalVolumeSlide = high > 0 ? high : -low
        }
    }

    @inline(__always)
    private static func applyITGlobalVolumeSlide(
        _ parameter: Int,
        state: RealtimePlaybackState
    ) -> Int {
        let high = (parameter >> 4) & 0x0F
        let low = parameter & 0x0F
        if low == 0x0F, high > 0 {
            state.globalVolume = min(128, state.globalVolume + Float(high))
            return 0
        } else if high == 0x0F, low > 0 {
            state.globalVolume = max(0, state.globalVolume - Float(low))
            return 0
        } else if high > 0 {
            return high
        } else if low > 0 {
            return -low
        }
        return 0
    }

    @inline(__always)
    private static func applyITSpecial(
        _ parameter: Int,
        channel: DSPChannel,
        state: RealtimePlaybackState
    ) {
        let command = (parameter >> 4) & 0x0F
        let value = parameter & 0x0F
        switch command {
        case 6: // S6x: aktuelle Zeile um x Ticks verlängern
            if value > 0 {
                state.rowTickDelay += value
                state.ticksPerRow += value
            }
        case 11: // SBx: Pattern Loop
            if let patternState = channel.itPatternState {
                if value == 0 {
                    patternState.patternLoopStartRow = state.rowIndex
                } else {
                    if patternState.patternLoopCount < 0 {
                        patternState.patternLoopCount = value
                    }
                    if patternState.patternLoopCount > 0 {
                        patternState.patternLoopCount -= 1
                        state.patternLoopRow = patternState.patternLoopStartRow
                    } else {
                        patternState.patternLoopCount = -1
                    }
                }
            } else if value == 0 {
                channel.patternLoopStartRow = state.rowIndex
            } else {
                if channel.patternLoopCount < 0 { channel.patternLoopCount = value }
                if channel.patternLoopCount > 0 {
                    channel.patternLoopCount -= 1
                    state.patternLoopRow = channel.patternLoopStartRow
                } else {
                    channel.patternLoopCount = -1
                }
            }
        case 14: // SEx: Pattern Delay um x zusätzliche Rows
            if !state.patternDelaySeen {
                state.patternDelaySeen = true
                state.patternDelay = value
            }
        default:
            break
        }
    }
}
