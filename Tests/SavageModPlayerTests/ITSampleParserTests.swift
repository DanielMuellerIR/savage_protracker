import XCTest
@testable import SavageModPlayerCore

final class ITSampleParserTests: XCTestCase {
    private struct SampleSpec {
        var name: String
        var frameCount: Int
        var data: [UInt8]
        var is16Bit = false
        var isSigned = true
        var isBigEndian = false
        var isDelta = false
        var isStereo = false
        var compressed = false
        var dataPresent = true
        var loopStart = 0
        var loopEnd = 0
        var loopEnabled = false
        var pingPongLoop = false
        var sustainStart = 0
        var sustainEnd = 0
        var sustainEnabled = false
        var pingPongSustain = false
        var globalVolume = 64
        var volume = 64
        var c5Speed = 8_363
        var defaultPanning: Int? = nil
        var vibratoSpeed = 0
        var vibratoDepth = 0
        var vibratoRate = 0
        var vibratoType = 0
    }

    func testEightBitSignedUnsignedAndDeltaGoldenVectors() throws {
        let specs = [
            SampleSpec(name: "signed8", frameCount: 3, data: [0x80, 0x00, 0x7F]),
            SampleSpec(name: "unsigned8", frameCount: 3, data: [0x00, 0x80, 0xFF], isSigned: false),
            SampleSpec(name: "delta8", frameCount: 3, data: [0x01, 0x01, 0xFE], isDelta: true),
            SampleSpec(name: "unsignedDelta8", frameCount: 3, data: [0x80, 0x01, 0xFF], isSigned: false, isDelta: true),
        ]
        let module = try ITParser.parse(data: makeSampleIT(specs))

        assertPCM(module.samplePool[1]!, [-0.5, 0, Float(127) / 256])
        assertPCM(module.samplePool[2]!, [-0.5, 0, Float(127) / 256])
        assertPCM(module.samplePool[3]!, [Float(1) / 256, Float(2) / 256, 0])
        assertPCM(module.samplePool[4]!, [0, Float(1) / 256, 0])
    }

    func testSixteenBitSignedUnsignedEndianAndDeltaGoldenVectors() throws {
        let specs = [
            SampleSpec(
                name: "signed16le", frameCount: 3,
                data: [0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F], is16Bit: true
            ),
            SampleSpec(
                name: "unsigned16le", frameCount: 3,
                data: [0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF],
                is16Bit: true, isSigned: false
            ),
            SampleSpec(
                name: "signed16be", frameCount: 3,
                data: [0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF],
                is16Bit: true, isBigEndian: true
            ),
            SampleSpec(
                name: "delta16le", frameCount: 3,
                data: [0x01, 0x00, 0x01, 0x00, 0xFE, 0xFF],
                is16Bit: true, isDelta: true
            ),
            SampleSpec(
                name: "delta16be", frameCount: 3,
                data: [0x00, 0x01, 0x00, 0x01, 0xFF, 0xFE],
                is16Bit: true, isBigEndian: true, isDelta: true
            ),
        ]
        let module = try ITParser.parse(data: makeSampleIT(specs))

        let extremes: [Float] = [-0.5, 0, 32_767.0 / 65_536.0]
        assertPCM(module.samplePool[1]!, extremes)
        assertPCM(module.samplePool[2]!, extremes)
        assertPCM(module.samplePool[3]!, extremes)
        let delta: [Float] = [1.0 / 65_536.0, 2.0 / 65_536.0, 0]
        assertPCM(module.samplePool[4]!, delta)
        assertPCM(module.samplePool[5]!, delta)
    }

    func testStereoIsPlanarAndPreservedLosslessly() throws {
        let spec = SampleSpec(
            name: "stereo", frameCount: 3,
            data: [0x80, 0x00, 0x7F, 0x7F, 0x00, 0x80],
            isStereo: true
        )
        let sample = try XCTUnwrap(ITParser.parse(data: makeSampleIT([spec])).samplePool[1])

        XCTAssertEqual(sample.pcm, [-0.5, 0, Float(127) / 256])
        XCTAssertEqual(sample.rightPCM, [Float(127) / 256, 0, -0.5])
    }

