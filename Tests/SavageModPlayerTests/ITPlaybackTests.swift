import XCTest
@testable import SavageModPlayerCore

final class ITPlaybackTests: XCTestCase {
    func testSixtyFourLogicalChannelsArePreallocatedWithIndependentState() {
        let mod = makeMod(
            rows: [Row(notes: [Note](repeating: emptyNote(), count: 64))],
            channelCount: 64,
            channelVolumes: Array(0..<64).map { $0 }
        )
        let channels = ModPlayerCoordinator.makeRenderChannels(for: mod)

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
            let channel = ModPlayerCoordinator.makeRenderChannels(for: mod)[0]
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
            let channel = ModPlayerCoordinator.makeRenderChannels(for: mod)[0]
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
        let channel = ModPlayerCoordinator.makeRenderChannels(for: mod)[0]
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
        XCTAssertEqual(channel.vibratoDepth, 4)
        channel.playNote(effect(11, 0x00), instruments: mod.instruments) // K00 nutzt D20
        XCTAssertTrue(channel.vibrato)
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentVolume, 38)

        channel.playNote(effect(12, 0x00), instruments: mod.instruments) // L00 nutzt D20
        XCTAssertTrue(channel.portamento)
        XCTAssertEqual(channel.volumeSlide, 2)
    }

    func testITArpeggioTremorOffsetRetriggerTremoloFineVibratoAndPanning() {
        let mod = makeMod(rows: [oneChannelRow()], linear: true)
        let channel = ModPlayerCoordinator.makeRenderChannels(for: mod)[0]
        channel.playNote(note(key: 60, instrument: 1, volume: 32), instruments: mod.instruments)
        let basePeriod = channel.currentPeriod

        channel.playNote(effect(10, 0x37), instruments: mod.instruments) // J37
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.currentPeriod, basePeriod - 3 * 64)

        channel.playNote(effect(9, 0x12), instruments: mod.instruments) // I12
        XCTAssertTrue(channel.tremorActive)
        XCTAssertEqual(channel.tremorOn, 2)
        XCTAssertEqual(channel.tremorOff, 3)

        channel.playNote(effect(15, 0x02), instruments: mod.instruments) // O02
        XCTAssertEqual(channel.sampleIndex, 512)

        channel.sampleIndex = 99
        channel.playNote(effect(17, 0x92), instruments: mod.instruments) // Q92
        channel.performTick(tick: 1, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 99)
        channel.performTick(tick: 2, sampleRate: 8_000, clockRate: 14_317_056)
        XCTAssertEqual(channel.sampleIndex, 0)
        XCTAssertEqual(channel.currentVolume, 33)

        channel.playNote(effect(18, 0x25), instruments: mod.instruments) // R25
        XCTAssertTrue(channel.tremolo)
        XCTAssertEqual(channel.tremoloSpeed, 2)
        XCTAssertEqual(channel.tremoloDepth, 5)

        channel.playNote(effect(21, 0x48), instruments: mod.instruments) // U48
        XCTAssertTrue(channel.vibrato)
        XCTAssertEqual(channel.vibratoSpeed, 4)
        XCTAssertEqual(channel.vibratoDepth, 2)

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
        let channel = ModPlayerCoordinator.makeRenderChannels(for: mod)[0]
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
        XCTAssertEqual(channel.currentPeriod, period + 8)
        channel.playNote(note(volume: 207), instruments: mod.instruments) // Vibrato depth 4
        XCTAssertTrue(channel.vibrato)
        XCTAssertEqual(channel.vibratoDepth, 4)
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
        let channels = ModPlayerCoordinator.makeRenderChannels(for: mod)
        let state = ModPlayerCoordinator.makeRenderState(for: mod, sampleRate: 2_400)

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
        sampleDefaultPanning: Int? = nil
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
            initialSpeed: 6,
            initialTempo: 125,
            initialGlobalVolume: 128,
            channelPannings: [Float](repeating: 0.5, count: channelCount),
            linearFrequency: linear,
            channelVolumes: channelVolumes,
            playbackSemantics: .impulseTracker(ITCompatibility(
                oldEffects: false, compatibleGxx: false
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
        let channels = ModPlayerCoordinator.makeRenderChannels(for: mod)
        let state = ModPlayerCoordinator.makeRenderState(for: mod, sampleRate: sampleRate)
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
