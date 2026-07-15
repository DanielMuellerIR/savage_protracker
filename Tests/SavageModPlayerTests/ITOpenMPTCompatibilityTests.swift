import XCTest
@testable import SavageModPlayerCore

final class ITOpenMPTCompatibilityTests: XCTestCase {
    func testCwtvIdentifiesOpenMPTButOnlyCmwtControlsFormatCompatibility() throws {
        let compatible = try ITParser.parse(data: makeIT(
            cwtv: 0x5128,
            cmwt: 0x0215,
            reserved: Array("OMPT".utf8)
        ))
        let identity = try XCTUnwrap(compatible.itProperties?.trackerIdentity)
        XCTAssertEqual(identity.family, .openMPT)
        XCTAssertEqual(identity.displayName, "OpenMPT 1.28")
        XCTAssertFalse(identity.compatibilityExport)
        XCTAssertTrue(compatible.compatibilityWarnings.isEmpty)

        let newerCreator = try ITParser.parse(data: makeIT(
            cwtv: 0x5FFF,
            cmwt: 0x0215,
            reserved: Array("OMPT".utf8)
        ))
        XCTAssertTrue(newerCreator.compatibilityWarnings.isEmpty)

        let newerStructure = try ITParser.parse(data: makeIT(
            cwtv: 0x0214,
            cmwt: 0x0217
        ))
        XCTAssertEqual(newerStructure.compatibilityWarnings.count, 1)
        XCTAssertTrue(newerStructure.compatibilityWarnings[0].contains("IT 2.17"))
    }

    func testStructuredSongExtensionsDecodeReferenceValuesWithoutWarnings() throws {
        let extensions = songExtensions([
            ("...C", le(32, size: 2)),
            ("..MT", le(0, size: 1)),
            (".MMP", le(4, size: 4)),
            (".VWC", le(0x01280400, size: 4)),
            ("VWSL", le(0x01280400, size: 4)),
            (".APS", le(48, size: 4)),
            ("VTSV", le(48, size: 4)),
            (".FSM", [0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x00, 0x00, 0x10]),
            ("AUTH", Array("Tester".utf8)),
            ("CCOL", [1, 2, 3, 0]),
        ])
        let module = try ITParser.parse(data: makeIT(
            cwtv: 0x5128,
            cmwt: 0x0214,
            endExtensions: extensions
        ))
        let properties = try XCTUnwrap(module.itProperties)
        let parsed = try XCTUnwrap(properties.openMPTExtensions)

        XCTAssertEqual(module.channelCount, 32)
        XCTAssertEqual(parsed.tempoMode, .classic)
        XCTAssertEqual(parsed.mixLevel, .compatible)
        XCTAssertEqual(parsed.createdWithVersion?.displayName, "1.28.04.00")
        XCTAssertEqual(parsed.lastSavedWithVersion?.displayName, "1.28.04.00")
        XCTAssertEqual(parsed.samplePreamp, 48)
        XCTAssertEqual(parsed.synthPreamp, 48)
        XCTAssertEqual(parsed.artist, "Tester")
        XCTAssertEqual(parsed.channelColors, [0x030201])
        XCTAssertEqual(parsed.playBehaviours.map(\.bit), [0, 7, 100])
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
        XCTAssertTrue(parsed.chunks.contains { $0.id == ".VWC" && $0.classification == .metadata })
    }

    func testAlternativeAndModernTempoModesDriveOpenMPTTimingFormula() throws {
        let alternative = try ITParser.parse(data: makeIT(endExtensions: songExtensions([
            ("..MT", le(1, size: 1)),
        ])))
        let alternativeState = RenderEngine.makeRenderState(
            for: alternative, sampleRate: 48_000
        )
        XCTAssertEqual(alternativeState.tempoMode, .alternative)
        XCTAssertEqual(alternativeState.outputsPerTick, 384, accuracy: 0.0001)

        let modern = try ITParser.parse(data: makeIT(
            highlight: 0,
            endExtensions: songExtensions([
                ("..MT", le(2, size: 1)),
                (".BPR", le(4, size: 4)),
            ])
        ))
        let modernState = RenderEngine.makeRenderState(for: modern, sampleRate: 48_000)
        XCTAssertEqual(modernState.tempoMode, .modern)
        XCTAssertEqual(modernState.rowsPerBeat, 4)
        XCTAssertEqual(modernState.outputsPerTick, 960, accuracy: 0.0001)
    }