    func testEveryUncompressedFlagCombinationGoldenMatrix() throws {
        var specs = [SampleSpec]()
        var expected = [([Float], [Float]?)]()

        for bits in [8, 16] {
            for signed in [false, true] {
                for bigEndian in (bits == 16 ? [false, true] : [false]) {
                    for delta in [false, true] {
                        for stereo in [false, true] {
                            let left = [-2, 0, 2]
                            let right = [2, 0, -2]
                            var data = encodeChannel(
                                left, bits: bits, signed: signed,
                                bigEndian: bigEndian, delta: delta
                            )
                            if stereo {
                                data += encodeChannel(
                                    right, bits: bits, signed: signed,
                                    bigEndian: bigEndian, delta: delta
                                )
                            }
                            specs.append(SampleSpec(
                                name: "matrix\(specs.count)",
                                frameCount: left.count,
                                data: data,
                                is16Bit: bits == 16,
                                isSigned: signed,
                                isBigEndian: bigEndian,
                                isDelta: delta,
                                isStereo: stereo
                            ))
                            let divisor: Float = bits == 16 ? 65_536 : 256
                            expected.append((
                                left.map { Float($0) / divisor },
                                stereo ? right.map { Float($0) / divisor } : nil
                            ))
                        }
                    }
                }
            }
        }

        let module = try ITParser.parse(data: makeSampleIT(specs))
        XCTAssertEqual(specs.count, 24)
        for index in specs.indices {
            let sample = try XCTUnwrap(module.samplePool[index + 1])
            XCTAssertEqual(sample.pcm, expected[index].0, "Matrixfall \(index), links")
            XCTAssertEqual(sample.rightPCM, expected[index].1, "Matrixfall \(index), rechts")
        }
    }

    func testLoopsMetadataVibratoAndSampleModeInstrumentSlots() throws {
        var spec = SampleSpec(
            name: "metadata", frameCount: 5,
            data: [0x80, 0xC0, 0x00, 0x40, 0x7F]
        )
        spec.loopStart = 1
        spec.loopEnd = 5
        spec.loopEnabled = true
        spec.pingPongLoop = true
        spec.sustainStart = 0
        spec.sustainEnd = 3
        spec.sustainEnabled = true
        spec.globalVolume = 48
        spec.volume = 32
        spec.c5Speed = 9_999_999
        spec.defaultPanning = 64
        spec.vibratoSpeed = 4
        spec.vibratoDepth = 5
        spec.vibratoRate = 6
        spec.vibratoType = 3

        let module = try ITParser.parse(data: makeSampleIT([spec]))
        let sample = try XCTUnwrap(module.samplePool[1])
        XCTAssertEqual(sample.name, "metadata")
        XCTAssertEqual(sample.loopStart, 1)
        XCTAssertEqual(sample.loopLength, 4)
        XCTAssertEqual(sample.loopType, .pingpong)
        XCTAssertEqual(sample.sustainLoop, SampleLoop(start: 0, length: 3, type: .forward))
        XCTAssertEqual(sample.volume, 32)
        XCTAssertEqual(sample.panning, 1)
        XCTAssertEqual(sample.itProperties?.c5Speed, 9_999_999)
        XCTAssertEqual(sample.itProperties?.globalVolume, 48)
        XCTAssertEqual(sample.itProperties?.defaultPanning, 64)
        XCTAssertEqual(sample.itProperties?.vibrato, ITSampleVibrato(
            speed: 4, depth: 5, rate: 6, waveform: .random
        ))

        XCTAssertEqual(module.instruments.count, 2)
        XCTAssertEqual(module.instruments[1]?.name, "metadata")
        XCTAssertEqual(module.instruments[1]?.samples.first?.pcm, sample.pcm)
    }

