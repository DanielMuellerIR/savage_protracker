import XCTest
@testable import SavageModPlayerCore

final class ITInstrumentPlaybackTests: XCTestCase {
    private let sampleRate = 8_000.0
    private let clockRate = 14_317_056.0

    func testNotemapTransposesSelectsGlobalSampleAndAppliesVolumeAndPanScales() throws {
        let first = sample(volume: 64, c5Speed: 8_000, globalVolume: 64, defaultPanning: 48)
        let second = sample(volume: 32, c5Speed: 16_000, globalVolume: 32, defaultPanning: 48)
        let transposingMapping = try mapping(overrides: [60: (72, 2)])
        let instrument = makeInstrument(
            index: 1, samples: [first, second], mapping: transposingMapping,
            globalVolume: 64, defaultPanning: 16
        )
        let channel = makeChannel(channelVolume: 32, samplePool: [first, second])

        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])
        XCTAssertEqual(channel.sample?.volume, 32)
        XCTAssertEqual(channel.period, DSPChannel.itLinearPeriod(key: 72))
        XCTAssertEqual(channel.currentVolume, 32)
        XCTAssertEqual(channel.panning, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(channel.itVolumeScale, 0.125, accuracy: 0.000_001)

        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.sampleSpeed, 4, accuracy: 0.000_001)

        let noSampleMapping = try mapping(overrides: [61: (61, 0)])
        let noSampleInstrument = makeInstrument(
            index: 1, samples: [first, second], mapping: noSampleMapping
        )
        channel.sampleIndex = 2
        channel.playNote(note(key: 61, instrument: 1), instruments: [nil, noSampleInstrument])
        XCTAssertTrue(channel.playing)
        XCTAssertEqual(channel.sample?.volume, 32)
        XCTAssertEqual(channel.sampleIndex, 2, "leerer IT-Map-Slot darf die laufende Stimme nicht schneiden")
    }

    func testSustainRangeLoopsUntilNoteOffThenReleasesAndFades() throws {
        let envelope = Envelope(
            points: [
                EnvelopePoint(frame: 0, value: 64),
                EnvelopePoint(frame: 2, value: 48),
                EnvelopePoint(frame: 4, value: 16),
            ],
            sustainStart: 1,
            sustainEnd: 2,
            loopStart: 0,
            loopEnd: 0,
            sustainEnabled: true,
            loopEnabled: false
        )
        let instrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(),
            volumeEnvelope: envelope, fadeout: 512
        )
        let channel = makeChannel(samplePool: instrument.samples)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])

        for tick in 0..<5 {
            channel.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
        }
        XCTAssertEqual(channel.volEnvPos, 2, "Sustain-Ende muss inklusiv auf den Anfang zurückschleifen")
        XCTAssertFalse(channel.keyReleased)

        channel.playNote(note(key: Note.keyOff), instruments: [nil, instrument])
        XCTAssertTrue(channel.keyReleased)
        XCTAssertFalse(channel.noteFadeActive, "mit nicht geloopter Volume-Hüllkurve beginnt Fade erst am Ende")
        for tick in 0..<3 {
            channel.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
        }
        XCTAssertTrue(channel.noteFadeActive)
        XCTAssertLessThan(channel.fadeVolume, 65536)
        XCTAssertTrue(channel.playing)
    }

    func testNoteFadeCutAndOffWithoutEnvelopeRemainDistinct() throws {
        let instrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(), fadeout: 1024
        )
        let channel = makeChannel(samplePool: instrument.samples)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])

        channel.playNote(note(key: Note.keyFade), instruments: [nil, instrument])
        XCTAssertTrue(channel.noteFadeActive)
        XCTAssertFalse(channel.keyReleased, "Note Fade darf Sustain nicht freigeben")
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.fadeVolume, 65536 - 2048)
        XCTAssertTrue(channel.playing)

        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])
        channel.playNote(note(key: Note.keyOff), instruments: [nil, instrument])
        XCTAssertTrue(channel.keyReleased)
        XCTAssertTrue(channel.noteFadeActive, "IT Key-Off ohne Volume-Hüllkurve startet Fadeout")

        channel.playNote(note(key: Note.keyCut), instruments: [nil, instrument])
        XCTAssertFalse(channel.playing)
        XCTAssertEqual(channel.fadeVolume, 0)
    }

    func testNoteOffAtSustainEndReleasesOnNextPassLikeImpulseTracker() throws {
        let envelope = Envelope(
            points: [EnvelopePoint(frame: 0, value: 64), EnvelopePoint(frame: 1, value: 32)],
            sustainStart: 0, sustainEnd: 1, loopStart: 0, loopEnd: 0,
            sustainEnabled: true, loopEnabled: false
        )
        let instrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(),
            volumeEnvelope: envelope, fadeout: 64
        )
        let channel = makeChannel(samplePool: instrument.samples)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.volEnvPos, 1)

        channel.playNote(note(key: Note.keyOff), instruments: [nil, instrument])
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.volEnvPos, 0, "Key-Off am Sustain-Ende gilt erst nach diesem Tick")
        channel.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.volEnvPos, 1)
        channel.performTick(tick: 2, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertTrue(channel.noteFadeActive)
    }

    func testCarryPreservesOnlyEnabledEnvelopePositionsOnSameInstrument() throws {
        let carried = Envelope(
            points: [EnvelopePoint(frame: 0, value: 64), EnvelopePoint(frame: 10, value: 32)],
            sustainStart: 0, sustainEnd: 0, loopStart: 0, loopEnd: 0,
            sustainEnabled: false, loopEnabled: false, carryEnabled: true
        )
        let reset = Envelope(
            points: carried.points,
            sustainStart: 0, sustainEnd: 0, loopStart: 0, loopEnd: 0,
            sustainEnabled: false, loopEnabled: false, carryEnabled: false
        )
        let carriedInstrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(), volumeEnvelope: carried
        )
        let resetInstrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(), volumeEnvelope: reset
        )
        let channel = makeChannel(samplePool: carriedInstrument.samples)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, carriedInstrument])
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        channel.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.volEnvPos, 2)

        channel.playNote(note(key: 62, instrument: 1), instruments: [nil, carriedInstrument])
        XCTAssertEqual(channel.volEnvPos, 2)

        channel.playNote(note(key: 64, instrument: 1), instruments: [nil, resetInstrument])
        XCTAssertEqual(channel.volEnvPos, 0)
    }

    func testPanningAndPitchEnvelopesAffectVoiceWithoutChangingBasePeriod() throws {
        let panEnvelope = Envelope(
            points: [EnvelopePoint(frame: 0, value: 64)],
            sustainStart: 0, sustainEnd: 0, loopStart: 0, loopEnd: 0,
            sustainEnabled: false, loopEnabled: false
        )
        let pitchEnvelope = Envelope(
            points: [EnvelopePoint(frame: 0, value: 40)],
            sustainStart: 0, sustainEnd: 0, loopStart: 0, loopEnd: 0,
            sustainEnabled: false, loopEnabled: false, valueMode: .pitch
        )
        let instrument = makeInstrument(
            index: 1, samples: [sample()], mapping: try mapping(),
            panningEnvelope: panEnvelope, pitchEnvelope: pitchEnvelope,
            defaultPanning: 16
        )
        let channel = makeChannel(samplePool: instrument.samples)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])
        let basePeriod = channel.currentPeriod
        let baseSpeed = 1.0
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)

        XCTAssertEqual(channel.effectivePanning, 0.5, accuracy: 0.001)
        XCTAssertEqual(channel.currentPeriod, basePeriod, "Pitch-Envelope darf die Slide-Basis nicht akkumulieren")
        XCTAssertGreaterThan(channel.sampleSpeed, baseSpeed)
        XCTAssertEqual(channel.sampleSpeed, pow(2.0, 8.0 / 24.0), accuracy: 0.000_001)
    }

    func testRealOpenMPTNnaCutInstrumentCorpusParsesRendersAndKeepsDuration() throws {
        let expectedDurations: [String: Double] = [
            "NoteFade-InsMode.it": 3.840,
            "EnvLoops.it": 10.500,
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("audio/it-tests")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        for name in expectedDurations.keys.sorted() {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let module = try ITParser.parse(data: Data(contentsOf: file))
            XCTAssertTrue(module.itProperties?.usesInstruments == true, name)
            let instruments = module.instruments.compactMap { $0 }
            XCTAssertFalse(instruments.isEmpty, name)
            XCTAssertTrue(
                instruments.allSatisfy { $0.itProperties?.newNoteAction == .cut },
                "M6-Realweltgate enthält nur NNA=Cut: \(name)"
            )

            let sampleRate = 8_000.0
            let duration = sequencedDuration(mod: module, sampleRate: sampleRate)
            let expected = try XCTUnwrap(expectedDurations[name])
            XCTAssertEqual(duration, expected, accuracy: 0.021, name)
            let wav = try ModuleRenderer.renderWavData(
                mod: module,
                sampleRate: sampleRate,
                maxDurationSeconds: expected + 1,
                normalize: false,
                useInterpolation: false
            )
            XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 }, name)
            if let outputDirectory = ProcessInfo.processInfo.environment["SAVAGE_IT_TEST_OUTPUT_DIR"] {
                try wav.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".wav"))
            }
        }
    }

    private func makeChannel(channelVolume: Float = 64, samplePool: [Sample] = []) -> DSPChannel {
        let channel = DSPChannel(index: 1)
        channel.itMode = true
        channel.itLinearMode = true
        channel.itInstrumentMode = true
        channel.periodMin = 1
        channel.periodMax = 7680
        channel.itPatternState = ITPatternChannelState(channelVolume: Int(channelVolume))
        channel.itSamplePool = [nil] + samplePool.map(Optional.some)
        return channel
    }

    private func sequencedDuration(mod: Mod, sampleRate: Double) -> Double {
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: sampleRate)
        let frameLimit = Int(sampleRate * 30)
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

    private func sample(
        volume: Int = 64,
        c5Speed: Int = 8_000,
        globalVolume: Int = 64,
        defaultPanning: Int? = nil
    ) -> Sample {
        Sample(
            pcm: [0.25, -0.25, 0.5, -0.5],
            loopStart: 0,
            loopLength: 4,
            loopType: .forward,
            volume: volume,
            finetune: 0,
            itProperties: ITSampleProperties(
                c5Speed: c5Speed,
                globalVolume: globalVolume,
                defaultPanning: defaultPanning
            )
        )
    }

    private func mapping(overrides: [Int: (Int, Int)] = [:]) throws -> NoteSampleMapping {
        try NoteSampleMapping(entries: try (0..<120).map { note in
            let value = overrides[note] ?? (note, 1)
            return try NoteSampleMapping.Entry(targetNote: value.0, sampleID: value.1)
        })
    }

    private func makeInstrument(
        index: Int,
        samples: [Sample],
        mapping: NoteSampleMapping,
        volumeEnvelope: Envelope? = nil,
        panningEnvelope: Envelope? = nil,
        pitchEnvelope: Envelope? = nil,
        fadeout: Int = 0,
        globalVolume: Int = 128,
        defaultPanning: Int? = nil
    ) -> Instrument {
        Instrument(
            index: index,
            name: "IT instrument",
            samples: samples,
            volumeEnvelope: volumeEnvelope,
            panningEnvelope: panningEnvelope,
            fadeout: fadeout,
            pitchEnvelope: pitchEnvelope,
            noteSampleMapping: mapping,
            itProperties: ITInstrumentProperties(
                newNoteAction: .cut,
                duplicateCheckType: .off,
                duplicateCheckAction: .cut,
                globalVolume: globalVolume,
                defaultPanning: defaultPanning,
                pitchPanSeparation: 0,
                pitchPanCenter: 60,
                randomVolumeVariation: 0,
                randomPanningVariation: 0,
                initialFilterCutoff: nil,
                initialFilterResonance: nil
            )
        )
    }

    private func note(key: Int, instrument: Int = 0) -> Note {
        Note(
            instrument: instrument, period: 0, effectId: 0, effectData: 0,
            key: key, effectPresent: false
        )
    }
}