    func testFirstExtendedPatternStartsAtRowZeroExactlyOnce() throws {
        let module = try ITParser.parse(data: makeIT(patternRows: [], patternRowCount: 128))
        XCTAssertEqual(module.patterns[0].rows.count, 128)

        // Bei 2.400 Hz, Tempo 125 und Speed 6 dauert ein Tick genau 48 Frames.
        // Das WAV muss deshalb 128 * 6 * 48 Stereo-Frames enthalten. Der alte
        // 64-Zeilen-Vorstart renderte zusaetzlich die Zeilen 64...127.
        let wav = try ModuleRenderer.renderWavData(
            mod: module,
            sampleRate: 2_400,
            maxDurationSeconds: 20,
            normalize: false
        )
        XCTAssertEqual((wav.count - 44) / 4, 128 * 6 * 48)
    }

    func testInstrumentExtensionsOverrideFadeoutAndPanning() throws {
        let extensionData = instrumentExtensions([
            ("..OF", 2, [1_234]),
            ("...P", 2, [192]),
        ])
        let module = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            patternRows: [[0x81, 0x03, 60, 1]],
            endExtensions: extensionData
        ))
        let parsed = try XCTUnwrap(module.instruments[1])
        XCTAssertEqual(parsed.fadeout, 1_234)
        XCTAssertEqual(parsed.itProperties?.defaultPanning, 48)
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
    }

    func testUnsupportedInstrumentPropertyWarnsOnlyWhenInstrumentIsReached() throws {
        let extensionData = instrumentExtensions([
            ("...R", 1, [0]), // explizites Nearest-Neighbor-Resampling
        ])
        let unused = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            endExtensions: extensionData
        ))
        XCTAssertTrue(unused.compatibilityWarnings.isEmpty)

        let used = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            patternRows: [[0x81, 0x03, 60, 1]],
            endExtensions: extensionData
        ))
        XCTAssertEqual(used.compatibilityWarnings.count, 1)
        XCTAssertTrue(used.compatibilityWarnings[0].contains("Instrument 1"))
        XCTAssertTrue(used.compatibilityWarnings[0].contains("Resampling"))
    }

    func testMIDIRoutingAndPluginWarningsRequireActualPatternUse() throws {
        var midiInstrument = instrument()
        midiInstrument[0x3C] = 7

        let unused = try ITParser.parse(data: makeIT(
            flags: 0x0045,
            instruments: [midiInstrument]
        ))
        XCTAssertTrue(unused.compatibilityWarnings.isEmpty)

        let used = try ITParser.parse(data: makeIT(
            flags: 0x0045,
            instruments: [midiInstrument],
            patternRows: [[0x81, 0x03, 60, 1]]
        ))
        XCTAssertEqual(used.compatibilityWarnings.filter { $0.contains("MIDI-Kanal 7") }.count, 1)
        XCTAssertEqual(used.compatibilityWarnings.filter { $0.contains("Pitchsteuerung") }.count, 1)

        let plugin = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            patternRows: [[0x81, 0x03, 60, 1]],
            endExtensions: instrumentExtensions([(".PiM", 1, [3])])
        ))
        XCTAssertEqual(plugin.compatibilityWarnings.count, 1)
        XCTAssertTrue(plugin.compatibilityWarnings[0].contains("Plugin-Slot 3"))
    }

    func testLegacyEmbeddedXTPMAndMSNIAreBoundToInstrumentOffset() throws {
        var extended = instrument()
        extended.replaceSubrange(550..<554, with: Array("XTPM".utf8))
        extended += [UInt8](repeating: 0, count: 120)
        extended += Array("MSNI".utf8)
        extended += le(5, size: 4)
        extended += Array("GULP".utf8) + [4]

        let module = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [extended],
            patternRows: [[0x81, 0x03, 60, 1]]
        ))
        XCTAssertEqual(module.instruments[1]?.itProperties?.pluginSlot, 4)
        XCTAssertEqual(module.compatibilityWarnings.count, 1)
        XCTAssertTrue(module.compatibilityWarnings[0].contains("Plugin-Slot 4"))
        XCTAssertTrue(module.itProperties?.openMPTExtensions?.chunks.contains {
            $0.id == "MSNI" && $0.context == .instrument
        } == true)
    }

    func testUnknownSongChunkNamesExactCapability() throws {
        let module = try ITParser.parse(data: makeIT(
            endExtensions: songExtensions([("ABCD", [1, 2, 3])])
        ))
        XCTAssertEqual(module.compatibilityWarnings.count, 1)
        XCTAssertTrue(module.compatibilityWarnings[0].contains("song-Chunk ABCD"))
    }

    func testKnownLegacyModPlugMetadataAndEmptyRoutingStayQuiet() throws {
        let headerTail = legacyChunk("PNAM", Array("Pattern 0".utf8))
            + legacyChunk("CNAM", Array("Kanal 1".utf8))
            + legacyChunk("CHFX", le(0, size: 4))
            + legacyChunk("MODU", [])
        let module = try ITParser.parse(data: makeIT(
            patternRows: [[0x81, 0x01, 60]],
            headerTail: headerTail
        ))
        let chunks = try XCTUnwrap(module.itProperties?.openMPTExtensions?.chunks)
        XCTAssertEqual(chunks.map(\.id), ["PNAM", "CNAM", "CHFX", "MODU"])
        XCTAssertEqual(chunks.map(\.classification), [.metadata, .metadata, .routing, .metadata])
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
    }

    func testUnsupportedLegacyMSFBehaviourWarnsOnlyWhenTriggerExists() throws {
        var bits = [UInt8](repeating: 0, count: 7)
        bits[49 / 8] = 1 << UInt8(49 % 8)
        let extensions = songExtensions([(".FSM", bits)])

        let unused = try ITParser.parse(data: makeIT(endExtensions: extensions))
        XCTAssertTrue(unused.compatibilityWarnings.isEmpty)

        let used = try ITParser.parse(data: makeIT(
            patternRows: [[0x81, 0x08, 19, 0xB1]],
            endExtensions: extensions
        ))
        XCTAssertEqual(used.compatibilityWarnings.count, 1)
        XCTAssertTrue(used.compatibilityWarnings[0].contains("Bit 49"))
        XCTAssertTrue(used.compatibilityWarnings[0].contains("itPatternLoopWithJumpsOld"))
    }

    func testSpeedOneSlideBehaviourIsUsedOnlyWithA01AndPortamento() throws {
        let extensions = songExtensions([(".FSM", [1 << 6])])
        let module = try ITParser.parse(data: makeIT(
            patternRows: [
                [0x81, 0x08, 1, 1], // A01: Speed 1
                [0x81, 0x08, 5, 2], // E02: normales Portamento down
            ],
            endExtensions: extensions
        ))
        let finding = try XCTUnwrap(module.itProperties?.capabilityReport?.findings.first {
            $0.identifier == "MSF.6"
        })
        XCTAssertEqual(finding.support, .supported)
        XCTAssertTrue(finding.used)
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
    }

    func testLegacyReleaseNodeBehaviourUsesPreciseInstrumentWarning() throws {
        var bits = [UInt8](repeating: 0, count: 12)
        bits[94 / 8] = 1 << UInt8(94 % 8)
        let extensionData = instrumentExtensions([("NREV", 1, [2])])
            + songExtensions([(".FSM", bits)])
        let module = try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            patternRows: [[0x81, 0x03, 60, 1]],
            endExtensions: extensionData
        ))

        let finding = try XCTUnwrap(module.itProperties?.capabilityReport?.findings.first {
            $0.identifier == "MSF.94"
        })
        XCTAssertEqual(finding.support, .unsupported)
        XCTAssertTrue(finding.used)
        XCTAssertEqual(module.compatibilityWarnings.count, 1)
        XCTAssertTrue(module.compatibilityWarnings[0].contains("Instrument 1"))
        XCTAssertTrue(module.compatibilityWarnings[0].contains("Release-Knoten"))
    }

    func testTruncatedStructuredExtensionChunksFailDeterministically() {
        var truncatedSong = Array("STPM".utf8)
        truncatedSong += Array(".APS".utf8)
        truncatedSong += le(4, size: 2)
        truncatedSong += [48]
        XCTAssertThrowsError(try ITParser.parse(data: makeIT(endExtensions: truncatedSong))) {
            guard case .invalidExtension(let detail)? = $0 as? ITParser.ParserError else {
                return XCTFail("Falscher Fehler: \($0)")
            }
            XCTAssertTrue(detail.contains(".APS"))
        }

        var truncatedInstrument = Array("XTPM".utf8)
        truncatedInstrument += Array("..OF".utf8)
        truncatedInstrument += le(2, size: 2)
        truncatedInstrument += [1]
        XCTAssertThrowsError(try ITParser.parse(data: makeIT(
            flags: 0x0005,
            instruments: [instrument()],
            endExtensions: truncatedInstrument
        )))
    }

    func testReferenceFileHasExpectedOpenMPTCapabilitiesWhenAvailable() throws {
        let url = projectRoot()
            .appendingPathComponent("audio/botb-it-top-10-2026-07-11")
            .appendingPathComponent("BotB 32429 kleeder - not so empty entry (hopefully).it")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Lokale, gitignorierte Referenzdatei fehlt.")
        }
        let module = try ITParser.parse(data: Data(contentsOf: url))
        let properties = try XCTUnwrap(module.itProperties)
        let extensions = try XCTUnwrap(properties.openMPTExtensions)

        XCTAssertEqual(properties.createdWithVersion, 0x5128)
        XCTAssertEqual(properties.compatibleWithVersion, 0x0214)
        XCTAssertEqual(properties.trackerIdentity?.family, .openMPT)
        XCTAssertEqual(extensions.channelCount, 32)
        XCTAssertEqual(extensions.tempoMode, .classic)
        XCTAssertEqual(extensions.mixLevel, .compatible)
        XCTAssertEqual(extensions.createdWithVersion?.displayName, "1.28.04.00")
        XCTAssertEqual(extensions.lastSavedWithVersion?.displayName, "1.28.04.00")
        XCTAssertEqual(extensions.samplePreamp, 48)
        XCTAssertEqual(extensions.synthPreamp, 48)
        XCTAssertEqual(extensions.playBehaviours.map(\.bit), [0] + Array(7...50) + [87, 88, 100])
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
        XCTAssertEqual(
            RenderEngine.sequencedDuration(of: module),
            46.080,
            accuracy: 1.0 / 44_100.0
        )
    }

    // MARK: - Selbst erzeugte, freie IT-Struktur-Fixtures

    private func makeIT(
        cwtv: Int = 0x0214,
        cmwt: Int = 0x0214,
        flags: Int = 0x0001,
        special: Int = 0,
        highlight: Int = 0x1004,
        reserved: [UInt8] = [0, 0, 0, 0],
        instruments: [[UInt8]] = [],
        patternRows: [[UInt8]]? = nil,
        patternRowCount: Int = 32,
        headerTail: [UInt8] = [],
        endExtensions: [UInt8] = []
    ) -> Data {
        precondition(reserved.count == 4)
        var bytes = [UInt8](repeating: 0, count: 0xC0)
        bytes.replaceSubrange(0..<4, with: Array("IMPM".utf8))
        write("OpenMPT Fixture", at: 4, in: &bytes)
        putWord(2, at: 0x20, in: &bytes)
        putWord(instruments.count, at: 0x22, in: &bytes)
        putWord(0, at: 0x24, in: &bytes)
        putWord(1, at: 0x26, in: &bytes)
        putWord(cwtv, at: 0x28, in: &bytes)
        putWord(cmwt, at: 0x2A, in: &bytes)
        putWord(flags, at: 0x2C, in: &bytes)
        putWord(special, at: 0x2E, in: &bytes)
        putWord(highlight, at: 0x1E, in: &bytes)
        bytes[0x30] = 128
        bytes[0x31] = 128
        bytes[0x32] = 6
        bytes[0x33] = 125
        bytes[0x34] = 128
        bytes.replaceSubrange(0x3C..<0x40, with: reserved)
        for channel in 0..<64 {
            bytes[0x40 + channel] = 32
            bytes[0x80 + channel] = 64
        }
        bytes += [0, 255]

        let instrumentTable = bytes.count
        bytes += [UInt8](repeating: 0, count: instruments.count * 4)
        let patternTable = bytes.count
        bytes += [0, 0, 0, 0]
        bytes += headerTail

        for (index, value) in instruments.enumerated() {
            putDword(bytes.count, at: instrumentTable + index * 4, in: &bytes)
            bytes += value
        }
        if let patternRows {
            putDword(bytes.count, at: patternTable, in: &bytes)
            let packed = packedPattern(patternRows, rowCount: patternRowCount)
            appendWord(packed.count, to: &bytes)
            appendWord(patternRowCount, to: &bytes)
            bytes += [0, 0, 0, 0]
            bytes += packed
        }
        bytes += endExtensions
        return Data(bytes)
    }

    private func instrument() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 554)
        bytes.replaceSubrange(0..<4, with: Array("IMPI".utf8))
        write("Instrument", at: 0x20, in: &bytes)
        bytes[0x17] = 60
        bytes[0x18] = 128
        bytes[0x19] = 32
        for note in 0..<120 { bytes[0x40 + note * 2] = UInt8(note) }
        return bytes
    }

    private func packedPattern(_ populatedRows: [[UInt8]], rowCount: Int) -> [UInt8] {
        var result = [UInt8]()
        for row in 0..<rowCount {
            if populatedRows.indices.contains(row) { result += populatedRows[row] }
            result.append(0)
        }
        return result
    }

    private func songExtensions(_ chunks: [(String, [UInt8])]) -> [UInt8] {
        var bytes = Array("STPM".utf8)
        for (id, payload) in chunks {
            precondition(id.utf8.count == 4 && payload.count <= 65_535)
            bytes += Array(id.utf8)
            bytes += le(payload.count, size: 2)
            bytes += payload
        }
        return bytes
    }

    private func instrumentExtensions(
        _ fields: [(String, Int, [Int])]
    ) -> [UInt8] {
        var bytes = Array("XTPM".utf8)
        for (id, entrySize, values) in fields {
            precondition(id.utf8.count == 4 && entrySize > 0)
            bytes += Array(id.utf8)
            bytes += le(entrySize, size: 2)
            for value in values { bytes += le(value, size: entrySize) }
        }
        return bytes
    }

    private func legacyChunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le(payload.count, size: 4) + payload
    }

    private func le(_ value: Int, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func write(_ value: String, at offset: Int, in bytes: inout [UInt8]) {
        let encoded = Array(value.utf8)
        bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
    }

    private func putWord(_ value: Int, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func putDword(_ value: Int, at offset: Int, in bytes: inout [UInt8]) {
        for byte in 0..<4 {
            bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
        }
    }

    private func appendWord(_ value: Int, to bytes: inout [UInt8]) {
        bytes += le(value, size: 2)
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