    func testCompressedIT214AndIT215IntegrateIntoSamplePool() throws {
        let it214 = SampleSpec(
            name: "it214", frameCount: 3,
            data: compressedBlock([(1, 9), (1, 9), (254, 9)]),
            compressed: true
        )
        let it215 = SampleSpec(
            name: "it215", frameCount: 3,
            data: compressedBlock([(1, 9), (1, 9), (1, 9)]),
            isDelta: true,
            compressed: true
        )

        let module = try ITParser.parse(data: makeSampleIT([it214, it215]))
        XCTAssertEqual(module.samplePool[1]?.pcm, [Float(1) / 256, Float(2) / 256, 0])
        XCTAssertEqual(module.samplePool[2]?.pcm, [Float(1) / 256, Float(3) / 256, Float(6) / 256])
    }

    func testLongCompressedWaveformMatchesReferencePCM() throws {
        let waveform = (0..<256).map { frame -> Int in
            let phase = frame % 64
            return phase < 32 ? -96 + phase * 6 : 96 - (phase - 32) * 6
        }
        var previous = 0
        let deltas = waveform.map { value -> (Int, Int) in
            defer { previous = value }
            return ((value - previous) & 0xFF, 9)
        }
        let spec = SampleSpec(
            name: "OpenMPT compressed reference",
            frameCount: waveform.count,
            data: compressedBlock(deltas),
            compressed: true
        )
        let sample = try XCTUnwrap(ITParser.parse(data: makeSampleIT([spec])).samplePool[1])
        XCTAssertEqual(sample.pcm, waveform.map { Float($0) / 256.0 })
    }

    func testParsedSampleModeITRendersAudibleWav() throws {
        var spec = SampleSpec(
            name: "render", frameCount: 64,
            data: (0..<64).map { UInt8(truncatingIfNeeded: $0 * 4 - 128) }
        )
        spec.loopEnabled = true
        spec.loopEnd = 64
        spec.c5Speed = 8_000
        var data = makeSampleIT([spec])

        // Pattern 0: C-5, Sample 1 und volle Lautstärke auf Kanal 1. Das Fixture
        // bleibt vollständig selbst erzeugt und läuft durch Parser UND Renderer.
        let packed = [UInt8(0x81), 0x07, 60, 1, 64, 0]
            + [UInt8](repeating: 0, count: 63)
        var pattern = [UInt8](repeating: 0, count: 8)
        putWord(packed.count, at: 0, in: &pattern)
        putWord(64, at: 2, in: &pattern)
        pattern += packed
        let patternOffset = data.count
        data.append(contentsOf: pattern)
        setDword(patternOffset, at: 0xC6, in: &data)

        let module = try ITParser.parse(data: data)
        let wav = try ModuleRenderer.renderWavData(
            mod: module, sampleRate: 8_000, maxDurationSeconds: 1,
            normalize: false, useInterpolation: false
        )
        XCTAssertEqual(module.format, .it)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertTrue(wav.dropFirst(44).contains { $0 != 0 })
    }

    func testMissingDataFlagCreatesSilentButDescribedSample() throws {
        var spec = SampleSpec(name: "empty", frameCount: 4, data: [])
        spec.dataPresent = false
        spec.c5Speed = 12_345
        // Deaktivierte Loop-Felder dürfen wie bei alten Trackern stale sein.
        spec.loopStart = 99
        spec.loopEnd = 1
        spec.sustainStart = 88
        spec.sustainEnd = 2
        let sample = try XCTUnwrap(ITParser.parse(data: makeSampleIT([spec])).samplePool[1])
        XCTAssertTrue(sample.pcm.isEmpty)
        XCTAssertNil(sample.rightPCM)
        XCTAssertEqual(sample.loopStart, 0)
        XCTAssertEqual(sample.loopLength, 0)
        XCTAssertNil(sample.sustainLoop)
        XCTAssertEqual(sample.itProperties?.c5Speed, 12_345)
    }

    func testOpenMPTMarkersInsidePCMDoNotCreateExtensionsOrWarnings() throws {
        let bytes = Array("MPTXSTPM".utf8)
        let spec = SampleSpec(name: "marker-pcm", frameCount: bytes.count, data: bytes)
        let module = try ITParser.parse(data: makeSampleIT([spec]))

        XCTAssertEqual(module.samplePool[1]?.pcm.count, bytes.count)
        XCTAssertTrue(module.itProperties?.openMPTExtensions?.chunks.isEmpty == true)
        XCTAssertTrue(module.compatibilityWarnings.isEmpty)
    }

