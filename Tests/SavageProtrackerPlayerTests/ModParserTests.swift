import XCTest
@testable import SavageProtrackerPlayerCore

final class ModParserTests: XCTestCase {
    
    func testMockModParsing() throws {
        // Create 2108 bytes for a mock MOD file (1084 header + 1024 pattern 0)
        var data = Data(repeating: 0, count: 2108)
        
        // 1. Song Title (Offset 0..20) -> "Test Mod Title"
        let title = "Test Mod Title"
        let titleData = title.data(using: .utf8)!
        data.replaceSubrange(0..<titleData.count, with: titleData)
        
        // 2. Instrument 1 (Offset 20..50)
        // Name: "Inst 1"
        let instName = "Inst 1"
        let instNameData = instName.data(using: .utf8)!
        data.replaceSubrange(20..<(20 + instNameData.count), with: instNameData)
        
        // Length: 2 * 16-bit word = let's set to 2 bytes (word value 1)
        data[42] = 0x00
        data[43] = 0x01
        
        // Finetune: 0
        data[44] = 0x00
        
        // Volume: 64
        data[45] = 64
        
        // Repeat Offset: 0
        data[46] = 0x00
        data[47] = 0x00
        
        // Repeat Length: word value 2 (4 bytes)
        data[48] = 0x00
        data[49] = 0x02
        
        // 3. Song Length (Offset 950) -> 1
        data[950] = 1
        
        // 4. Pattern Table (Offset 952..1080) -> Index 0
        data[952] = 0
        
        // 5. Signature (Offset 1080..1084) -> "M.K."
        let sig = "M.K.".data(using: .utf8)!
        data.replaceSubrange(1080..<1084, with: sig)
        
        // 6. Pattern 0, Row 0, Channel 0 (Offset 1084..1088)
        data[1084] = 0x01
        data[1085] = 0xAC
        data[1086] = 0x1C
        data[1087] = 0x20
        
        // Run parser
        let mod = try ModParser.parse(data: data)
        
        // Assertions
        XCTAssertEqual(mod.name, "Test Mod Title")
        XCTAssertEqual(mod.length, 1)
        XCTAssertEqual(mod.patternTable[0], 0)
        
        // Instrument assertions
        XCTAssertEqual(mod.instruments.count, 32)
        guard let inst = mod.instruments[1] else {
            XCTFail("Instrument 1 should not be nil")
            return
        }
        XCTAssertEqual(inst.name, "Inst 1")
        XCTAssertEqual(inst.length, 2)
        XCTAssertEqual(inst.volume, 64)
        XCTAssertEqual(inst.isLooped, true)
        
        // Note assertions
        XCTAssertEqual(mod.patterns.count, 1)
        let note = mod.patterns[0].rows[0].notes[0]
        XCTAssertEqual(note.instrument, 1)
        XCTAssertEqual(note.period, 428)
        XCTAssertEqual(note.effectId, 0x0C)
        XCTAssertEqual(note.effectData, 0x20)
        XCTAssertEqual(note.hasEffect, true)
    }
    
    func testRealModFilesParsing() throws {
        let audioDirPath = "audio"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: audioDirPath) else {
            print("Audio directory not found, skipping real MOD test.")
            return
        }
        
        let contents = try fileManager.contentsOfDirectory(atPath: audioDirPath)
        let modFiles = contents.filter { $0.lowercased().hasSuffix(".mod") }
        
        XCTAssertFalse(modFiles.isEmpty, "No MOD files found in audio directory!")
        
        print("Starting parsing tests for \(modFiles.count) actual Amiga MOD files...")
        
