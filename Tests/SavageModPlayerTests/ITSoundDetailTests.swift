import XCTest
@testable import SavageModPlayerCore

/// Kleine, hardwarefreie Regressionen für die in M9 ergänzten IT-Klangdetails.
/// Die Werte folgen ITTECH sowie den Referenzimplementierungen von Schism und
/// OpenMPT; dadurch grenzen Fehler nicht erst in einem dichten Realweltmix ein.
final class ITSoundDetailTests: XCTestCase {
    private let sampleRate = 8_000.0
    private let clockRate = 14_317_056.0

    func testFilterCoefficientsMatchImpulseTrackerFormula() {
        let channel = voice(sample: sample())
        channel.setITFilterCutoff(64)
        channel.setITFilterResonance(32)
        channel.itFilterNeedsReset = true
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)

        let computedCutoff = 128.0
        let frequency = 110.0 * pow(2.0, computedCutoff * 128.0 / (24.0 * 256.0) + 0.25)
        let damping = pow(10.0, -3.0 * 32.0 / 320.0)
        let ratio = sampleRate / (2.0 * Double.pi * frequency)
        let d = damping * ratio + damping - 1.0
        let e = ratio * ratio
        let denominator = 1.0 + d + e

        XCTAssertTrue(channel.itFilterActive)
        XCTAssertEqual(channel.itFilterA0, Float(1.0 / denominator), accuracy: 0.000_001)
        XCTAssertEqual(channel.itFilterB0, Float((d + e + e) / denominator), accuracy: 0.000_001)
        XCTAssertEqual(channel.itFilterB1, Float(-e / denominator), accuracy: 0.000_001)
    }

    func testFilterEnvelopeChangesCutoffWithoutChangingBasePitch() throws {
        let filterEnvelope = Envelope(
            points: [EnvelopePoint(frame: 0, value: 0), EnvelopePoint(frame: 1, value: 64)],
            sustainStart: 0, sustainEnd: 0, loopStart: 0, loopEnd: 0,
            sustainEnabled: false, loopEnabled: false, valueMode: .filter
        )
        let instrument = try makeInstrument(
            pitchEnvelope: filterEnvelope,
            cutoff: 64,
            resonance: 16
        )
        let channel = instrumentVoice(instrument: instrument)
        channel.playNote(note(key: 60, instrument: 1), instruments: [nil, instrument])
        let basePeriod = channel.currentPeriod

        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        let closedA0 = channel.itFilterA0
        channel.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)

        XCTAssertGreaterThan(channel.itFilterA0, closedA0)
        XCTAssertEqual(channel.currentPeriod, basePeriod,
                       "Filter-Hüllkurve darf nicht als Pitch-Hüllkurve wirken")
    }

    func testCommonFilterMacrosAndDelayedNoteChangeOnlyAtTriggerTick() throws {
        let channel = voice(sample: sample())
        channel.playNote(effect(19, 0xF1), instruments: [])
        channel.playNote(effect(26, 0x40), instruments: [])
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.itFilterResonance, 64)
        XCTAssertTrue(channel.itFilterActive)

        channel.playNote(effect(19, 0xF0), instruments: [])
        channel.playNote(effect(26, 0x20), instruments: [])
        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.itFilterCutoff, 32)

        let instrument = try makeInstrument(cutoff: 16, resonance: 8)
        let delayed = instrumentVoice(instrument: instrument)
        let delayedNote = Note(
            instrument: 1,
            period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(19),
            effectData: 0xD2,
            key: 60,
            effectPresent: true
        )
        delayed.playNote(delayedNote, instruments: [nil, instrument])
        XCTAssertEqual(delayed.itFilterCutoff, 127)
        delayed.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        delayed.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(delayed.itFilterCutoff, 127,
                       "SDx darf die alte Voice vor dem Ziel-Tick nicht filtern")
        delayed.performTick(tick: 2, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(delayed.itFilterCutoff, 16)
        XCTAssertEqual(delayed.itFilterResonance, 8)
    }

    func testSampleVibratoUsesHeaderSpeedForPhaseAndRateForSweep() {
        let vibrato = ITSampleVibrato(speed: 64, depth: 8, rate: 64, waveform: .sine)
        let channel = voice(sample: sample(vibrato: vibrato))
        let baseSpeed = channel.sampleSpeed

        channel.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(channel.itSampleVibratoPosition, 64)
        XCTAssertEqual(channel.itSampleVibratoDepth, 64)
        for tick in 1...3 {
            channel.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
        }

        XCTAssertEqual(channel.itSampleVibratoPosition, 0)
        XCTAssertEqual(channel.itSampleVibratoDepth, 256)
        XCTAssertLessThan(channel.sampleSpeed, baseSpeed,
                          "Phase 192 der Sinuswelle muss die Frequenz senken")
    }

    func testRandomSampleVibratoAndInstrumentSwingAreDeterministicAndBounded() throws {
        let vibrato = ITSampleVibrato(speed: 1, depth: 32, rate: 255, waveform: .random)
        let first = voice(sample: sample(vibrato: vibrato))
        let second = voice(sample: sample(vibrato: vibrato))
        for tick in 0..<8 {
            first.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
            second.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
            XCTAssertEqual(first.sampleSpeed, second.sampleSpeed, accuracy: 0.000_001)
        }

        let instrument = try makeInstrument(
            pitchPanSeparation: 8,
            pitchPanCenter: 60,
            randomVolumeVariation: 100,
            randomPanningVariation: 64
        )
        let swungA = instrumentVoice(instrument: instrument)
        let swungB = instrumentVoice(instrument: instrument)
        swungA.playNote(note(key: 72, instrument: 1), instruments: [nil, instrument])
        swungB.playNote(note(key: 72, instrument: 1), instruments: [nil, instrument])

        XCTAssertEqual(swungA.itInstrumentVolumeWithSwing, swungB.itInstrumentVolumeWithSwing)
        XCTAssertEqual(swungA.itPanningSwing, swungB.itPanningSwing, accuracy: 0.000_001)
        XCTAssertTrue((0...128).contains(swungA.itInstrumentVolumeWithSwing))
        XCTAssertTrue((0...1).contains(swungA.effectivePanning))
        XCTAssertEqual(swungA.panning, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(swungA.itPitchPanOffset, 0.1875, accuracy: 0.000_001,
                       "Pitch-Pan verschiebt C-6 relativ zu C-5 um 12*8/512")
        swungA.playNote(note(key: 60), instruments: [nil, instrument])
        XCTAssertEqual(swungA.itPitchPanOffset, 0, accuracy: 0.000_001)
        XCTAssertEqual(swungA.panning, 0.5, accuracy: 0.000_001,
                       "Pitch-Pan darf sich bei instrumentlosen Folgenoten nicht aufsummieren")
    }

    func testSustainLoopHoldsThenReleasesIntoOneShotTail() {
        let held = Sample(
            pcm: [0.1, 0.2, 0.3, 0.4, 0.5],
            loopStart: 0, loopLength: 0, loopType: .none,
            volume: 64, finetune: 0,
            sustainLoop: SampleLoop(start: 1, length: 2, type: .forward),
            itProperties: ITSampleProperties(
                c5Speed: 8_000, globalVolume: 64, defaultPanning: nil
            )
        )
        let channel = voice(sample: held)
        let heldFrames = (0..<6).map { _ in
            RenderEngine.renderChannelStereoSampleForTesting(
                channel: channel, useInterpolation: false
            ).left
        }
        XCTAssertEqual(heldFrames, [0.1, 0.2, 0.3, 0.2, 0.3, 0.2])

        channel.keyReleased = true
        let releasedFrames = (0..<4).map { _ in
            RenderEngine.renderChannelStereoSampleForTesting(
                channel: channel, useInterpolation: false
            ).left
        }
        XCTAssertEqual(releasedFrames, [0.3, 0.4, 0.5, 0.0])
        XCTAssertFalse(channel.playing)
    }

    func testStereoPCMAndSurroundKeepIndependentPhases() {
        let stereo = Sample(
            pcm: [0.25, 0.25],
            loopStart: 0, loopLength: 2, loopType: .forward,
            volume: 64, finetune: 0,
            rightPCM: [-0.25, -0.25],
            itProperties: ITSampleProperties(
                c5Speed: 8_000, globalVolume: 64, defaultPanning: nil
            )
        )
        let channel = voice(sample: stereo)
        let frame = RenderEngine.renderChannelStereoSampleForTesting(
            channel: channel, useInterpolation: false
        )
        XCTAssertEqual(frame.left, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(frame.right, -0.25, accuracy: 0.000_001)

        let sharedState = ITPatternChannelState(channelVolume: 64, isSurround: true)
        channel.itPatternState = sharedState
        channel.itSurround = true
        channel.detachFromPatternEffects()
        let foreground = voice(sample: stereo)
        foreground.itPatternState = sharedState
        foreground.itSurround = true
        foreground.playNote(effect(19, 0x90), instruments: [])
        XCTAssertFalse(foreground.itSurround)
        XCTAssertTrue(channel.itSurround,
                      "eine NNA-Voice behält Surround nach einem Vordergrundwechsel")
    }

    func testRealFilterStereoAndRandomWaveformCorpusKeepsReferenceDuration() throws {
        let expectedDurations: [String: Double] = [
            "filter-nna.it": 2.400,
            "PanbrelloHold.it": 7.680,
            "RandomWaveform.it": 7.680,
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("audio/it-tests")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        for name in expectedDurations.keys.sorted() {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let module = try ITParser.parse(data: Data(contentsOf: url))
            let expected = try XCTUnwrap(expectedDurations[name])
            XCTAssertEqual(
                sequencedDuration(module, limit: expected + 1),
                expected,
                accuracy: 0.021,
                name
            )
            let outputDirectory = ProcessInfo.processInfo.environment["SAVAGE_IT_TEST_OUTPUT_DIR"]
            // Das reguläre Gate bleibt mit 8 kHz schnell. Für den expliziten
            // A/B-Lauf erzeugt dieselbe Testnaht kanonische 44,1-kHz-Dateien.
            let renderRate = outputDirectory == nil ? sampleRate : 44_100.0
            let wav = try ModuleRenderer.renderWavData(
                mod: module,
                sampleRate: renderRate,
                maxDurationSeconds: expected + 1,
                normalize: false,
                useInterpolation: false
            )
            XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 }, name)
            if let outputDirectory {
                try wav.write(to: URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent(name + ".wav"))
            }
        }
    }

    func testFilterNNAOutputFollowsEmbeddedReferenceStemSpectrally() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("audio/it-tests/filter-nna.it")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let module = try ITParser.parse(data: Data(contentsOf: url))
        var actual = [Float]()
        var reference = [Float]()
        _ = try ModuleRenderer.renderWavDataWithCapture(
            mod: module,
            sampleRate: sampleRate,
            maxDurationSeconds: 2.5,
            normalize: false,
            useInterpolation: false
        ) { block in
            actual.append(contentsOf: block.stems[0..<block.frameCount])
            let referenceStart = block.frameCount
            reference.append(contentsOf: block.stems[
                referenceStart..<(referenceStart + block.frameCount)
            ])
        }

        let correlation = rmsEnvelopeCorrelation(actual, reference, window: 80)
        XCTAssertGreaterThan(correlation, 0.95,
                             "Filter-/NNA-Hüllkurve muss dem eingebetteten Oracle folgen")
        let actualStart = actual.firstIndex { abs($0) > 0.000_001 } ?? -1
        let referenceStart = reference.firstIndex { abs($0) > 0.000_001 } ?? -1
        XCTAssertLessThanOrEqual(abs(actualStart - referenceStart), 8,
                                 "Onsets dürfen höchstens eine Millisekunde abweichen")
    }

    private func voice(sample: Sample) -> DSPChannel {
        let channel = DSPChannel(index: 1)
        channel.itMode = true
        channel.itLinearMode = true
        channel.periodMin = 1
        channel.periodMax = 7680
        channel.sample = sample
        channel.volume = 64
        channel.currentVolume = 64
        channel.period = 3840
        channel.currentPeriod = 3840
        channel.sampleSpeed = 1
        channel.playing = true
        channel.itPatternState = ITPatternChannelState(channelVolume: 64)
        return channel
    }

    private func instrumentVoice(instrument: Instrument) -> DSPChannel {
        let channel = voice(sample: instrument.samples[0])
        channel.itInstrumentMode = true
        channel.itSamplePool = [nil, instrument.samples[0]]
        return channel
    }

    private func sample(vibrato: ITSampleVibrato? = nil) -> Sample {
        Sample(
            pcm: [0.25, -0.25, 0.5, -0.5],
            loopStart: 0, loopLength: 4, loopType: .forward,
            volume: 64, finetune: 0,
            itProperties: ITSampleProperties(
                c5Speed: 8_000, globalVolume: 64, defaultPanning: nil,
                vibrato: vibrato
            )
        )
    }

    private func makeInstrument(
        pitchEnvelope: Envelope? = nil,
        cutoff: Int? = nil,
        resonance: Int? = nil,
        pitchPanSeparation: Int = 0,
        pitchPanCenter: Int = 60,
        randomVolumeVariation: Int = 0,
        randomPanningVariation: Int = 0
    ) throws -> Instrument {
        let mapping = try NoteSampleMapping(entries: try (0..<120).map {
            try NoteSampleMapping.Entry(targetNote: $0, sampleID: 1)
        })
        return Instrument(
            index: 1,
            name: "IT sound details",
            samples: [sample()],
            pitchEnvelope: pitchEnvelope,
            noteSampleMapping: mapping,
            itProperties: ITInstrumentProperties(
                newNoteAction: .cut,
                duplicateCheckType: .off,
                duplicateCheckAction: .cut,
                globalVolume: 128,
                defaultPanning: 32,
                pitchPanSeparation: pitchPanSeparation,
                pitchPanCenter: pitchPanCenter,
                randomVolumeVariation: randomVolumeVariation,
                randomPanningVariation: randomPanningVariation,
                initialFilterCutoff: cutoff,
                initialFilterResonance: resonance
            )
        )
    }

    private func note(key: Int, instrument: Int = 0) -> Note {
        Note(
            instrument: instrument, period: 0, effectId: 0, effectData: 0,
            key: key, effectPresent: false
        )
    }

    private func effect(_ command: Int, _ parameter: Int) -> Note {
        Note(
            instrument: 0, period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(command),
            effectData: parameter, effectPresent: true
        )
    }

    private func sequencedDuration(_ module: Mod, limit: Double) -> Double {
        let channels = RenderEngine.makeRenderChannels(for: module)
        let state = RenderEngine.makeRenderState(for: module, sampleRate: sampleRate)
        var frames = 0
        let frameLimit = Int(sampleRate * limit)
        while frames < frameLimit {
            SequencerCore.advanceIfNeeded(
                state: state, channels: channels, mod: module, sampleRate: sampleRate
            )
            if state.endReached { break }
            state.outputsUntilNextTick -= 1
            state.elapsedFrames += 1
            frames += 1
        }
        return Double(frames) / sampleRate
    }

    private func rmsEnvelopeCorrelation(
        _ left: [Float],
        _ right: [Float],
        window: Int
    ) -> Double {
        let count = min(left.count, right.count) / window
        guard count > 1 else { return 0 }
        let lhs = (0..<count).map { index -> Double in
            let range = (index * window)..<((index + 1) * window)
            return sqrt(left[range].reduce(0.0) { $0 + Double($1 * $1) } / Double(window))
        }
        let rhs = (0..<count).map { index -> Double in
            let range = (index * window)..<((index + 1) * window)
            return sqrt(right[range].reduce(0.0) { $0 + Double($1 * $1) } / Double(window))
        }
        let leftMean = lhs.reduce(0, +) / Double(count)
        let rightMean = rhs.reduce(0, +) / Double(count)
        var numerator = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        for index in 0..<count {
            let l = lhs[index] - leftMean
            let r = rhs[index] - rightMean
            numerator += l * r
            leftEnergy += l * l
            rightEnergy += r * r
        }
        return numerator / sqrt(max(Double.leastNonzeroMagnitude, leftEnergy * rightEnergy))
    }
}
