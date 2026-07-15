import XCTest
@testable import SavageModPlayerCore

final class ITPlaybackTests: XCTestCase {
    func testSequencedDurationStopsAtBackwardSubsongJump() {
        let mod = makeMod(rows: [
            oneChannelRow(),
            oneChannelRow(),
            oneChannelRow(),
            oneChannelRow(effect(2, 0)), // B00 beendet den Subsong nach Zeile 3.
        ])

        // 4 Zeilen * Speed 6 * 48 Frames/Tick bei 2.400 Hz und BPM 125.
        let duration = RenderEngine.sequencedDuration(
            of: mod,
            sampleRate: 2_400,
            maximumSeconds: 10
        )
        XCTAssertEqual(duration, 0.480, accuracy: 0.000_001)
    }

    func testSixtyFourLogicalChannelsArePreallocatedWithIndependentState() {
        let mod = makeMod(
            rows: [Row(notes: [Note](repeating: emptyNote(), count: 64))],
            channelCount: 64,
            channelVolumes: Array(0..<64).map { $0 }
        )
        let channels = RenderEngine.makeRenderChannels(for: mod)

        XCTAssertEqual(channels.count, 64)
        XCTAssertEqual(channels.first?.itVoicePool?.patternChannels.count, 64)
        XCTAssertEqual(channels.prefix(64).compactMap { $0.itPatternState }.count, 64)
        XCTAssertEqual(channels[0].itPatternState?.channelVolume, 0)
        XCTAssertEqual(channels[63].itPatternState?.channelVolume, 63)
        XCTAssertFalse(channels[0].itPatternState === channels[1].itPatternState)
    }

    func testC5SpeedDrivesLinearAndAmigaFrequencyModels() {
        for linear in [false, true] {
            let mod = makeMod(rows: [oneChannelRow()], linear: linear, c5Speed: 8_000)
            let channel = RenderEngine.makeRenderChannels(for: mod)[0]
            channel.playNote(note(key: 60, instrument: 1), instruments: mod.instruments)
            channel.performTick(tick: 0, sampleRate: 4_000, clockRate: 14_317_056)
            XCTAssertEqual(channel.sampleSpeed, 2, accuracy: 0.000_001, "linear=\(linear)")

            channel.playNote(note(key: 72, instrument: 1), instruments: mod.instruments)
            channel.performTick(tick: 0, sampleRate: 4_000, clockRate: 14_317_056)
            XCTAssertEqual(channel.sampleSpeed, 4, accuracy: 0.000_001, "linear=\(linear)")
        }
    }

    func testLinearAndAmigaPortamentoMovePitchInTheSameDirection() {
        for linear in [false, true] {
            let mod = makeMod(rows: [oneChannelRow()], linear: linear)
            let channel = RenderEngine.makeRenderChannels(for: mod)[0]
            channel.playNote(note(key: 60, instrument: 1), instruments: mod.instruments)
            channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
            let baseSpeed = channel.sampleSpeed

            channel.playNote(effect(5, 0x02), instruments: mod.instruments) // E02: tiefer
            channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
            XCTAssertLessThan(channel.sampleSpeed, baseSpeed, "linear=\(linear)")

            channel.playNote(effect(6, 0x04), instruments: mod.instruments) // F04: höher
            channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
            XCTAssertGreaterThan(channel.sampleSpeed, baseSpeed, "linear=\(linear)")
        }
    }