    func testInvalidSampleSignaturePointerLoopsConversionAndCompressionFailCleanly() {
        let validSpec = SampleSpec(name: "valid", frameCount: 2, data: [0, 1])

        var badSignature = makeSampleIT([validSpec])
        let header = sampleHeaderOffset(in: badSignature)
        badSignature[badSignature.startIndex + header] = 0
        XCTAssertThrowsError(try ITParser.parse(data: badSignature)) {
            XCTAssertEqual($0 as? ITParser.ParserError, .invalidSampleHeader(1))
        }

        var badPointer = makeSampleIT([validSpec])
        setDword(badPointer.count + 1, at: header + 0x48, in: &badPointer)
        XCTAssertThrowsError(try ITParser.parse(data: badPointer)) {
            XCTAssertEqual($0 as? ITParser.ParserError, .truncatedSample(1))
        }

        var badLoopSpec = validSpec
        badLoopSpec.loopStart = 1
        badLoopSpec.loopEnd = 3
        badLoopSpec.loopEnabled = true
        XCTAssertThrowsError(try ITParser.parse(data: makeSampleIT([badLoopSpec]))) {
            XCTAssertEqual(
                $0 as? ITParser.ParserError,
                .invalidSampleLoop(sample: 1, kind: "normalen", start: 1, end: 3, length: 2)
            )
        }

        var unsupported = makeSampleIT([validSpec])
        unsupported[unsupported.startIndex + header + 0x2E] = 0x08
        XCTAssertThrowsError(try ITParser.parse(data: unsupported)) {
            XCTAssertEqual(
                $0 as? ITParser.ParserError,
                .unsupportedSampleEncoding(sample: 1, convertFlags: 0x08)
            )
        }

        var compressedSpec = validSpec
        compressedSpec.compressed = true
        compressedSpec.data = [0, 0]
        XCTAssertThrowsError(try ITParser.parse(data: makeSampleIT([compressedSpec]))) {
            XCTAssertEqual(
                $0 as? ITSampleDecompressor.DecompressionError,
                .invalidBlockLength(0)
            )
        }
    }

    // MARK: - Selbst erzeugte, frei eincheckbare Sample-Fixtures

    private func makeSampleIT(_ specs: [SampleSpec]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0xC0)
        bytes.replaceSubrange(0..<4, with: Array("IMPM".utf8))
        putWord(2, at: 0x20, in: &bytes)
        putWord(0, at: 0x22, in: &bytes)
        putWord(specs.count, at: 0x24, in: &bytes)
        putWord(1, at: 0x26, in: &bytes)
        putWord(0x0214, at: 0x28, in: &bytes)
        putWord(0x0214, at: 0x2A, in: &bytes)
        putWord(0x0001, at: 0x2C, in: &bytes) // Stereo, Sample-Mode
        bytes[0x30] = 128
        bytes[0x31] = 128
        bytes[0x32] = 6
        bytes[0x33] = 125
        bytes[0x34] = 128
        for channel in 0..<64 {
            bytes[0x40 + channel] = 32
            bytes[0x80 + channel] = 64
        }
        bytes += [0, 255]

        let sampleTable = bytes.count
        bytes += [UInt8](repeating: 0, count: specs.count * 4)
        bytes += [0, 0, 0, 0] // ein Null-Pattern

        var headerOffsets = [Int]()
        for (index, spec) in specs.enumerated() {
            let offset = bytes.count
            headerOffsets.append(offset)
            putDword(offset, at: sampleTable + index * 4, in: &bytes)
            bytes += sampleHeader(spec)
        }

