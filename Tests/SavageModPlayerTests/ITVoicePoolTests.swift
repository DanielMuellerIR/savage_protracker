import AVFoundation
import XCTest
@testable import SavageModPlayerCore

final class ITVoicePoolTests: XCTestCase {
    private let sampleRate = 8_000.0
    private let clockRate = 14_317_056.0

    func testAllNewNoteActionsKeepOneForegroundAndExpectedBackgroundState() throws {
        for action in [
            NewNoteAction.cut, .continuePlaying, .noteOff, .noteFade,
        ] {
            let setup = try makeSetup(newNoteAction: action)
            setup.pool.process(
                note: note(key: 48, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            let first = setup.voices[0]
            setup.pool.process(
                note: note(key: 52, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )

            let foreground = setup.voices[setup.pool.patternChannels[0].foregroundVoiceIndex]
            XCTAssertTrue(foreground.playing, "NNA \(action)")
            XCTAssertEqual(foreground.itTriggerNote, 52, "NNA \(action)")
            if action == .cut {
                XCTAssertTrue(foreground === first)
                XCTAssertFalse(foreground.itIsBackgroundVoice)
                XCTAssertEqual(setup.pool.activeVoiceCount, 1)
            } else {
                XCTAssertFalse(foreground === first)
                XCTAssertTrue(first.itIsBackgroundVoice)
                XCTAssertTrue(first.playing)
                XCTAssertEqual(setup.pool.activeVoiceCount, 2)
                XCTAssertEqual(first.keyReleased, action == .noteOff)
                XCTAssertEqual(first.noteFadeActive, action == .noteFade || action == .noteOff)
            }
        }
    }

    func testDuplicateTypesMatchOnlyTheirDocumentedIdentity() throws {
        for type in [DuplicateCheckType.note, .sample, .instrument] {
            let setup = try makeSetup(
                newNoteAction: .continuePlaying,
                duplicateCheckType: type,
                duplicateCheckAction: .noteFade
            )
            setup.pool.process(
                note: note(key: 48, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            let oldest = setup.voices[0]
            let nonDuplicateInstrument = type == .sample ? 1 : 2
            let nonDuplicateKey = type == .note ? 48 : 52
            setup.pool.process(
                note: note(key: nonDuplicateKey, instrument: nonDuplicateInstrument), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            XCTAssertFalse(oldest.noteFadeActive, "zweite Note darf für \(type) hier nicht treffen")

            let duplicateKey = type == .note ? 48 : 55 // 55 nutzt wie 48 Sample 1.
            setup.pool.process(
                note: note(key: duplicateKey, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            XCTAssertTrue(oldest.noteFadeActive, "DCT \(type) muss die ältere passende Stimme finden")
        }
    }

    func testEveryDuplicateActionWorksAcrossEveryNNAAndDCT() throws {
        let nnas: [NewNoteAction] = [.cut, .continuePlaying, .noteOff, .noteFade]
        let types: [DuplicateCheckType] = [.note, .sample, .instrument]
        let actions: [DuplicateCheckAction] = [.cut, .noteOff, .noteFade]

        for nna in nnas {
            for type in types {
                for action in actions {
                    let setup = try makeSetup(
                        newNoteAction: nna,
                        duplicateCheckType: type,
                        duplicateCheckAction: action
                    )
                    setup.pool.process(
                        note: note(key: 48, instrument: 1), logicalChannel: 0,
                        voices: setup.voices, instruments: setup.mod.instruments
                    )
                    let duplicate = setup.voices[0]
                    let oldGeneration = duplicate.itVoiceGeneration
                    setup.pool.process(
                        note: note(key: 48, instrument: 1),
                        logicalChannel: 0,
                        voices: setup.voices,
                        instruments: setup.mod.instruments
                    )

                    let context = "NNA/DCT/DCA \(nna)/\(type)/\(action)"
                    if action == .cut || nna == .cut {
                        XCTAssertEqual(setup.pool.activeVoiceCount, 1, context)
                        XCTAssertGreaterThan(duplicate.itVoiceGeneration, oldGeneration, context)
                    } else {
                        XCTAssertEqual(setup.pool.activeVoiceCount, 2, context)
                        XCTAssertTrue(duplicate.itIsBackgroundVoice, context)
                        XCTAssertEqual(
                            duplicate.keyReleased,
                            action == .noteOff || nna == .noteOff,
                            context
                        )
                        XCTAssertEqual(
                            duplicate.noteFadeActive,
                            action != .cut || nna == .noteOff || nna == .noteFade,
                            context
                        )
                    }
                }
            }
        }
    }

    func testS7xPastNoteActionsAndNextNNAOverrides() throws {
        for low in 0...2 {
            let setup = try makeSetup(newNoteAction: .continuePlaying)
            setup.pool.process(
                note: note(key: 48, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            let old = setup.voices[0]
            setup.pool.process(
                note: note(key: 52, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            setup.pool.process(
                note: s7Note(low: low), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            if low == 0 { XCTAssertFalse(old.playing) }
            if low == 1 { XCTAssertTrue(old.keyReleased) }
            if low == 2 { XCTAssertTrue(old.noteFadeActive) }
        }

        for low in 3...6 {
            let setup = try makeSetup(newNoteAction: .cut)
            setup.pool.process(
                note: note(key: 48, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            let old = setup.voices[0]
            setup.pool.process(
                note: s7Note(key: 52, instrument: 1, low: low), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
            let action = NewNoteAction(rawValue: low - 3)!
            if action == .cut {
                XCTAssertFalse(old.itIsBackgroundVoice)
                XCTAssertEqual(setup.pool.activeVoiceCount, 1)
            } else {
                XCTAssertTrue(old.itIsBackgroundVoice)
                XCTAssertEqual(old.keyReleased, action == .noteOff)
                XCTAssertEqual(old.noteFadeActive, action == .noteOff || action == .noteFade)
                XCTAssertEqual(setup.pool.activeVoiceCount, 2)
            }
        }
    }

    func testVoiceStealingIsQuietestThenOldestThenLowestIndex() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying)
        let owner = setup.pool.patternChannels[0]
        for index in 64..<setup.voices.count {
            let voice = setup.voices[index]
            voice.playing = true
            voice.itIsBackgroundVoice = true
            voice.itPatternState = owner
            voice.currentVolume = 32
            voice.itVoiceGeneration = UInt64(index)
        }
        setup.voices[90].currentVolume = 2
        setup.voices[90].itVoiceGeneration = 20
        setup.voices[91].currentVolume = 2
        setup.voices[91].itVoiceGeneration = 10
        setup.voices[92].currentVolume = 2
        setup.voices[92].itVoiceGeneration = 10

        XCTAssertEqual(
            setup.pool.selectVoiceIndex(owner: owner, excluding: 0, voices: setup.voices),
            91
        )
    }

    func testFullPoolOverflowReusesDeterministicOldestBackgroundSlot() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying)
        for pass in 0..<4 {
            for channel in 0..<64 {
                setup.pool.process(
                    note: note(key: 48 + ((pass + channel) % 12), instrument: 1),
                    logicalChannel: channel,
                    voices: setup.voices,
                    instruments: setup.mod.instruments
                )
            }
        }
        XCTAssertEqual(setup.pool.activeVoiceCount, 256)
        XCTAssertTrue(setup.voices[0].itIsBackgroundVoice)
        let oldestGeneration = setup.voices[0].itVoiceGeneration

        setup.pool.process(
            note: note(key: 60, instrument: 1), logicalChannel: 0,
            voices: setup.voices, instruments: setup.mod.instruments
        )
        XCTAssertEqual(setup.pool.activeVoiceCount, 256)
        XCTAssertEqual(setup.pool.patternChannels[0].foregroundVoiceIndex, 0)
        XCTAssertFalse(setup.voices[0].itIsBackgroundVoice)
        XCTAssertGreaterThan(setup.voices[0].itVoiceGeneration, oldestGeneration)
    }

    func testActiveListCompactsCutVoicesWithoutChangingOrder() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying)
        for key in 48..<52 {
            setup.pool.process(
                note: note(key: key, instrument: 1), logicalChannel: 0,
                voices: setup.voices, instruments: setup.mod.instruments
            )
        }
        XCTAssertEqual(setup.pool.activeVoiceCount, 4)
        let removed = setup.pool.activeVoiceIndex(at: 1)
        setup.voices[removed].applyITVoiceAction(.cut)
        setup.pool.compactActiveVoices(setup.voices)
        XCTAssertEqual(setup.pool.activeVoiceCount, 3)
        XCTAssertFalse((0..<setup.pool.activeVoiceCount).contains {
            setup.pool.activeVoiceIndex(at: $0) == removed
        })
    }

    func testBackgroundVoiceDropsPatternEffectsButContinuesEnvelopeAndFade() throws {
        let setup = try makeSetup(newNoteAction: .noteFade)
        setup.pool.process(
            note: note(key: 48, instrument: 1), logicalChannel: 0,
            voices: setup.voices, instruments: setup.mod.instruments
        )
        let old = setup.voices[0]
        old.volumeSlide = 3
        old.panSlide = 4
        old.periodDelta = 5
        old.portamento = true
        old.vibrato = true
        old.retrigger = 2

        setup.pool.process(
            note: note(key: 52, instrument: 1), logicalChannel: 0,
            voices: setup.voices, instruments: setup.mod.instruments
        )
        XCTAssertTrue(old.itIsBackgroundVoice)
        XCTAssertEqual(old.volumeSlide, 0)
        XCTAssertEqual(old.panSlide, 0)
        XCTAssertEqual(old.periodDelta, 0)
        XCTAssertFalse(old.portamento)
        XCTAssertFalse(old.vibrato)
        XCTAssertEqual(old.retrigger, 0)

        let fadeBefore = old.fadeVolume
        old.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertLessThan(old.fadeVolume, fadeBefore)
        XCTAssertTrue(old.playing)
    }

    func testForegroundMigrationKeepsInstrumentlessNotesAndEnvelopeCarry() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying, carryEnvelopes: true)
        setup.pool.process(
            note: note(key: 48, instrument: 1), logicalChannel: 0,
            voices: setup.voices, instruments: setup.mod.instruments
        )
        let old = setup.voices[0]
        old.volEnvPos = 7
        old.panEnvPos = 8
        old.pitchEnvPos = 9

        setup.pool.process(
            note: note(key: 52), logicalChannel: 0,
            voices: setup.voices, instruments: setup.mod.instruments
        )
        let migrated = setup.voices[setup.pool.patternChannels[0].foregroundVoiceIndex]
        XCTAssertFalse(migrated === old)
        XCTAssertEqual(migrated.instrument?.index, 1)
        XCTAssertEqual(migrated.itTriggerSampleID, 2)
        XCTAssertTrue(migrated.playing)
        XCTAssertEqual(migrated.volEnvPos, 7)
        XCTAssertEqual(migrated.panEnvPos, 8)
        XCTAssertEqual(migrated.pitchEnvPos, 9)

        // Auch NNA=Cut verwendet intern reset(); Carry darf dabei nicht fallen.
        let cut = try makeSetup(newNoteAction: .cut, carryEnvelopes: true)
        cut.pool.process(
            note: note(key: 48, instrument: 1), logicalChannel: 0,
            voices: cut.voices, instruments: cut.mod.instruments
        )
        cut.voices[0].volEnvPos = 11
        cut.pool.process(
            note: note(key: 55), logicalChannel: 0,
            voices: cut.voices, instruments: cut.mod.instruments
        )
        XCTAssertEqual(cut.voices[0].volEnvPos, 11)
        XCTAssertTrue(cut.voices[0].playing)
    }

    func testOwnerStemMuteVUAndScopeAggregateBackgroundVoices() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying)
        let empty = note(key: -1)
        func row(_ key: Int) -> Row {
            Row(notes: [note(key: key, instrument: 1)] + Array(repeating: empty, count: 63))
        }
        let pattern = SavageModPlayerCore.Pattern(rows: [row(48), row(52)])
        let module = moduleLike(
            setup.mod, patterns: [pattern], initialSpeed: 1, initialTempo: 125
        )
        let observed = try renderOwnerSignals(module)
        XCTAssertGreaterThan(observed.maxStem, 0.49, "Vorder- und Hintergrundvoice müssen im Besitzer-Stem addieren")
        XCTAssertGreaterThan(observed.vu, 0.49)
        XCTAssertGreaterThan(observed.scope, 0.49)
        XCTAssertTrue(observed.otherStemsAreSilent)
        XCTAssertGreaterThan(observed.maxStereo, 0)

        let muted = moduleLike(
            setup.mod,
            patterns: [pattern],
            initialSpeed: 1,
            initialTempo: 125,
            channelDisabled: [true] + Array(repeating: false, count: 63)
        )
        let mutedSignals = try renderOwnerSignals(muted)
        XCTAssertGreaterThan(mutedSignals.maxStem, 0.49, "Roh-Stem bleibt für Analyse vor Mute erhalten")
        XCTAssertEqual(mutedSignals.maxStereo, 0, accuracy: 0.000_001)
        XCTAssertEqual(mutedSignals.vu, 0, accuracy: 0.000_001)
        XCTAssertEqual(mutedSignals.scope, 0, accuracy: 0.000_001)
    }

    func testSixtyFourChannelVoiceStressStaysBoundedAndFasterThanRealtime() throws {
        let setup = try makeSetup(newNoteAction: .continuePlaying)
        let rows = (0..<200).map { rowIndex in
            Row(notes: (0..<64).map { channel in
                note(key: 48 + ((rowIndex + channel) % 12), instrument: 1)
            })
        }
        let stress = moduleLike(
            setup.mod,
            patterns: [SavageModPlayerCore.Pattern(rows: rows)],
            initialSpeed: 1,
            initialTempo: 255
        )
        let audioDuration = Double(rows.count) * 60.0 / (255.0 * 24.0)
        let started = Date().timeIntervalSinceReferenceDate
        let wav = try ModuleRenderer.renderWavData(
            mod: stress,
            sampleRate: sampleRate,
            maxDurationSeconds: audioDuration + 0.1,
            normalize: false,
            useInterpolation: false
        )
        let elapsed = Date().timeIntervalSinceReferenceDate - started

        XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 })
        #if DEBUG
        // Der Debug-Build trägt Bounds-/Exklusivitätsprüfungen in jeder Voice.
        // Er sichert hier gegen grobe Regressionen; das verbindliche
        // Echtzeitgate läuft zusätzlich mit `swift test -c release`.
        XCTAssertLessThan(elapsed, audioDuration * 3)
        #else
        XCTAssertLessThan(
            elapsed,
            audioDuration,
            "64-Kanal-/256-Voice-Releasepfad muss schneller als Echtzeit bleiben"
        )
        #endif
        XCTAssertEqual(ModPlayerCoordinator.makeRenderChannels(for: stress).count, 256)
    }

    func testRealOpenMPTCarryNNASongIsStructuredTimedAndAudible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("audio/it-tests/CarryNNA.it")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let module = try ITParser.parse(data: Data(contentsOf: file))
        let properties = module.instruments.compactMap { $0?.itProperties }
        XCTAssertTrue(properties.contains { $0.newNoteAction == .noteFade })
        XCTAssertTrue(module.instruments.compactMap { $0?.volumeEnvelope }.contains { $0.carryEnabled })

        let sequence = sequencedDuration(module, sampleRate: sampleRate, limit: 10)
        XCTAssertEqual(sequence.duration, 5.760, accuracy: 0.021)
        XCTAssertGreaterThan(sequence.maxActiveVoices, 2, "Realweltdatei muss NNA-Hintergrundvoices erzeugen")
        let wav = try ModuleRenderer.renderWavData(
            mod: module,
            sampleRate: 44_100,
            maxDurationSeconds: 6,
            normalize: false,
            useInterpolation: true
        )
        XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 })
        if let directory = ProcessInfo.processInfo.environment["SAVAGE_IT_TEST_OUTPUT_DIR"] {
            try wav.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("CarryNNA.it.wav")
            )
        }
    }

