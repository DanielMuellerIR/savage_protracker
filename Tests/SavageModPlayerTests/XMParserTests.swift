import XCTest
import Foundation
@testable import SavageModPlayerCore

// Tests für den XM-Parser (FastTracker II, .xm). Baut ein synthetisches, aber
// vollständig gültiges XM-Modul komplett in-Code als `Data` (analog zu makeS3M()
// in MultiFormatTests) und prüft, dass der Parser Header, Patterns, Instrumente,
// Samples (Delta-Dekodierung), Envelopes und Auto-Vibrato korrekt liest.
//
// Struktur des Fixtures (spiegelt make_test_xm.py):
// - 4 Kanäle, 2 Patterns, 2 Instrumente, lineare Frequenztabelle, Speed 6, BPM 125
// - Pattern 0: Note+Instrument, Note+Instrument+Volume-Column, Key-Off, sowie
//   mehrere Effekt-Zellen (0x0A, Gxx, E1x, X1x) zur Prüfung der Übersetzung
// - Pattern 1: komplett leer (patternDataSize == 0)
// - Instrument 1: 8-bit Sample mit Forward-Loop, Volume-Envelope (3 Punkte,
//   Sustain), Auto-Vibrato, fadeout=1024
// - Instrument 2: 16-bit Sample ohne Loop/Envelope, relativeNote=12
final class XMParserTests: XCTestCase {

    private let numChannels = 4
    private let numPatterns = 2
    private let numInstruments = 2

    // MARK: - Little-Endian-Byte-Helfer