        for (index, spec) in specs.enumerated() {
            if spec.dataPresent, !spec.data.isEmpty {
                putDword(bytes.count, at: headerOffsets[index] + 0x48, in: &bytes)
                bytes += spec.data
            }
        }
        return Data(bytes)
    }

    private func sampleHeader(_ spec: SampleSpec) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 80)
        header.replaceSubrange(0..<4, with: Array("IMPS".utf8))
        header[0x11] = UInt8(spec.globalVolume)
        var flags = spec.dataPresent ? 0x01 : 0
        if spec.is16Bit { flags |= 0x02 }
        if spec.isStereo { flags |= 0x04 }
        if spec.compressed { flags |= 0x08 }
        if spec.loopEnabled { flags |= 0x10 }
        if spec.sustainEnabled { flags |= 0x20 }
        if spec.pingPongLoop { flags |= 0x40 }
        if spec.pingPongSustain { flags |= 0x80 }
        header[0x12] = UInt8(flags)
        header[0x13] = UInt8(spec.volume)
        let name = Array(spec.name.utf8.prefix(25))
        header.replaceSubrange(0x14..<(0x14 + name.count), with: name)
        var convert = spec.isSigned ? 0x01 : 0
        if spec.isBigEndian { convert |= 0x02 }
        if spec.isDelta { convert |= 0x04 }
        header[0x2E] = UInt8(convert)
        header[0x2F] = spec.defaultPanning.map { UInt8(0x80 | $0) } ?? 0
        putDword(spec.frameCount, at: 0x30, in: &header)
        putDword(spec.loopStart, at: 0x34, in: &header)
        putDword(spec.loopEnd, at: 0x38, in: &header)
        putDword(spec.c5Speed, at: 0x3C, in: &header)
        putDword(spec.sustainStart, at: 0x40, in: &header)
        putDword(spec.sustainEnd, at: 0x44, in: &header)
        header[0x4C] = UInt8(spec.vibratoSpeed)
        header[0x4D] = UInt8(spec.vibratoDepth)
        header[0x4E] = UInt8(spec.vibratoRate)
        header[0x4F] = UInt8(spec.vibratoType)
        return header
    }

    private func sampleHeaderOffset(in data: Data) -> Int {
        let sampleTable = 0xC0 + 2
        return Int(data[data.startIndex + sampleTable])
            | (Int(data[data.startIndex + sampleTable + 1]) << 8)
            | (Int(data[data.startIndex + sampleTable + 2]) << 16)
            | (Int(data[data.startIndex + sampleTable + 3]) << 24)
    }

    private func assertPCM(
        _ sample: Sample,
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.pcm, expected, file: file, line: line)
        XCTAssertNil(sample.rightPCM, file: file, line: line)
    }

    // Kodiert bekannte zentrierte Integerwerte als IT-PCM. Der Test erzeugt
    // damit die Datei-Goldenwerte unabhängig vom Decoder für alle Flagkombinationen.
    private func encodeChannel(
        _ values: [Int],
        bits: Int,
        signed: Bool,
        bigEndian: Bool,
        delta: Bool
    ) -> [UInt8] {
        let modulus = bits == 16 ? 65_536 : 256
        let midpoint = modulus / 2
        var previous = 0
        var result = [UInt8]()

        for value in values {
            let representation = (signed ? value : value + midpoint) & (modulus - 1)
            let stored = delta
                ? (representation - previous) & (modulus - 1)
                : representation
            previous = representation

            if bits == 16 {
                let low = UInt8(truncatingIfNeeded: stored)
                let high = UInt8(truncatingIfNeeded: stored >> 8)
                result += bigEndian ? [high, low] : [low, high]
            } else {
                result.append(UInt8(truncatingIfNeeded: stored))
            }
        }
        return result
    }

    private func compressedBlock(_ values: [(Int, Int)]) -> [UInt8] {
        var payload = [UInt8]()
        var accumulator: UInt64 = 0
        var bitCount = 0
        for (value, width) in values {
            accumulator |= UInt64(value) << bitCount
            bitCount += width
            while bitCount >= 8 {
                payload.append(UInt8(truncatingIfNeeded: accumulator))
                accumulator >>= 8
                bitCount -= 8
            }
        }
        if bitCount > 0 { payload.append(UInt8(truncatingIfNeeded: accumulator)) }
        return [
            UInt8(truncatingIfNeeded: payload.count),
            UInt8(truncatingIfNeeded: payload.count >> 8),
        ] + payload
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

    private func setDword(_ value: Int, at offset: Int, in data: inout Data) {
        for byte in 0..<4 {
            data[data.startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
        }
    }
}