    private typealias Setup = (mod: Mod, pool: ITPlaybackVoicePool, voices: [DSPChannel])

    private func makeSetup(
        newNoteAction: NewNoteAction,
        duplicateCheckType: DuplicateCheckType = .off,
        duplicateCheckAction: DuplicateCheckAction = .cut,
        carryEnvelopes: Bool = false
    ) throws -> Setup {
        let sound = Sample(
            pcm: [0.25, 0.25, 0.25, 0.25], loopStart: 0, loopLength: 4,
            loopType: .forward, volume: 64, finetune: 0,
            itProperties: ITSampleProperties(
                c5Speed: 8_000, globalVolume: 64, defaultPanning: nil
            )
        )
        let secondSound = Sample(
            pcm: [0.125, -0.125, 0.375, -0.375], loopStart: 0, loopLength: 4,
            loopType: .forward, volume: 64, finetune: 0,
            itProperties: ITSampleProperties(
                c5Speed: 8_000, globalVolume: 64, defaultPanning: nil
            )
        )
        let mapping = try NoteSampleMapping(entries: try (0..<120).map { key in
            try NoteSampleMapping.Entry(targetNote: key, sampleID: key == 52 ? 2 : 1)
        })
        func properties() -> ITInstrumentProperties {
            ITInstrumentProperties(
                newNoteAction: newNoteAction,
                duplicateCheckType: duplicateCheckType,
                duplicateCheckAction: duplicateCheckAction,
                globalVolume: 128,
                defaultPanning: nil,
                pitchPanSeparation: 0,
                pitchPanCenter: 60,
                randomVolumeVariation: 0,
                randomPanningVariation: 0,
                initialFilterCutoff: nil,
                initialFilterResonance: nil
            )
        }
        let carryEnvelope = carryEnvelopes ? Envelope(
            points: [EnvelopePoint(frame: 0, value: 32), EnvelopePoint(frame: 20, value: 64)],
            sustainStart: 0,
            sustainEnd: 0,
            loopStart: 0,
            loopEnd: 0,
            sustainEnabled: false,
            loopEnabled: false,
            carryEnabled: true
        ) : nil
        let instrument = Instrument(
            index: 1, name: "Voice pool", samples: [sound, secondSound],
            volumeEnvelope: carryEnvelope,
            panningEnvelope: carryEnvelope,
            fadeout: 512,
            pitchEnvelope: carryEnvelope,
            noteSampleMapping: mapping, itProperties: properties()
        )
        let secondInstrument = Instrument(
            index: 2, name: "Second instrument", samples: [sound, secondSound], fadeout: 512,
            noteSampleMapping: mapping, itProperties: properties()
        )
        let module = Mod(
            name: "Voice pool", length: 1, patternTable: [0],
            instruments: [nil, instrument, secondInstrument],
            samplePool: [nil, sound, secondSound],
            patterns: [], channelCount: 64, format: .it,
            initialSpeed: 6, initialTempo: 125, initialGlobalVolume: 128,
            channelPannings: Array(repeating: 0.5, count: 64),
            linearFrequency: true,
            channelVolumes: Array(repeating: 64, count: 64),
            itProperties: instrumentModeProperties
        )
        let voices = ModPlayerCoordinator.makeRenderChannels(for: module)
        return (module, try XCTUnwrap(voices.first?.itVoicePool), voices)
    }