    func testITEffectMemorySlidesAndCombinedEffects() {
        let mod = makeMod(rows: [oneChannelRow()], linear: true)
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 32), instruments: mod.instruments)
        channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)

        channel.playNote(effect(4, 0x20), instruments: mod.instruments) // D20
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 34)
        channel.playNote(effect(4, 0x00), instruments: mod.instruments) // D00 wiederholt
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 36)

        let beforeDown = channel.currentPeriod
        channel.playNote(effect(5, 0x02), instruments: mod.instruments) // E02
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, beforeDown + 8)
        channel.playNote(effect(6, 0x02), instruments: mod.instruments) // F02
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, beforeDown)

        channel.playNote(effect(8, 0x34), instruments: mod.instruments) // H34
        XCTAssertTrue(channel.vibrato)
        XCTAssertEqual(channel.vibratoSpeed, 3)
        XCTAssertEqual(channel.vibratoDepth, 16)
        channel.playNote(effect(11, 0x00), instruments: mod.instruments) // K00 nutzt D20
        XCTAssertTrue(channel.vibrato)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 38)

        channel.playNote(effect(12, 0x00), instruments: mod.instruments) // L00 nutzt D20
        XCTAssertTrue(channel.portamento)
        XCTAssertEqual(channel.volumeSlide, 2)

        channel.playNote(effect(4, 0x1F), instruments: mod.instruments)
        XCTAssertEqual(channel.currentVolume, 39, "D1F wirkt genau auf Tick 0")
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 39)
        channel.playNote(effect(4, 0x12), instruments: mod.instruments)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 39, "gemischte Dxy-Nibbles sind wirkungslos")
    }

    func testITArpeggioTremorOffsetRetriggerTremoloFineVibratoAndPanning() {
        let mod = makeMod(rows: [oneChannelRow()], linear: true)
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 32), instruments: mod.instruments)
        let basePeriod = channel.currentPeriod

        channel.playNote(effect(10, 0x37), instruments: mod.instruments) // J37
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, basePeriod - 3 * 64)

        channel.playNote(effect(9, 0x12), instruments: mod.instruments) // I12
        XCTAssertTrue(channel.tremorActive)
        XCTAssertEqual(channel.tremorOn, 1)
        XCTAssertEqual(channel.tremorOff, 2)

        channel.playNote(effect(15, 0x02), instruments: mod.instruments) // O02
        XCTAssertEqual(channel.sampleIndex, 0, "neue IT-Effekte setzen Offset hinter Sampleende auf 0")

        channel.sampleIndex = 99
        channel.playNote(effect(17, 0x92), instruments: mod.instruments) // Q92
        channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 0,
                       "Qxy ohne neue Note übernimmt den laufenden Kanalzähler")
        XCTAssertEqual(channel.currentVolume, 33)
        channel.sampleIndex = 99
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 99)
        channel.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 0)
        XCTAssertEqual(channel.currentVolume, 34)

        channel.playNote(effect(18, 0x25), instruments: mod.instruments) // R25
        XCTAssertTrue(channel.tremolo)
        XCTAssertEqual(channel.tremoloSpeed, 2)
        XCTAssertEqual(channel.tremoloDepth, 5)

        channel.playNote(effect(21, 0x48), instruments: mod.instruments) // U48
        XCTAssertTrue(channel.vibrato)
        XCTAssertEqual(channel.vibratoSpeed, 4)
        XCTAssertEqual(channel.vibratoDepth, 8)

        channel.playNote(effect(24, 0x40), instruments: mod.instruments) // X40
        XCTAssertEqual(channel.panning, 64.0 / 255.0, accuracy: 0.000_001)

        channel.playNote(note(key: Note.keyFade), instruments: mod.instruments)
        XCTAssertTrue(channel.playing, "Note Fade ist im IT-Sample-Modus wirkungslos")
        channel.playing = false
        channel.sampleIndex = 77
        channel.playNote(effect(17, 0x02), instruments: mod.instruments)
        channel.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 77, "Qxy darf ein beendetes One-Shot nicht wiederbeleben")
    }

    func testITVolumeColumnAndIndependentVolumeScales() {
        let mod = makeMod(
            rows: [oneChannelRow()],
            channelVolumes: [32],
            sampleGlobalVolume: 48,
            sampleDefaultPanning: 16
        )
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 40), instruments: mod.instruments)
        XCTAssertEqual(channel.currentVolume, 40)
        XCTAssertEqual(channel.panning, 0.25)
        XCTAssertEqual(channel.itVolumeScale, 0.375)

        channel.playNote(note(volume: 90), instruments: mod.instruments) // Slide up 5
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 45)
        channel.playNote(note(volume: 160), instruments: mod.instruments) // Pan 32/64
        XCTAssertEqual(channel.panning, 0.5)
        let period = channel.currentPeriod
        channel.playNote(note(volume: 107), instruments: mod.instruments) // Pitch down 2
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, period + 32)
        channel.playNote(note(volume: 207), instruments: mod.instruments) // Vibrato depth 4
        XCTAssertTrue(channel.vibrato)
        XCTAssertEqual(channel.vibratoDepth, 16)
    }

    func testITSpeedTempoSlideGlobalVolumeAndHexPatternBreak() {
        let row0 = Row(notes: [effect(1, 3), effect(20, 0x40), effect(22, 128), emptyNote()])
        let row1 = Row(notes: [effect(20, 0x12), effect(22, 129), emptyNote(), emptyNote()])
        let row2 = Row(notes: [effect(2, 1), effect(3, 3), emptyNote(), emptyNote()])
        let first = SavageModPlayerCore.Pattern(rows: [row0, row1, row2])
        let second = SavageModPlayerCore.Pattern(rows: (0..<5).map { _ in
            Row(notes: [Note](repeating: emptyNote(), count: 4))
        })
        let mod = makeMod(patterns: [first, second], patternTable: [0, 1], channelCount: 4)
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: 2_400)

        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 0, Tick 0
        XCTAssertEqual(state.ticksPerRow, 3)
        XCTAssertEqual(state.bpm, 0x40)
        XCTAssertEqual(state.globalVolume, 128)

        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Tick 1
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Tick 2
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 1
        XCTAssertEqual(state.tempoSlide, 2)
        XCTAssertEqual(state.globalVolume, 128, "V81 ist ungültig und muss ignoriert werden")
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        XCTAssertEqual(state.bpm, 0x44)

        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 2
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Pos 1, Row 3
        XCTAssertEqual(state.position, 1)
        XCTAssertEqual(state.rowIndex, 3)

        let memoryMod = makeMod(
            rows: [oneChannelRow(effect(20, 0x12)), oneChannelRow(effect(20, 0x00))],
            initialSpeed: 2,
            initialTempo: 125
        )
        let memoryChannels = RenderEngine.makeRenderChannels(for: memoryMod)
        let memoryState = RenderEngine.makeRenderState(for: memoryMod, sampleRate: 2_400)
        for _ in 0..<4 {
            advanceTick(memoryState, channels: memoryChannels, mod: memoryMod, sampleRate: 2_400)
        }
        XCTAssertEqual(memoryState.bpm, 129, "T00 wiederholt den letzten Tempo-Slide")
    }

    func testCompatibleGxxControlsSharedPitchMemory() {
        for compatible in [false, true] {
            let mod = makeMod(rows: [oneChannelRow()], compatibleGxx: compatible)
            let channel = RenderEngine.makeRenderChannels(for: mod)[0]
            channel.playNote(note(key: 60, instrument: 1), instruments: mod.instruments)

            channel.playNote(effect(5, 0x02), instruments: mod.instruments)
            channel.playNote(effect(7, 0x00), instruments: mod.instruments)
            XCTAssertEqual(channel.portamentoSpeed, compatible ? 0 : 8)

            channel.playNote(effect(7, 0x03), instruments: mod.instruments)
            XCTAssertEqual(channel.portamentoSpeed, 12)
            channel.playNote(effect(6, 0x00), instruments: mod.instruments)
            XCTAssertEqual(channel.periodDelta, compatible ? -8 : -12)
        }
    }

    func testOldEffectsChangeTickZeroTremorAndOutOfRangeOffset() {
        for oldEffects in [false, true] {
            let mod = makeMod(rows: [oneChannelRow()], oldEffects: oldEffects)
            let channel = RenderEngine.makeRenderChannels(for: mod)[0]
            channel.playNote(note(key: 60, instrument: 1), instruments: mod.instruments)

            channel.playNote(effect(8, 0x14), instruments: mod.instruments)
            let basePeriod = channel.period
            channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
            XCTAssertEqual(channel.vibratoIndex, oldEffects ? 0 : 4)
            if oldEffects {
                XCTAssertEqual(channel.currentPeriod, basePeriod)
                channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
                XCTAssertGreaterThan(channel.currentPeriod, basePeriod,
                                     "Old Effects kehrt IT-Vibrato um")
            } else {
                XCTAssertLessThan(channel.currentPeriod, basePeriod)
            }

            channel.playNote(effect(9, 0x12), instruments: mod.instruments)
            XCTAssertEqual(channel.tremorOn, oldEffects ? 2 : 1)
            XCTAssertEqual(channel.tremorOff, oldEffects ? 3 : 2)

            channel.playNote(effect(15, 0x02), instruments: mod.instruments)
            XCTAssertEqual(channel.sampleIndex, oldEffects ? 512 : 0)
            channel.playNote(effect(15, 0x00), instruments: mod.instruments)
            XCTAssertEqual(channel.sampleIndex, oldEffects ? 512 : 0, "O00 nutzt Oxx-Memory")
            if oldEffects {
                channel.playNote(effect(19, 0xA1), instruments: mod.instruments)
                channel.playNote(effect(15, 0x00), instruments: mod.instruments)
                XCTAssertEqual(channel.sampleIndex, 65_536 + 512,
                               "SAx ergänzt das erinnerte Oxx-Offset")
            }
        }
    }

    func testChannelVolumePanningAndGlobalSlidesUseIndependentMemory() {
        let row0 = Row(notes: [effect(22, 64)])
        let row1 = Row(notes: [effect(23, 0x20)])
        let row2 = Row(notes: [effect(23, 0x00)])
        let mod = makeMod(rows: [row0, row1, row2], initialSpeed: 3)
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let channel = channels[0]
        let pool = channel.itVoicePool!
        let patternState = pool.patternChannels[0]

        channel.playNote(effect(13, 32), instruments: mod.instruments)
        XCTAssertEqual(patternState.channelVolume, 32)
        channel.playNote(effect(14, 0x20), instruments: mod.instruments)
        pool.performPatternChannelTick(tick: 1, voices: channels)
        XCTAssertEqual(patternState.channelVolume, 34)
        channel.playNote(effect(14, 0x00), instruments: mod.instruments)
        pool.performPatternChannelTick(tick: 1, voices: channels)
        XCTAssertEqual(patternState.channelVolume, 36)
        channel.playNote(effect(14, 0x1F), instruments: mod.instruments)
        XCTAssertEqual(patternState.channelVolume, 37)

        channel.panning = 0.5
        patternState.channelPanning = 0.5
        channel.playNote(effect(16, 0x10), instruments: mod.instruments)
        pool.performPatternChannelTick(tick: 1, voices: channels)
        XCTAssertEqual(patternState.channelPanning, 0.5 - 1.0 / 64.0, accuracy: 0.000_001)
        channel.playNote(effect(16, 0x00), instruments: mod.instruments)
        pool.performPatternChannelTick(tick: 1, voices: channels)
        XCTAssertEqual(patternState.channelPanning, 0.5 - 2.0 / 64.0, accuracy: 0.000_001)

        let state = RenderEngine.makeRenderState(for: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 0
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 1
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        XCTAssertEqual(state.globalVolume, 66)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 2, W00
        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
        XCTAssertEqual(state.globalVolume, 70)
    }

    func testVolumeColumnMemoryIsSeparateAndPitchSlidesAreFourTimesEffectColumn() {
        let mod = makeMod(rows: [oneChannelRow()])
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 32), instruments: mod.instruments)

        channel.playNote(note(volume: 88), instruments: mod.instruments) // C3
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 35)
        channel.playNote(effect(4, 0x20), instruments: mod.instruments) // getrenntes Dxx-Memory
        channel.playNote(note(volume: 65), instruments: mod.instruments) // A0 nutzt weiter 3
        XCTAssertEqual(channel.currentVolume, 38)

        let base = channel.currentPeriod
        channel.playNote(note(volume: 107), instruments: mod.instruments) // E2 = E08
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, base + 32)
        channel.playNote(note(volume: 193), instruments: mod.instruments) // G0 teilt Memory
        XCTAssertEqual(channel.portamentoSpeed, 32)
    }

    func testAllRetriggerVolumeModesAndMemory() {
        let expected: [Float] = [
            32, 31, 30, 28, 24, 16, 32 * 2 / 3, 16,
            32, 33, 34, 36, 40, 48, 48, 64,
        ]
        for mode in 0...15 {
            let mod = makeMod(rows: [oneChannelRow()])
            let channel = RenderEngine.makeRenderChannels(for: mod)[0]
            channel.playNote(
                note(key: 60, instrument: 1, volume: 32),
                instruments: mod.instruments
            )
            channel.playNote(effect(17, (mode << 4) | 1), instruments: mod.instruments)
            channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
            XCTAssertEqual(channel.currentVolume, expected[mode], accuracy: 0.000_001, "Q\(mode)")
        }

        let mod = makeMod(rows: [oneChannelRow()])
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 32), instruments: mod.instruments)
        channel.playNote(effect(17, 0x91), instruments: mod.instruments)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        channel.playNote(effect(17, 0x00), instruments: mod.instruments)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 34, "Q00 muss Modus und Intervall wiederholen")

        let spanning = RenderEngine.makeRenderChannels(for: mod)[0]
        let noteWithQ = Note(
            instrument: 1,
            period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(17),
            effectData: 0x04,
            key: 60,
            volume: 32,
            effectPresent: true
        )
        spanning.playNote(noteWithQ, instruments: mod.instruments)
        spanning.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        spanning.sampleIndex = 99
        for tick in 1...3 {
            spanning.performTick(tick: tick, sampleRate: 8_000, clockRate: 14_317_056)
            XCTAssertEqual(spanning.sampleIndex, 99)
        }
        spanning.performTick(tick: 4, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(spanning.sampleIndex, 0)
        spanning.sampleIndex = 99
        spanning.performTick(tick: 5, sampleRate: 8_000, clockRate: 14_317_056)
        spanning.playNote(effect(17, 0x04), instruments: mod.instruments)
        spanning.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        spanning.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(spanning.sampleIndex, 99)
        spanning.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(spanning.sampleIndex, 0,
                       "Qxy-Zähler läuft über die Row-Grenze weiter")
    }

    func testFinePanningAndGlobalSlidesApplyOnlyOnTickZero() {
        let mod = makeMod(rows: [oneChannelRow()])
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let channel = channels[0]
        let patternState = channel.itPatternState!
        patternState.channelPanning = 0.5
        channel.panning = 0.5

        channel.playNote(effect(16, 0x1F), instruments: mod.instruments)
        XCTAssertEqual(patternState.channelPanning, 0.5 - 1.0 / 64.0, accuracy: 0.000_001)
        channel.playNote(effect(16, 0xF2), instruments: mod.instruments)
        XCTAssertEqual(patternState.channelPanning, 0.5 + 1.0 / 64.0, accuracy: 0.000_001)
        channel.itVoicePool?.performPatternChannelTick(tick: 1, voices: channels)
        XCTAssertEqual(patternState.channelPanning, 0.5 + 1.0 / 64.0, accuracy: 0.000_001)

        let rows = [oneChannelRow(effect(23, 0x2F)), oneChannelRow(effect(23, 0xF1))]
        let globalMod = makeMod(rows: rows, initialSpeed: 2)
        let globalChannels = RenderEngine.makeRenderChannels(for: globalMod)
        let state = RenderEngine.makeRenderState(for: globalMod, sampleRate: 2_400)
        state.globalVolume = 64
        advanceTick(state, channels: globalChannels, mod: globalMod, sampleRate: 2_400)
        XCTAssertEqual(state.globalVolume, 66)
        advanceTick(state, channels: globalChannels, mod: globalMod, sampleRate: 2_400)
        XCTAssertEqual(state.globalVolume, 66, "Fine Wxy darf auf Tick N nicht weiterlaufen")
        advanceTick(state, channels: globalChannels, mod: globalMod, sampleRate: 2_400)
        XCTAssertEqual(state.globalVolume, 65)
    }

    func testITWaveformsPanbrelloHighOffsetAndSurroundState() {
        let mod = makeMod(rows: [oneChannelRow()])
        let channel = RenderEngine.makeRenderChannels(for: mod)[0]
        let state = channel.itPatternState!
        channel.playNote(note(key: 60, instrument: 1), instruments: mod.instruments)

        channel.playNote(effect(19, 0x32), instruments: mod.instruments) // S32 square vibrato
        channel.playNote(effect(8, 0x14), instruments: mod.instruments)
        let base = channel.period
        channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, base - 16,
                       "IT-Square-Vibrato nutzt die 256er Tabelle mit ±64")

        channel.playNote(effect(19, 0x52), instruments: mod.instruments) // S52 square panbrello
        channel.playNote(effect(25, 0x14), instruments: mod.instruments)
        channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.effectivePanning, channel.panning + 0.125,
                       accuracy: 0.000_001)
        let heldPanbrello = channel.panbrelloDelta
        channel.playNote(note(), instruments: mod.instruments)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.panbrelloDelta, heldPanbrello, accuracy: 0.000_001,
                       "IT hält Panbrello über effektlose Rows")

        channel.playNote(effect(19, 0x53), instruments: mod.instruments) // S53 Random
        channel.playNote(effect(25, 0x31), instruments: mod.instruments)
        channel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        let randomHeld = channel.panbrelloDelta
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.panbrelloDelta, randomHeld, accuracy: 0.000_001)
        channel.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.panbrelloDelta, randomHeld, accuracy: 0.000_001)
        channel.performTick(tick: 3, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertNotEqual(channel.panbrelloDelta, randomHeld,
                          "Random-Panbrello übernimmt nach Yxys Haltedauer einen neuen Wert")
        channel.playNote(effect(25, 0x00), instruments: mod.instruments)
        XCTAssertEqual(channel.panbrelloSpeed, 3)
        XCTAssertEqual(channel.panbrelloDepth, 1, "Y00 wiederholt beide Parameter")

        let detachedDelta = channel.panbrelloDelta
        channel.detachFromPatternEffects()
        XCTAssertFalse(channel.panbrelloActive)
        XCTAssertEqual(channel.panbrelloDelta, detachedDelta,
                       "eine NNA-Stimme hält die letzte Auslenkung ohne weitere Phasenupdates")

        channel.playNote(effect(19, 0x37), instruments: mod.instruments)
        channel.playNote(effect(19, 0x44), instruments: mod.instruments)
        channel.playNote(effect(19, 0x5F), instruments: mod.instruments)
        XCTAssertEqual(state.vibratoWaveform, 0)
        XCTAssertEqual(state.tremoloWaveform, 0)
        XCTAssertEqual(state.panbrelloWaveform, 0,
                       "IT ignoriert ungültige Wellenformen zugunsten von Sinus")

        channel.playNote(effect(19, 0xA3), instruments: mod.instruments)
        channel.playNote(effect(15, 0x01), instruments: mod.instruments)
        XCTAssertEqual(channel.sampleIndex, 0, "neue Effekte resetten auch High-Offset hinter Sampleende")
        channel.playNote(effect(19, 0x91), instruments: mod.instruments)
        XCTAssertTrue(state.isSurround)
        channel.playNote(effect(19, 0x90), instruments: mod.instruments)
        XCTAssertFalse(state.isSurround)
    }

    func testITNoteCutDelayTickDelayPatternDelayAndPatternLoop() {
        let base = makeMod(rows: [oneChannelRow()])
        let delayedChannel = RenderEngine.makeRenderChannels(for: base)[0]
        let delayed = Note(
            instrument: 1,
            period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(19),
            effectData: 0xD2,
            key: 60,
            effectPresent: true
        )
        delayedChannel.playNote(delayed, instruments: base.instruments)
        delayedChannel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertFalse(delayedChannel.playing)
        delayedChannel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertFalse(delayedChannel.playing)
        delayedChannel.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertTrue(delayedChannel.playing)

        delayedChannel.playNote(effect(19, 0xC0), instruments: base.instruments)
        delayedChannel.performTick(tick: 0, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertTrue(delayedChannel.playing, "SC0 schneidet nach IT-Regeln erst auf Tick 1")
        delayedChannel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertFalse(delayedChannel.playing)

        let delayRows = [
            oneChannelRow(effect(19, 0x62)),
            oneChannelRow(effect(19, 0xE2)),
            oneChannelRow(effect(19, 0xB0)),
            oneChannelRow(effect(19, 0xB2)),
            oneChannelRow(),
        ]
        let mod = makeMod(rows: delayRows, initialSpeed: 2)
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: 2_400)

        advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) // Row 0
        XCTAssertEqual(state.ticksPerRow, 4)
        for _ in 0..<4 { advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400) }
        XCTAssertEqual(state.rowIndex, 1)
        XCTAssertEqual(state.ticksPerRow, 2)

        // SE2: Row 1 läuft initial plus exakt zwei Wiederholungen.
        var rowOneStarts = 1
        var previousTick = state.tick
        while state.rowIndex == 1 {
            advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
            if state.rowIndex == 1, state.tick == 0, previousTick != 0 { rowOneStarts += 1 }
            previousTick = state.tick
        }
        XCTAssertEqual(rowOneStarts, 3)
        XCTAssertEqual(state.rowIndex, 2)

        // SB0/SB2: Bereich 2...3 wird genau zweimal zusätzlich gespielt.
        var rowTwoVisits = 1
        while state.rowIndex < 4 && rowTwoVisits < 4 {
            let before = state.rowIndex
            advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
            if state.rowIndex == 2, before != 2 { rowTwoVisits += 1 }
        }
        XCTAssertEqual(rowTwoVisits, 3)
    }

    func testITPositionBreakLoopAndDelayComposeDeterministically() {
        let empty = emptyNote()
        let first = SavageModPlayerCore.Pattern(rows: [
            Row(notes: [effect(19, 0xB0), empty, empty, empty]),
            Row(notes: [effect(19, 0xB1), effect(19, 0xE1), empty, empty]),
            Row(notes: [effect(2, 1), effect(3, 3), empty, empty]),
        ])
        let second = SavageModPlayerCore.Pattern(rows: (0..<5).map { _ in
            Row(notes: [Note](repeating: empty, count: 4))
        })
        let mod = makeMod(
            patterns: [first, second],
            patternTable: [0, 1],
            channelCount: 4,
            initialSpeed: 2
        )
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: 2_400)
        var rowStarts: [(Int, Int)] = []
        var lastTick = -1
        for _ in 0..<30 {
            advanceTick(state, channels: channels, mod: mod, sampleRate: 2_400)
            if state.tick == 0, lastTick != 0 {
                rowStarts.append((state.position, state.rowIndex))
            }
            lastTick = state.tick
            if state.position == 1 { break }
        }
        XCTAssertEqual(
            rowStarts.map { "\($0.0):\($0.1)" },
            ["0:0", "0:1", "0:1", "0:0", "0:1", "0:1", "0:2", "1:3"]
        )
    }

    func testSampleModeITRendersDeterministicAudibleWav() throws {
        let noteRow = oneChannelRow(note(key: 60, instrument: 1, volume: 64))
        let empty = oneChannelRow()
        let mod = makeMod(rows: [noteRow, empty, empty, empty], linear: true)

        let first = try ModuleRenderer.renderWavData(
            mod: mod, sampleRate: 8_000, maxDurationSeconds: 1,
            normalize: false, useInterpolation: false
        )
        let second = try ModuleRenderer.renderWavData(
            mod: mod, sampleRate: 8_000, maxDurationSeconds: 1,
            normalize: false, useInterpolation: false
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(data: first.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertTrue(first.dropFirst(44).contains { $0 != 0 })
    }

    func testRealOpenMPTSampleModeCorpusParsesRendersAndKeepsDuration() throws {
        let expectedDurations: [String: Double] = [
            "LinearSlides.it": 2.560,
            "NoteFade-SmpMode.it": 3.840,
            "PortaSample.it": 0.480,
            "retrig-short.it": 3.840,
            "tremolo.it": 15.359,
            "vibrato.it": 15.359,
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("audio/it-tests")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension.lowercased() == "it" }), !files.isEmpty else { return }

        let supportedFiles = files.filter { expectedDurations[$0.lastPathComponent] != nil }
        for file in supportedFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let module = try ITParser.parse(data: Data(contentsOf: file))
            XCTAssertEqual(module.format, .it)
            XCTAssertEqual(module.itProperties?.usesInstruments, false)

            let sampleRate = 8_000.0
            let duration = sequencedDuration(mod: module, sampleRate: sampleRate)
            let expected = try XCTUnwrap(expectedDurations[file.lastPathComponent])
            XCTAssertEqual(duration, expected, accuracy: 0.021, file.lastPathComponent)

            let wav = try ModuleRenderer.renderWavData(
                mod: module,
                sampleRate: sampleRate,
                maxDurationSeconds: expected + 1,
                normalize: false,
                useInterpolation: false
            )
            XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 }, file.lastPathComponent)
        }
    }

    func testRealOpenMPTM8EffectFixturesKeepDurationAndRenderAudibly() throws {
        let expectedDurations: [String: Double] = [
            "GlobalVolFirstTick.it": 7.440,
            "PanbrelloHold.it": 7.680,
            "PatternDelay-NoteDelay.it": 1.075,
            "PatternDelays.it": 6.380,
            "RandomWaveform.it": 7.680,
            "VolColMemory.it": 6.180,
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("audio/it-tests")

        for name in expectedDurations.keys.sorted() {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let module = try ITParser.parse(data: Data(contentsOf: file))
            let expected = try XCTUnwrap(expectedDurations[name])
            XCTAssertEqual(
                sequencedDuration(mod: module, sampleRate: 8_000),
                expected,
                accuracy: 0.021,
                name
            )
            let wav = try ModuleRenderer.renderWavData(
                mod: module,
                sampleRate: 8_000,
                maxDurationSeconds: expected + 0.5,
                normalize: false,
                useInterpolation: false
            )
            XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 }, name)
            if let outputDirectory = ProcessInfo.processInfo.environment["SAVAGE_IT_TEST_OUTPUT_DIR"] {
                let comparisonWav = try ModuleRenderer.renderWavData(
                    mod: module,
                    sampleRate: 44_100,
                    maxDurationSeconds: expected + 0.5,
                    normalize: false,
                    useInterpolation: true
                )
                try comparisonWav.write(
                    to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".wav")
                )
            }
        }
    }

    func testRealVibratoFixtureMatchesEmbeddedReferenceStem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("audio/it-tests/vibrato.it")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let module = try ITParser.parse(data: Data(contentsOf: file))
        var actual: [Float] = []
        var reference: [Float] = []
        _ = try ModuleRenderer.renderWavDataWithCapture(
            mod: module,
            sampleRate: 8_000,
            maxDurationSeconds: 16,
            normalize: false,
            useInterpolation: true
        ) { block in
            actual.append(contentsOf: block.stems[0..<block.frameCount])
            let start = block.frameCount
            reference.append(contentsOf: block.stems[start..<(start + block.frameCount)])
        }
        let actualRMS = sqrt(actual.reduce(0.0) { $0 + Double($1 * $1) } / Double(actual.count))
        let referenceRMS = sqrt(reference.reduce(0.0) { $0 + Double($1 * $1) } / Double(reference.count))
        let actualStart = actual.firstIndex(where: { abs($0) > 0.000_001 }) ?? -1
        let referenceStart = reference.firstIndex(where: { abs($0) > 0.000_001 }) ?? -1
        func crossings(_ values: [Float]) -> [Int] {
            (0..<min(32, values.count / 960)).map { row in
                let start = row * 960
                let end = min(values.count, start + 960)
                return (start + 1..<end).reduce(0) { count, index in
                    count + (values[index - 1] <= 0 && values[index] > 0 ? 1 : 0)
                }
            }
        }
        let actualCrossings = crossings(actual)
        let referenceCrossings = crossings(reference)
        let meanCrossingError = Double(zip(actualCrossings, referenceCrossings)
            .map { abs($0 - $1) }
            .reduce(0, +)) / Double(max(1, actualCrossings.count))
        XCTAssertEqual(actualStart, referenceStart, accuracy: 2)
        XCTAssertEqual(actualRMS, referenceRMS, accuracy: 0.02)
        XCTAssertLessThanOrEqual(meanCrossingError, 0.5,
                                 "Vibrato-Pitchverlauf muss pro Row der eingebetteten Referenz folgen")
    }

    // MARK: - Kleine synthetische IT-Modelle

    private func makeMod(
        rows: [Row] = [],
        patterns: [SavageModPlayerCore.Pattern]? = nil,
        patternTable: [Int] = [0],
        linear: Bool = true,
        c5Speed: Int = 8_000,
        channelCount: Int = 1,
        channelVolumes: [Int] = [],
        sampleGlobalVolume: Int = 64,
        sampleDefaultPanning: Int? = nil,
        oldEffects: Bool = false,
        compatibleGxx: Bool = false,
        initialSpeed: Int = 6,
        initialTempo: Int = 125
    ) -> Mod {
        let pcm = (0..<128).map { Float(($0 % 32) - 16) / 32.0 }
        let sample = Sample(
            pcm: pcm,
            loopStart: 0,
            loopLength: pcm.count,
            loopType: .forward,
            volume: 64,
            finetune: 0,
            name: "IT sample",
            itProperties: ITSampleProperties(
                c5Speed: c5Speed,
                globalVolume: sampleGlobalVolume,
                defaultPanning: sampleDefaultPanning
            )
        )
        let instrument = Instrument(index: 1, name: "IT sample", samples: [sample])
        let actualPatterns = patterns ?? [SavageModPlayerCore.Pattern(
            rows: rows.isEmpty ? [oneChannelRow()] : rows
        )]
        return Mod(
            name: "IT playback",
            length: patternTable.count,
            patternTable: patternTable,
            instruments: [nil, instrument],
            samplePool: [nil, sample],
            patterns: actualPatterns,
            channelCount: channelCount,
            format: .it,
            initialSpeed: initialSpeed,
            initialTempo: initialTempo,
            initialGlobalVolume: 128,
            channelPannings: [Float](repeating: 0.5, count: channelCount),
            linearFrequency: linear,
            channelVolumes: channelVolumes,
            playbackSemantics: .impulseTracker(ITCompatibility(
                oldEffects: oldEffects, compatibleGxx: compatibleGxx
            ))
        )
    }

    private func oneChannelRow(_ value: Note? = nil) -> Row {
        Row(notes: [value ?? emptyNote()])
    }

    private func note(
        key: Int = -1,
        instrument: Int = 0,
        volume: Int = -1
    ) -> Note {
        Note(
            instrument: instrument, period: 0, effectId: 0, effectData: 0,
            key: key, volume: volume, effectPresent: false
        )
    }

    private func effect(_ command: Int, _ parameter: Int) -> Note {
        Note(
            instrument: 0, period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(command),
            effectData: parameter, effectPresent: true
        )
    }

    private func emptyNote() -> Note { note() }

    private func advanceTick(
        _ state: RealtimePlaybackState,
        channels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) {
        state.outputsUntilNextTick = 0
        SequencerCore.advanceIfNeeded(
            state: state, channels: channels, mod: mod, sampleRate: sampleRate
        )
    }


    // Framegenaue Sequencer-Dauer ohne WAV-Blockrundung. Der erste Frame nach
    // dem Songende gehört bereits zum Wrap und wird deshalb nicht mitgezählt.
    private func sequencedDuration(mod: Mod, sampleRate: Double) -> Double {
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: sampleRate)
        let frameLimit = Int(sampleRate * 60)
        var frames = 0
        while frames < frameLimit {
            SequencerCore.advanceIfNeeded(
                state: state, channels: channels, mod: mod, sampleRate: sampleRate
            )
            if state.endReached { break }
            state.outputsUntilNextTick -= 1
            state.elapsedFrames += 1
            frames += 1
        }
        return Double(frames) / sampleRate
    }
}