    private func u8(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF)] }
    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func s8(_ v: Int) -> [UInt8] { [UInt8(bitPattern: Int8(truncatingIfNeeded: v))] }
    private func s16(_ v: Int) -> [UInt8] {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF)]
    }
    private func padName(_ s: String, _ len: Int) -> [UInt8] {
        var b = Array(s.utf8)
        precondition(b.count <= len)
        b += [UInt8](repeating: 0x20, count: len - b.count) // Space-Padding wie FT2
        return b
    }

    // MARK: - Fixture-Bausteine

    // Pattern-Notenwert (1-basiert, 1 = C-0) aus Oktave + Halbton.
    private func noteNum(_ octave: Int, _ semitone: Int) -> Int { octave * 12 + semitone + 1 }

    // Packt eine Zelle im XM-Bit7-Kompressionsschema (nur ≠0-Felder werden geschrieben).
    private func packCell(note: Int = 0, instr: Int = 0, vol: Int = 0,
                          fxType: Int = 0, fxParam: Int = 0) -> [UInt8] {
        var flags = 0x80
        var fields = [UInt8]()
        if note != 0 { flags |= 0x01; fields += u8(note) }
        if instr != 0 { flags |= 0x02; fields += u8(instr) }
        if vol != 0 { flags |= 0x04; fields += u8(vol) }
        if fxType != 0 { flags |= 0x08; fields += u8(fxType) }
        if fxParam != 0 { flags |= 0x10; fields += u8(fxParam) }
        return u8(flags) + fields
    }

    private func deltaEncode8(_ pcm: [Int]) -> [UInt8] {
        var raw = [UInt8](); var prev = 0
        for v in pcm { raw += s8(v - prev); prev = v }
        return raw
    }
    private func deltaEncode16(_ pcm: [Int]) -> [UInt8] {
        var raw = [UInt8](); var prev = 0
        for v in pcm { raw += s16(v - prev); prev = v }
        return raw
    }

    private func sine8(_ n: Int, amplitude: Double = 96) -> [Int] {
        (0..<n).map { i in
            let v = Int((amplitude * sin(2 * Double.pi * Double(i) / Double(n))).rounded())
            return max(-128, min(127, v))
        }
    }
    private func sine16(_ n: Int, amplitude: Double = 30000) -> [Int] {
        (0..<n).map { i in
            let v = Int((amplitude * sin(2 * Double.pi * Double(i) / Double(n))).rounded())
            return max(-32768, min(32767, v))
        }
    }

    private func buildHeader() -> [UInt8] {
        var h = Array("Extended Module: ".utf8)   // 17
        h += padName("SAVAGE XM TEST", 20)
        h += u8(0x1A)
        h += padName("SAVAGE XM WRITER", 20)
        h += u16(0x0104)                          // version

        var tail = [UInt8]()
        tail += u16(2)                            // songLength
        tail += u16(0)                            // restartPos
        tail += u16(numChannels)
        tail += u16(numPatterns)
        tail += u16(numInstruments)
        tail += u16(0x0001)                       // flags: Bit0 = lineare Frequenztabelle
        tail += u16(6)                            // defaultTempo (speed)
        tail += u16(125)                          // defaultBPM
        var order = [UInt8](repeating: 0, count: 256)
        order[0] = 0; order[1] = 1
        tail += order

        let headerSize = 4 + tail.count           // headerSize-Feld zählt sich selbst mit
        h += u32(headerSize)
        h += tail
        return h
    }

    private func buildPattern0() -> [UInt8] {
        let c4 = noteNum(4, 0)  // 49
        let e4 = noteNum(4, 4)  // 53
        let c5 = noteNum(5, 0)  // 61
        var data = [UInt8]()
        for row in 0..<64 {
            for ch in 0..<numChannels {
                switch (row, ch) {
                case (0, 0):  data += packCell(note: c4, instr: 1)
                case (0, 1):  data += packCell(note: e4, instr: 2, vol: 0x40)
                case (16, 0): data += packCell(note: 97)                       // Key-Off
                case (32, 0): data += packCell(note: c5, fxType: 0x0A, fxParam: 0xA0)
                case (33, 0): data += packCell(fxType: 0x10, fxParam: 0x30)    // Gxx (Global Volume)
                case (34, 0): data += packCell(fxType: 0x0E, fxParam: 0x1A)    // E1x (Fine Porta Up)
                case (35, 0): data += packCell(fxType: 0x21, fxParam: 0x15)    // X1x (Extra Fine Porta Up)
                default:      data += packCell()                              // leer -> 0x80
                }
            }
        }
        var out = u32(9) + u8(0) + u16(64) + u16(data.count) // patternHeaderLen, packingType, numRows, size
        out += data
        return out
    }

    private func buildPattern1Empty() -> [UInt8] {
        return u32(9) + u8(0) + u16(64) + u16(0) // patternDataSize = 0, keine Daten
    }

    private func buildEnvelopePoints(_ points: [(Int, Int)]) -> [UInt8] {
        var words = [Int]()
        for (x, y) in points { words += [x, y] }
        while words.count < 24 { words.append(0) }
        var out = [UInt8]()
        for w in words { out += u16(w) }
        return out
    }

    private func buildSampleHeader(sampleLength: Int, loopStart: Int, loopLength: Int,
                                   volume: Int, finetune: Int, type: Int, panning: Int,
                                   relativeNote: Int, name: String) -> [UInt8] {
        var sh = u32(sampleLength) + u32(loopStart) + u32(loopLength)
        sh += u8(volume) + s8(finetune) + u8(type) + u8(panning) + s8(relativeNote)
        sh += u8(0)                    // reserved
        sh += padName(name, 22)
        precondition(sh.count == 40)
        return sh
    }

    private func buildInstrument(name: String, volEnvPoints: [(Int, Int)], numVolPoints: Int,
                                 volSustainPoint: Int, volType: Int, vibType: Int, vibSweep: Int,
                                 vibDepth: Int, vibRate: Int, fadeout: Int,
                                 sampleHeader: [UInt8], sampleData: [UInt8]) -> [UInt8] {
        let part1 = padName(name, 22) + u8(0) + u16(1) // type=0, numSamples=1

        var part2 = u32(40)                            // sampleHeaderSize
        part2 += [UInt8](repeating: 0, count: 96)      // keymap (alle Sample 0)
        part2 += buildEnvelopePoints(volEnvPoints)     // volEnv 48
        part2 += buildEnvelopePoints([])               // panEnv 48
        part2 += u8(numVolPoints)                       // +225
        part2 += u8(0)                                  // +226 numPanPoints
        part2 += u8(volSustainPoint)                    // +227
        part2 += u8(0) + u8(0)                          // +228/+229 volLoopStart/End
        part2 += u8(0) + u8(0) + u8(0)                  // +230/+231/+232 pan sustain/loop
        part2 += u8(volType)                            // +233
        part2 += u8(0)                                  // +234 panType
        part2 += u8(vibType)                            // +235
        part2 += u8(vibSweep)                           // +236
        part2 += u8(vibDepth)                           // +237
        part2 += u8(vibRate)                            // +238
        part2 += u16(fadeout)                           // +239
        part2 += u16(0)                                 // +241 reserved
        let targetPart2 = 234
        precondition(part2.count <= targetPart2)
        part2 += [UInt8](repeating: 0, count: targetPart2 - part2.count)

        let body = part1 + part2
        let instrSize = 4 + body.count
        return u32(instrSize) + body + sampleHeader + sampleData
    }

    private func buildInstrument1() -> [UInt8] {
        let pcm = sine8(64)
        let data = deltaEncode8(pcm)
        let sh = buildSampleHeader(sampleLength: 64, loopStart: 0, loopLength: 64, volume: 64,
                                   finetune: 0, type: 0x01, panning: 128, relativeNote: 0,
                                   name: "Sine8 smp")
        return buildInstrument(name: "Sine8", volEnvPoints: [(0, 64), (20, 32), (40, 0)],
                               numVolPoints: 3, volSustainPoint: 1, volType: 0x03,
                               vibType: 0, vibSweep: 10, vibDepth: 4, vibRate: 8, fadeout: 1024,
                               sampleHeader: sh, sampleData: data)
    }

    private func buildInstrument2() -> [UInt8] {
        let pcm = sine16(128)
        let data = deltaEncode16(pcm)
        let sh = buildSampleHeader(sampleLength: 128 * 2, loopStart: 0, loopLength: 0, volume: 64,
                                   finetune: 0, type: 0x10, panning: 128, relativeNote: 12,
                                   name: "Sine16 smp")
        return buildInstrument(name: "Sine16", volEnvPoints: [], numVolPoints: 0,
                               volSustainPoint: 0, volType: 0, vibType: 0, vibSweep: 0,
                               vibDepth: 0, vibRate: 0, fadeout: 0, sampleHeader: sh, sampleData: data)
    }

    private func makeXM() -> Data {
        var bytes = buildHeader()
        bytes += buildPattern0()
        bytes += buildPattern1Empty()
        bytes += buildInstrument1()
        bytes += buildInstrument2()
        return Data(bytes)
    }

    // MARK: - Tests

    func testCanParseSignature() {
        XCTAssertTrue(XMParser.canParse(data: makeXM()))
        XCTAssertFalse(XMParser.canParse(data: Data("SCRM garbage padding here....".utf8)))
    }

    func testHeader() throws {
        let mod = try XMParser.parse(data: makeXM())
        XCTAssertEqual(mod.name, "SAVAGE XM TEST")
        XCTAssertEqual(mod.format, .xm)
        XCTAssertEqual(mod.channelCount, 4)
        XCTAssertTrue(mod.linearFrequency)
        XCTAssertEqual(mod.initialSpeed, 6)
        XCTAssertEqual(mod.initialTempo, 125)
        XCTAssertEqual(mod.initialGlobalVolume, 64)
        XCTAssertEqual(mod.length, 2)
        XCTAssertEqual(mod.patternTable, [0, 1])
        XCTAssertEqual(mod.channelPannings, [Float](repeating: 0.5, count: 4))
        XCTAssertEqual(mod.patterns.count, 2)
    }

    func testPattern0Notes() throws {
        let mod = try XMParser.parse(data: makeXM())
        let rows = mod.patterns[0].rows
        XCTAssertEqual(rows.count, 64)
        XCTAssertEqual(rows[0].notes.count, 4)

        // Row 0, Ch 0: C-4 (patternNote 49) -> key 48, Instrument 1, period immer 0
        let n00 = rows[0].notes[0]
        XCTAssertEqual(n00.key, 48)
        XCTAssertEqual(n00.instrument, 1)
        XCTAssertEqual(n00.period, 0)
        XCTAssertEqual(n00.volCmd, 0)

        // Row 0, Ch 1: E-4 (53) -> key 52, Instrument 2, Volume-Column 0x40
        let n01 = rows[0].notes[1]
        XCTAssertEqual(n01.key, 52)
        XCTAssertEqual(n01.instrument, 2)
        XCTAssertEqual(n01.volCmd, 0x40)

        // Row 16, Ch 0: Key-Off (patternNote 97)
        XCTAssertEqual(rows[16].notes[0].key, Note.keyOff)

        // Leere Zelle -> key -1
        XCTAssertEqual(rows[1].notes[0].key, -1)
    }

    func testEffectTranslation() throws {
        let mod = try XMParser.parse(data: makeXM())
        let rows = mod.patterns[0].rows

        // Row 32: C-5 + Effekt 0x0A (Volume Slide), Param 0xA0 -> unverändert
        let n32 = rows[32].notes[0]
        XCTAssertEqual(n32.key, 60)
        XCTAssertEqual(n32.effectId, 0x0A)
        XCTAssertEqual(n32.effectData, 0xA0)

        // Row 33: Gxx (0x10) -> ModuleEffect.globalVolume
        XCTAssertEqual(rows[33].notes[0].effectId, ModuleEffect.globalVolume)
        XCTAssertEqual(rows[33].notes[0].effectData, 0x30)

        // Row 34: E1x (0x0E, param 0x1A) -> 0xE1, data 0x0A
        XCTAssertEqual(rows[34].notes[0].effectId, 0xE1)
        XCTAssertEqual(rows[34].notes[0].effectData, 0x0A)

        // Row 35: X1x (0x21, param 0x15) -> extraFinePortaUp, data 5
        XCTAssertEqual(rows[35].notes[0].effectId, ModuleEffect.extraFinePortaUp)
        XCTAssertEqual(rows[35].notes[0].effectData, 5)
    }

    func testEmptyPatternHasFullRows() throws {
        let mod = try XMParser.parse(data: makeXM())
        let rows = mod.patterns[1].rows
        XCTAssertEqual(rows.count, 64)
        for row in rows {
            XCTAssertEqual(row.notes.count, 4)
            for note in row.notes {
                XCTAssertEqual(note.key, -1)
                XCTAssertEqual(note.instrument, 0)
                XCTAssertEqual(note.volCmd, 0)
            }
        }
    }

    func testInstrument1SampleAndDelta() throws {
        let mod = try XMParser.parse(data: makeXM())
        XCTAssertEqual(mod.instruments.count, 3) // nil + 2
        let inst = try XCTUnwrap(mod.instruments[1])
        XCTAssertEqual(inst.name, "Sine8")
        XCTAssertEqual(inst.keymap.count, 96)
        XCTAssertEqual(inst.samples.count, 1)

        let s = inst.samples[0]
        XCTAssertEqual(s.pcm.count, 64)
        XCTAssertEqual(s.volume, 64)
        XCTAssertEqual(s.finetune, 0)
        XCTAssertEqual(s.relativeNote, 0)
        XCTAssertEqual(s.loopType, .forward)
        XCTAssertEqual(s.loopStart, 0)
        XCTAssertEqual(s.loopLength, 64)
        XCTAssertEqual(s.panning, 128.0 / 255.0, accuracy: 0.001)

        // Delta-Dekodierung: von Hand akkumulierte Sinus-Erwartung (8-bit / 256).
        XCTAssertEqual(s.pcm[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[1], 9.0 / 256.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[2], 19.0 / 256.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[3], 28.0 / 256.0, accuracy: 1e-6)
    }

    func testInstrument1EnvelopeAndVibrato() throws {
        let mod = try XMParser.parse(data: makeXM())
        let inst = try XCTUnwrap(mod.instruments[1])

        let env = try XCTUnwrap(inst.volumeEnvelope)
        XCTAssertEqual(env.points.count, 3)
        XCTAssertEqual(env.points[0].frame, 0)
        XCTAssertEqual(env.points[0].value, 64)
        XCTAssertEqual(env.points[1].frame, 20)
        XCTAssertEqual(env.points[1].value, 32)
        XCTAssertEqual(env.points[2].frame, 40)
        XCTAssertEqual(env.points[2].value, 0)
        XCTAssertEqual(env.sustainPoint, 1)
        XCTAssertTrue(env.sustainEnabled)
        XCTAssertFalse(env.loopEnabled)

        XCTAssertNil(inst.panningEnvelope)
        XCTAssertEqual(inst.fadeout, 1024)

        let vib = try XCTUnwrap(inst.autoVibrato)
        XCTAssertEqual(vib.type, 0)
        XCTAssertEqual(vib.sweep, 10)
        XCTAssertEqual(vib.depth, 4)
        XCTAssertEqual(vib.rate, 8)
    }

    func testInstrument2SixteenBitNoEnvelope() throws {
        let mod = try XMParser.parse(data: makeXM())
        let inst = try XCTUnwrap(mod.instruments[2])
        XCTAssertEqual(inst.name, "Sine16")
        XCTAssertNil(inst.volumeEnvelope)
        XCTAssertNil(inst.panningEnvelope)
        XCTAssertNil(inst.autoVibrato)
        XCTAssertEqual(inst.fadeout, 0)

        let s = inst.samples[0]
        XCTAssertEqual(s.pcm.count, 128)      // 256 Bytes / 2
        XCTAssertEqual(s.relativeNote, 12)
        XCTAssertEqual(s.loopType, .none)

        // 16-bit Delta-Dekodierung (int16 / 65536).
        XCTAssertEqual(s.pcm[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[1], 1472.0 / 65536.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[2], 2941.0 / 65536.0, accuracy: 1e-6)
        XCTAssertEqual(s.pcm[3], 4402.0 / 65536.0, accuracy: 1e-6)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try XMParser.parse(data: Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertThrowsError(try XMParser.parse(data: Data(repeating: 0xEE, count: 500)))
    }

    // Baut ein Instrument mit VERKÜRZTEM Header (instrumentSize 38, "sample-only").
    // Solche Instrumente (von manchen Konvertern erzeugt — 9 von 12 in "BotB 9805
    // Starfish - Life Support.xm") haben keine zweite Header-Hälfte: keine Keymap,
    // Envelopes, Auto-Vibrato oder Fadeout. Läse der Parser die Felder trotzdem an
    // ihren festen Offsets (129/225/235/239), träfe er Sample-Header-/PCM-Bytes.
    private func buildMinimalInstrument(name: String, sampleHeader: [UInt8], sampleData: [UInt8]) -> [UInt8] {
        // part1 (25 B) + 9 B von part2 (sampleHeaderSize + 5 Füllbytes) = 34 B Body.
        let part1 = padName(name, 22) + u8(0) + u16(1)     // type=0, numSamples=1
        var part2 = u32(40)                                 // sampleHeaderSize (+29..+32)
        part2 += [UInt8](repeating: 0xFF, count: 5)         // Füllbytes bis Offset 38 (bewusst ≠0)
        let body = part1 + part2                             // 34 B -> instrumentSize 38
        return u32(4 + body.count) + body + sampleHeader + sampleData
    }

    // Regression 2026-07-09: Minimal-Header-Instrument darf keine (aus Sample-Bytes
    // fehlgelesene) Müll-Hüllkurve/-Auto-Vibrato tragen, aber sein Sample muss
    // trotzdem korrekt geparst werden (Parser darf nicht desynchronisieren).
    func testMinimalHeaderInstrumentHasNoGarbage() throws {
        var h = Array("Extended Module: ".utf8)
        h += padName("MIN HDR TEST", 20) + u8(0x1A) + padName("SAVAGE", 20) + u16(0x0104)
        var tail = [UInt8]()
        tail += u16(1) + u16(0) + u16(1) + u16(1) + u16(2)  // songLen, restart, ch, patterns, instruments
        tail += u16(0x0001) + u16(6) + u16(125)             // flags(linear), speed, bpm
        tail += [UInt8](repeating: 0, count: 256)           // Order-Table
        var bytes = h + u32(4 + tail.count) + tail
        bytes += u32(9) + u8(0) + u16(64) + u16(0)          // 1 leeres Pattern
        bytes += buildInstrument1()                          // #1: voller Header (mit Envelope)
        let pcm = sine8(50)
        let sh = buildSampleHeader(sampleLength: 50, loopStart: 0, loopLength: 0, volume: 48,
                                   finetune: 5, type: 0, panning: 128, relativeNote: 3, name: "min")
        bytes += buildMinimalInstrument(name: "Minimal", sampleHeader: sh, sampleData: deltaEncode8(pcm))

        let mod = try XMParser.parse(data: Data(bytes))
        // Voll-Header-Instrument behält seine Hüllkurve (keine Regression).
        XCTAssertNotNil(mod.instruments[1]?.volumeEnvelope)
        // Minimal-Header: keine zweite Hälfte — aber Sample sauber geparst.
        let minimal = try XCTUnwrap(mod.instruments[2])
        XCTAssertNil(minimal.volumeEnvelope, "Minimal-Header darf keine Müll-Hüllkurve haben")
        XCTAssertNil(minimal.panningEnvelope)
        XCTAssertNil(minimal.autoVibrato, "Minimal-Header darf kein Müll-Auto-Vibrato haben")
        XCTAssertEqual(minimal.fadeout, 0)
        XCTAssertTrue(minimal.keymap.isEmpty, "Minimal-Header -> Keymap leer (immer Sample 0)")
        let s = try XCTUnwrap(minimal.primarySample)
        XCTAssertEqual(s.pcm.count, 50, "Sample-Daten trotz Minimal-Header korrekt geparst")
        XCTAssertEqual(s.volume, 48)
        XCTAssertEqual(s.relativeNote, 3)
    }

    // Optionaler Realwelt-Test: parst alle .xm aus audio/ (gitignoriert, lokal)
    // und prüft grundlegende Plausibilität + dass beim Rendern hörbares Signal
    // entsteht. Überspringt still, wenn keine .xm vorhanden sind.
    @MainActor
    func testRealXMFilesParseAndRender() throws {
        let audioDirPath = "audio"
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioDirPath) else { return }
        let xmFiles = try fm.contentsOfDirectory(atPath: audioDirPath)
            .filter { $0.lowercased().hasSuffix(".xm") }
        guard !xmFiles.isEmpty else { return }

        for fileName in xmFiles {
            let url = URL(fileURLWithPath: (audioDirPath as NSString).appendingPathComponent(fileName))
            let mod = try ModuleLoader.parse(data: Data(contentsOf: url))
            XCTAssertEqual(mod.format, .xm, fileName)
            XCTAssertGreaterThan(mod.length, 0, fileName)
            XCTAssertGreaterThan(mod.channelCount, 0, fileName)
            XCTAssertGreaterThan(mod.patterns.count, 0, fileName)
            // Mindestens ein Instrument mit Sample-Daten.
            let withSamples = mod.instruments.compactMap { $0 }.filter { ($0.primarySample?.pcm.count ?? 0) > 0 }
            XCTAssertFalse(withSamples.isEmpty, "\(fileName): kein Instrument mit Sample-Daten")

            // Invariante gegen den Minimal-Header-Regressionsfehler (2026-07-09):
            // Wurden Envelope/Auto-Vibrato aus Sample-Bytes fehlgelesen, tauchen
            // unmögliche Werte auf (Envelope-Value > 64, Frame > 1024, Vibrato-Typ
            // > 3, Depth > 15). Reale XM-Werte liegen immer darunter.
            for inst in mod.instruments.compactMap({ $0 }) {
                for env in [inst.volumeEnvelope, inst.panningEnvelope].compactMap({ $0 }) {
                    for p in env.points {
                        XCTAssertLessThanOrEqual(p.value, 64, "\(fileName)/#\(inst.index): Envelope-Value > 64 (Müll)")
                        XCTAssertLessThanOrEqual(p.frame, 1024, "\(fileName)/#\(inst.index): Envelope-Frame > 1024 (Müll)")
                    }
                }
                if let av = inst.autoVibrato {
                    XCTAssertLessThanOrEqual(av.type, 3, "\(fileName)/#\(inst.index): Auto-Vibrato-Typ > 3 (Müll)")
                    XCTAssertLessThanOrEqual(av.depth, 15, "\(fileName)/#\(inst.index): Auto-Vibrato-Depth > 15 (Müll)")
                }
            }

            let coordinator = ModPlayerCoordinator()
            let probes = coordinator.renderProbe(mod: mod, durationSeconds: 3.0)
            let peak = probes.flatMap { $0.channelOutputs }.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "\(fileName) rendert nur Stille")
            print("✓ XM geparst + gerendert: \(fileName) (\"\(mod.name)\"), \(mod.channelCount) Kanäle, \(mod.instruments.count - 1) Instrumente, \(mod.patterns.count) Patterns, Probe-Peak \(peak)")
        }
    }
}