    private var instrumentModeProperties: ITModuleProperties {
        ITModuleProperties(
            createdWithVersion: 0x0214, compatibleWithVersion: 0x0214,
            usesInstruments: true, stereo: true,
            volumeZeroMixOptimization: false, linearSlides: true,
            patternHighlight: 0, mixVolume: 64, panSeparation: 128,
            pitchWheelDepth: 0, hasSongMessage: false,
            songMessageLength: 0, songMessageOffset: 0,
            usesMIDIPitchController: false,
            hasEmbeddedMIDIConfiguration: false,
            unknownHeaderFlags: 0, unknownSpecialFlags: 0
        )
    }

    private func moduleLike(
        _ source: Mod,
        patterns: [SavageModPlayerCore.Pattern],
        initialSpeed: Int,
        initialTempo: Int,
        channelDisabled: [Bool]? = nil
    ) -> Mod {
        Mod(
            name: source.name,
            length: 1,
            patternTable: [0],
            instruments: source.instruments,
            samplePool: source.samplePool,
            patterns: patterns,
            channelCount: source.channelCount,
            format: .it,
            initialSpeed: initialSpeed,
            initialTempo: initialTempo,
            initialGlobalVolume: source.initialGlobalVolume,
            channelPannings: source.channelPannings,
            linearFrequency: source.linearFrequency,
            channelVolumes: source.channelVolumes,
            channelSurrounds: source.channelSurrounds,
            channelDisabled: channelDisabled ?? source.channelDisabled,
            playbackSemantics: source.playbackSemantics,
            itProperties: source.itProperties
        )
    }