        for fileName in modFiles {
            let filePath = (audioDirPath as NSString).appendingPathComponent(fileName)
            let fileURL = URL(fileURLWithPath: filePath)
            
            let data = try Data(contentsOf: fileURL)
            let mod = try ModParser.parse(data: data)
            
            if mod.name.isEmpty {
                print("Parsed real MOD with empty title field: \(fileName)")
            }
            XCTAssertTrue(mod.length > 0, "Song length is zero for \(fileName)")
            XCTAssertTrue(mod.patterns.count > 0, "No patterns parsed for \(fileName)")
            XCTAssertEqual(mod.instruments.count, 32, "Instruments count should be exactly 32 for \(fileName)")
            
            print("✓ Successfully parsed real MOD: \(fileName) (\"\(mod.name)\"), Patterns: \(mod.patterns.count), Length: \(mod.length)")
        }
    }
    
    func testDSPChannelSafety() {
        let channel = DSPChannel(index: 1)
        let bytes: [Int8] = [0, 10, 20, 30, 40, 50]
        
        // 1. Valid index interpolation
        let val1 = channel.getInterpolatedSample(from: bytes, index: 1.5)
        XCTAssertEqual(val1, 15.0 / 256.0, accuracy: 0.0001)
        
        // 2. Out-of-bounds index interpolation checks (underflow & overflow)
        XCTAssertEqual(channel.getInterpolatedSample(from: bytes, index: -1.0), 0.0)
        XCTAssertEqual(channel.getInterpolatedSample(from: bytes, index: 10.0), 0.0)
        XCTAssertEqual(channel.getInterpolatedSample(from: bytes, index: Double.nan), 0.0)
        XCTAssertEqual(channel.getInterpolatedSample(from: bytes, index: Double.infinity), 0.0)
        XCTAssertEqual(channel.getInterpolatedSample(from: bytes, index: -Double.infinity), 0.0)
        
        // 3. Looped interpolation out-of-bounds checks
        XCTAssertEqual(channel.getInterpolatedSampleLooped(from: bytes, index: -2.0, repeatOffset: 1, repeatLength: 3), 0.0)
        XCTAssertEqual(channel.getInterpolatedSampleLooped(from: bytes, index: 20.0, repeatOffset: 1, repeatLength: 3), 0.0)
        XCTAssertEqual(channel.getInterpolatedSampleLooped(from: bytes, index: Double.nan, repeatOffset: 1, repeatLength: 3), 0.0)
        
        // 4. Perform tick safety check (prevent NaN or division by zero)
        channel.period = 0 // Zero period (should fallback/cap correctly to 113 and NOT crash)
        channel.performTick(tick: 0, sampleRate: 44100.0, clockRate: 3546894.6)
        XCTAssertTrue(channel.sampleSpeed > 0.0) // Caps at 113, so speed is non-zero
        
        channel.period = 428
        channel.performTick(tick: 0, sampleRate: 0.0, clockRate: 3546894.6) // Zero sampleRate check
        XCTAssertEqual(channel.sampleSpeed, 0.0)
        
        // Negative tick or weird values check
        channel.performTick(tick: -5, sampleRate: 44100.0, clockRate: 3546894.6)
        XCTAssertTrue(channel.sampleSpeed >= 0.0)
    }

    func testLongOneShotSampleKeepsAdvancing() {
        let bytes = [Int8](repeating: 64, count: 12_000)
        let instrument = Instrument(
            index: 1,
            name: "Long One Shot",
            length: bytes.count,
            finetune: 0,
            volume: 64,
            repeatOffset: 0,
            repeatLength: 0,
            bytes: bytes,
            isLooped: false
        )
        let channel = DSPChannel(index: 1)
        let note = Note(instrument: 1, period: 428, effectId: 0, effectData: 0)

        channel.playNote(note, instruments: [nil, instrument])
        channel.performTick(tick: 0, sampleRate: 44100.0, clockRate: 3546894.6)

        for _ in 0..<4_000 {
            channel.sampleIndex += channel.sampleSpeed
        }

        XCTAssertGreaterThan(channel.sampleIndex, 0)
        XCTAssertLessThan(Int(channel.sampleIndex), instrument.length)
    }

    @MainActor
    func testRTypeFourthChannelSampleSurvivesPastRow16() throws {
        let fileURL = URL(fileURLWithPath: "audio/Rtype.mod")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("RType test file not found, skipping.")
            return
        }

        let data = try Data(contentsOf: fileURL)
        let mod = try ModParser.parse(data: data)
        let coordinator = ModPlayerCoordinator()
        let samples = coordinator.renderProbe(mod: mod, durationSeconds: 4.0)

        // RType Pattern 0, Row 16, Kanal 4 startet Instrument 2. Danach
        // kommen lange keine neuen Kanal-4-Noten; der Loop muss weiterlaufen.
        let tailSamples = samples.filter { sample in
            sample.position == 0 && sample.row >= 24 && sample.row <= 36
        }
        let fourthChannelPeaks = tailSamples.map { abs($0.channelOutputs[3]) }
        let maxFourthChannelPeak = fourthChannelPeaks.max() ?? 0
        let audibleProbeCount = fourthChannelPeaks.filter { $0 > 0.001 }.count

        XCTAssertGreaterThan(maxFourthChannelPeak, 0.001)
        XCTAssertGreaterThan(audibleProbeCount, 8)
    }
    
    func testParserErrorResilience() {
        // Test parsing too small data
        let emptyData = Data()
        XCTAssertThrowsError(try ModParser.parse(data: emptyData)) { error in
            guard let parserError = error as? ModParser.ParserError else {
                XCTFail("Unexpected error type")
                return
            }
            switch parserError {
            case .fileTooSmall:
                break // Expected
            default:
                XCTFail("Expected .fileTooSmall, got \(parserError)")
            }
        }
        
        // Test parsing invalid signature
        var invalidData = Data(repeating: 0, count: 1200)
        let badSig = "BAD!".data(using: .utf8)!
        invalidData.replaceSubrange(1080..<1084, with: badSig)
        
        XCTAssertThrowsError(try ModParser.parse(data: invalidData)) { error in
            guard let parserError = error as? ModParser.ParserError else {
                XCTFail("Unexpected error type")
                return
            }
            switch parserError {
            case .invalidSignature(let sig):
                XCTAssertEqual(sig, "BAD!")
            default:
                XCTFail("Expected .invalidSignature, got \(parserError)")
            }
        }

        // Gueltige Signatur, aber Songlaenge 0 -> nicht abspielbar, muss als
        // .emptySong abgelehnt werden (sonst patternTable[-1]-Crash in der UI).
        var emptySong = Data(repeating: 0, count: 1200)
        emptySong.replaceSubrange(1080..<1084, with: Data("M.K.".utf8))
        emptySong[950] = 0
        XCTAssertThrowsError(try ModParser.parse(data: emptySong)) { error in
            guard case ModParser.ParserError.emptySong? = error as? ModParser.ParserError else {
                XCTFail("Expected .emptySong")
                return
            }
        }

        // Mehrkanal-Signaturen (6CHN/8CHN/FLT8) muessen abgelehnt werden, weil
        // der Parser strikt 4-kanalig ist und sie sonst als Garbage einliest.
        for unsupported in ["8CHN", "6CHN", "FLT8"] {
            var multiData = Data(repeating: 0, count: 1200)
            multiData.replaceSubrange(1080..<1084, with: unsupported.data(using: .utf8)!)
            XCTAssertThrowsError(try ModParser.parse(data: multiData), "\(unsupported) sollte abgelehnt werden") { error in
                guard case ModParser.ParserError.invalidSignature(let sig)? = error as? ModParser.ParserError else {
                    XCTFail("Expected .invalidSignature for \(unsupported)")
                    return
                }
                XCTAssertEqual(sig, unsupported)
            }
        }
    }
    
    @MainActor
    func testRealtimePlaybackSurvivesFiveSeconds() async throws {
        let audioDirPath = "audio"
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioDirPath) else {
            return
        }
        let contents = try fileManager.contentsOfDirectory(atPath: audioDirPath)
        let modFiles = contents
            .filter { $0.lowercased().hasSuffix(".mod") }
            .sorted()
        guard let randomModName = modFiles.randomElement() else {
            return
        }
        let filePath = (audioDirPath as NSString).appendingPathComponent(randomModName)
        let fileURL = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: fileURL)
        let mod = try ModParser.parse(data: data)
        
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(mod)
        
        coordinator.play()
        XCTAssertTrue(coordinator.isPlaying)

        // Regressionstest für Startcrashes: echte Wiedergabe muss länger
        // laufen als der frühere Absturz nach ungefähr einer Sekunde.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        XCTAssertTrue(coordinator.isPlaying, "Playback stopped early for \(randomModName)")
        coordinator.stop()
        XCTAssertFalse(coordinator.isPlaying)
    }
    
    func testPrintPatternNotes() throws {
        let audioDirPath = "audio"
        let filePath = (audioDirPath as NSString).appendingPathComponent("Simon_the_Sorcerer-Village.mod")
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("Simon test file not found, skipping.")
            return
        }
        let data = try Data(contentsOf: fileURL)
        let mod = try ModParser.parse(data: data)
        
        print("--- SWIFT PARSER OUTPUT ---")
        for r in 0..<16 {
            let row = mod.patterns[0].rows[r]
            var rowStr = "Row \(String(format: "%02d", r)):"
            for c in 0..<4 {
                let note = row.notes[c]
                rowStr += " [Ch\(c): Inst=\(note.instrument), Per=\(note.period), Eff=\(note.effectId), Dat=\(note.effectData)]"
            }
            print(rowStr)
        }
        print("---------------------------")
    }
    
    func testSwiftFinetuneMatchesHtmlWorkletApproximation() {
        let instrument = Instrument(
            index: 1,
            name: "Fine",
            length: 8,
            finetune: 7,
            volume: 64,
            repeatOffset: 0,
            repeatLength: 0,
            bytes: [1, 2, 3, 4, 5, 6, 7, 8],
            isLooped: false
        )
        let channel = DSPChannel(index: 1)
        let note = Note(instrument: 1, period: 856, effectId: 0, effectData: 0)

        channel.playNote(note, instruments: [nil, instrument])

        XCTAssertEqual(channel.period, 849.0)
        XCTAssertEqual(channel.currentPeriod, 849.0)
    }
    
    func testOneShotSentinelNotLooped() throws {
        var data = Data(repeating: 0, count: 2108)
        data.replaceSubrange(1080..<1084, with: Data("M.K.".utf8))
        data[950] = 1
        data[952] = 0
        // Instrument 1: Laenge 10 Words, repeatOffset 3 Words (>0), repeatLength 1
        // Word (= 2 Bytes Sentinel). Darf NICHT als Loop gelten.
        data[42] = 0x00; data[43] = 0x0A
        data[45] = 64
        data[46] = 0x00; data[47] = 0x03
        data[48] = 0x00; data[49] = 0x01
        let mod = try ModParser.parse(data: data)
        XCTAssertEqual(mod.instruments[1]?.isLooped, false,
                       "repeatLength 1 Word (Sentinel) darf trotz repeatOffset>0 nicht loopen")
    }

    func testDemoModGeneration() {
        let mod = ModParser.generateDemoMod()
        XCTAssertEqual(mod.name, "Cyber Synth Demo")
        XCTAssertEqual(mod.length, 1)
        XCTAssertEqual(mod.patterns.count, 1)
        XCTAssertEqual(mod.instruments.count, 32)
    }
}