    private func renderOwnerSignals(
        _ module: Mod
    ) throws -> (maxStem: Float, maxStereo: Float, vu: Float, scope: Float, otherStemsAreSilent: Bool) {
        let channels = ModPlayerCoordinator.makeRenderChannels(for: module)
        let state = ModPlayerCoordinator.makeRenderState(for: module, sampleRate: sampleRate)
        let peaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let waves = UnsafeMutablePointer<Float>.allocate(capacity: 64 * 32)
        let master = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer {
            peaks.deallocate()
            waves.deallocate()
            master.deallocate()
        }
        peaks.initialize(repeating: 0, count: 64)
        waves.initialize(repeating: 0, count: 64 * 32)
        master.initialize(repeating: 0, count: 128)
        let vu = RealtimeVUBuffer(pointer: peaks)
        let wave = RealtimeWaveBuffer(channelWaves: waves, masterWaves: master)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw XCTSkip("Audio-Puffer konnte nicht angelegt werden")
        }
        buffer.frameLength = 1024
        let captureStems = UnsafeMutablePointer<Float>.allocate(capacity: 64 * 1024)
        let captureLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        let captureRight = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        defer {
            captureStems.deallocate()
            captureLeft.deallocate()
            captureRight.deallocate()
        }
        captureStems.initialize(repeating: 0, count: 64 * 1024)
        captureLeft.initialize(repeating: 0, count: 1024)
        captureRight.initialize(repeating: 0, count: 1024)
        let capture = RenderCapture(
            stereoLeftPointer: captureLeft,
            stereoRightPointer: captureRight,
            stemsPointer: captureStems,
            frameCapacity: 1024,
            channelCount: 64
        )
        let block = ModPlayerCoordinator.createRenderBlock(
            state: state,
            vuBuffer: vu,
            waveBuffer: wave,
            dspChannels: channels,
            mod: module,
            sampleRate: sampleRate,
            capture: capture
        )
        var silence = ObjCBool(false)
        var timestamp = AudioTimeStamp()
        XCTAssertEqual(block(&silence, &timestamp, 1024, buffer.mutableAudioBufferList), noErr)

        var maxStem: Float = 0
        var maxStereo: Float = 0
        var otherSilent = true
        for frame in 0..<1024 {
            maxStem = max(maxStem, abs(captureStems[frame]))
            maxStereo = max(maxStereo, abs(captureLeft[frame]), abs(captureRight[frame]))
        }
        for channel in 1..<64 {
            for frame in 0..<1024 where captureStems[channel * 1024 + frame] != 0 {
                otherSilent = false
            }
        }
        var maxScope: Float = 0
        for index in 0..<32 { maxScope = max(maxScope, abs(waves[index])) }
        return (maxStem, maxStereo, peaks[0], maxScope, otherSilent)
    }

    private func sequencedDuration(
        _ module: Mod,
        sampleRate: Double,
        limit: Double
    ) -> (duration: Double, maxActiveVoices: Int) {
        let channels = ModPlayerCoordinator.makeRenderChannels(for: module)
        let state = ModPlayerCoordinator.makeRenderState(for: module, sampleRate: sampleRate)
        let frameLimit = Int(sampleRate * limit)
        var frames = 0
        var maxActiveVoices = 0
        while frames < frameLimit {
            SequencerCore.advanceIfNeeded(
                state: state, channels: channels, mod: module, sampleRate: sampleRate
            )
            maxActiveVoices = max(
                maxActiveVoices,
                channels.first?.itVoicePool?.activeVoiceCount ?? 0
            )
            if state.endReached { break }
            state.outputsUntilNextTick -= 1
            state.elapsedFrames += 1
            frames += 1
        }
        return (Double(frames) / sampleRate, maxActiveVoices)
    }

    private func note(key: Int, instrument: Int = 0) -> Note {
        Note(
            instrument: instrument, period: 0, effectId: 0, effectData: 0,
            key: key, effectPresent: false
        )
    }

    private func s7Note(key: Int = -1, instrument: Int = 0, low: Int) -> Note {
        Note(
            instrument: instrument, period: 0,
            effectId: ModuleEffect.impulseTrackerCommand(19),
            effectData: 0x70 | low, key: key, effectPresent: true
        )
    }
}
