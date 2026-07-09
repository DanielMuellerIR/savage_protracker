import Foundation

// Parser für FastTracker-II-Module (.xm, "Extended Module"). Übersetzt das
// XM-Format in das interne Mod-Datenmodell. Anders als bei MOD/S3M werden
// Noten hier als 0-basierter Halbton-Key (Note.key) abgelegt (period bleibt
// immer 0); Instrumente tragen echte XM-Samples (delta-dekodiert, normalisiert),
// Volume-/Panning-Envelopes, Auto-Vibrato und Fadeout.
//
// Der Aufbau folgt strikt den Längenfeldern der Datei (headerSize,
// patternHeaderLen, patternDataSize, instrumentSize, sampleHeaderSize) — es
// wird NIE über feste Offsets gesprungen, weil reale FT2-Module von den
// Idealwerten abweichen (z. B. headerSize 275 statt 276).
//
// Bewusste Vereinfachungen (dokumentiert):
// - restartPos (Order-Index für Loop-Neustart) wird ignoriert; der Song wrappt
//   wie bei den anderen Formaten auf Position 0.
// - Order-Einträge, die auf ein nicht existierendes Pattern zeigen (Index >=
//   numPatterns), werden auf ein einmalig angehängtes leeres 64-Row-Pattern
//   umgebogen (robust gegen defekte/„Skip"-Order-Tables).
// - Der rohe XM-Volume-Column-Wert wird unverändert in Note.volCmd gelegt (die
//   Auswertung Set-Volume/Slide/Vibrato/Panning macht später der DSP).
public class XMParser {
    public enum ParserError: Error, LocalizedError {
        case fileTooSmall
        case invalidSignature
        case emptySong
        case noChannels

        public var errorDescription: String? {
            switch self {
            case .fileTooSmall:
                return "Datei zu klein für ein gültiges XM-Modul."
            case .invalidSignature:
                return "Kein \"Extended Module: \"-Kennung — kein FastTracker-II-Modul."
            case .emptySong:
                return "Leeres XM-Modul: keine Songpositionen in der Order-Table."
            case .noChannels:
                return "XM-Modul ohne Kanäle."
            }
        }
    }

    // Schneller Vorab-Check für den Format-Dispatch (ModuleLoader).
    // Prüft die 17-Byte-Signatur "Extended Module: " ab Offset 0.
    public static func canParse(data: Data) -> Bool {
        let sig: [UInt8] = Array("Extended Module: ".utf8) // 17 Bytes
        guard data.count >= sig.count else { return false }
        for i in 0..<sig.count where data[data.startIndex + i] != sig[i] { return false }
        return true
    }

    public static func parse(data: Data) throws -> Mod {
        guard data.count >= 60 else { throw ParserError.fileTooSmall }
        guard canParse(data: data) else { throw ParserError.invalidSignature }

        // Little-Endian-Leser mit Bounds-Guard: außerhalb der Datei liefern sie
        // 0 statt zu crashen (defekte Dateien werden so tolerant behandelt).
        // `data` kann einen von 0 verschiedenen startIndex haben (Slices) —
        // deshalb konsequent relativ zu startIndex indizieren.
        let base = data.startIndex
        func byte(_ o: Int) -> Int {
            guard o >= 0, o < data.count else { return 0 }
            return Int(data[base + o])
        }
        func word(_ o: Int) -> Int { byte(o) | (byte(o + 1) << 8) }
        func dword(_ o: Int) -> Int { word(o) | (word(o + 2) << 16) }
        // Signed Byte (finetune, relativeNote): -128..127.
        func sbyte(_ o: Int) -> Int { Int(Int8(bitPattern: UInt8(byte(o) & 0xFF))) }
        // Latin-1-String fester Länge, 0x00/0x20-Padding entfernt.
        func string(_ o: Int, _ len: Int) -> String {
            let bytes = (0..<len).map { UInt8(truncatingIfNeeded: byte(o + $0)) }.filter { $0 != 0 }
            return (String(bytes: bytes, encoding: .isoLatin1) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // ---- Datei-Header (§1) ----
        let name = string(0x11, 20)
        let headerSize = dword(0x3C)          // Größe ab 0x3C; erstes Pattern bei 0x3C + headerSize
        var songLength = word(0x40)
        // restartPos = word(0x42) — bewusst ignoriert (Song wrappt auf 0).
        let numChannels = word(0x44)
        let numPatterns = word(0x46)
        let numInstruments = word(0x48)
        let flags = word(0x4A)
        let linearFrequency = (flags & 1) != 0  // Bit0: 0 = Amiga-Perioden, 1 = linear
        let defaultTempo = word(0x4C)           // "Speed" = Ticks pro Row -> initialSpeed
        let defaultBPM = word(0x4E)             // BPM -> initialTempo

        guard numChannels > 0 else { throw ParserError.noChannels }
        guard songLength > 0 else { throw ParserError.emptySong }
        songLength = min(songLength, 256)       // Order-Table ist immer 256 Byte

        // Order-Table (256 Byte ab 0x50), nur die ersten songLength Einträge gültig.
        var patternTable = (0..<songLength).map { byte(0x50 + $0) }

        // ---- Patterns (§2) ----
        // Ab hier strikt über die Längenfelder vorwärts seeken.
        var pos = 0x3C + headerSize
        let emptyRow = Row(notes: [Note](repeating: Note(instrument: 0, period: 0, effectId: 0, effectData: 0), count: numChannels))

        var patterns = [Pattern]()
        patterns.reserveCapacity(numPatterns)
        for _ in 0..<numPatterns {
            guard pos >= 0, pos < data.count else {
                // Datei früher zu Ende als erwartet -> Rest als leere Patterns.
                patterns.append(Pattern(rows: [Row](repeating: emptyRow, count: 64)))
                continue
            }
            let patternHeaderLen = dword(pos)
            // let packingType = byte(pos + 4) // immer 0
            var numRows = word(pos + 5)
            let patternDataSize = word(pos + 7)
            if numRows == 0 { numRows = 64 }

            // Grid mit Leernoten vorbelegen; belegte Zellen werden überschrieben.
            var grid = (0..<numRows).map { _ in
                [Note](repeating: Note(instrument: 0, period: 0, effectId: 0, effectData: 0), count: numChannels)
            }

            if patternDataSize > 0 {
                let dataStart = pos + max(patternHeaderLen, 9)
                let dataEnd = min(dataStart + patternDataSize, data.count)
                var cursor = dataStart
                let cellCount = numRows * numChannels
                var cell = 0
                while cell < cellCount && cursor < dataEnd {
                    let b = byte(cursor); cursor += 1
                    var patternNote = 0, instr = 0, vol = 0, fxType = 0, fxParam = 0
                    if b & 0x80 != 0 {
                        // Komprimiert: nur die per Bit markierten Felder folgen.
                        if b & 0x01 != 0 { patternNote = byte(cursor); cursor += 1 }
                        if b & 0x02 != 0 { instr = byte(cursor); cursor += 1 }
                        if b & 0x04 != 0 { vol = byte(cursor); cursor += 1 }
                        if b & 0x08 != 0 { fxType = byte(cursor); cursor += 1 }
                        if b & 0x10 != 0 { fxParam = byte(cursor); cursor += 1 }
                    } else {
                        // Unkomprimiert: gelesenes Byte IST die Note, dann 4 feste Felder.
                        patternNote = b
                        instr = byte(cursor); cursor += 1
                        vol = byte(cursor); cursor += 1
                        fxType = byte(cursor); cursor += 1
                        fxParam = byte(cursor); cursor += 1
                    }

                    let row = cell / numChannels
                    let ch = cell % numChannels
                    grid[row][ch] = makeNote(patternNote: patternNote, instr: instr, vol: vol,
                                             fxType: fxType, fxParam: fxParam)
                    cell += 1
                }
            }

            patterns.append(Pattern(rows: grid.map { Row(notes: $0) }))
            pos += max(patternHeaderLen, 9) + patternDataSize
        }

        // Order-Einträge auf nicht existierende Patterns -> ein leeres Pattern.
        let realPatternCount = patterns.count
        if patternTable.contains(where: { $0 < 0 || $0 >= realPatternCount }) {
            let emptyIndex = patterns.count
            patterns.append(Pattern(rows: [Row](repeating: emptyRow, count: 64)))
            patternTable = patternTable.map { ($0 >= 0 && $0 < realPatternCount) ? $0 : emptyIndex }
        }

        // ---- Instrumente (§3–§5) ----
        var instruments: [Instrument?] = [nil] // 1-basiert: Index 0 = nil
        for i in 0..<numInstruments {
            guard pos >= 0, pos < data.count else { break }
            let instrStart = pos
            let instrumentSize = dword(instrStart)
            let instName = string(instrStart + 4, 22)
            let numSamples = word(instrStart + 27)

            if numSamples == 0 {
                // Platzhalter-Instrument: kein Teil-2-Header, keine Samples.
                instruments.append(Instrument(index: i + 1, name: instName, samples: []))
                pos = instrStart + max(instrumentSize, 29)
                continue
            }

            // Teil 2 (nur wenn numSamples > 0), Offsets relativ zum Instrument-Start.
            // sampleHeaderSize liegt bei +29 (im minimalen wie im vollen Header).
            let sampleHeaderSize = instrumentSize >= 33 ? dword(instrStart + 29) : 40

            // WICHTIG: Die "zweite Hälfte" des Instrument-Headers (Keymap ab +33,
            // Envelopes ab +129, Envelope-Metadaten +225.., Vibrato +235.., Fadeout
            // +239) ist NUR vorhanden, wenn der Header groß genug ist. FastTracker II
            // schreibt hier 263 Bytes; manche Konverter/Tracker schreiben aber einen
            // "sample-only"-Header von nur 38 Bytes (instrumentSize < 241). Läse man
            // die Felder dann an ihren festen Offsets, träfe man Sample-Header-/PCM-
            // Bytes → absurde Auto-Vibrati (depth 229), Envelope-Punkte wie (8202,
            // 64054) (Lautstärke ×1000 → Clipping), Müll-Fadeout, Out-of-range-Keymap.
            // Solche Instrumente haben KEINE zweite Hälfte: Keymap = alles Sample 0,
            // keine Hüllkurven, kein Auto-Vibrato, kein Fadeout. (Feld-Ende Fadeout =
            // Offset 241 → das ist die Schwelle.)
            let hasExtendedHeader = instrumentSize >= 241

            // Volume-/Panning-Envelope-Punkte: je 12 (x,y)-Word-Paare.
            func envelopePoints(_ off: Int, _ count: Int) -> [EnvelopePoint] {
                (0..<min(count, 12)).map { j in
                    EnvelopePoint(frame: word(off + j * 4), value: word(off + j * 4 + 2))
                }
            }

            let keymap: [UInt8]
            var volumeEnvelope: Envelope?
            var panningEnvelope: Envelope?
            var autoVibrato: AutoVibrato?
            var fadeout = 0

            if hasExtendedHeader {
                keymap = (0..<96).map { UInt8(truncatingIfNeeded: byte(instrStart + 33 + $0)) }

                let numVolPoints = byte(instrStart + 225)
                let numPanPoints = byte(instrStart + 226)
                let volSustainPoint = byte(instrStart + 227)
                let volLoopStart = byte(instrStart + 228)
                let volLoopEnd = byte(instrStart + 229)
                let panSustainPoint = byte(instrStart + 230)
                let panLoopStart = byte(instrStart + 231)
                let panLoopEnd = byte(instrStart + 232)
                let volType = byte(instrStart + 233)
                let panType = byte(instrStart + 234)
                let vibType = byte(instrStart + 235)
                let vibSweep = byte(instrStart + 236)
                let vibDepth = byte(instrStart + 237)
                let vibRate = byte(instrStart + 238)
                fadeout = word(instrStart + 239)

                // Envelope nur bauen, wenn das jeweilige Type-Bit0 (on) gesetzt ist.
                if volType & 0x01 != 0 {
                    volumeEnvelope = Envelope(
                        points: envelopePoints(instrStart + 129, numVolPoints),
                        sustainPoint: volSustainPoint, loopStart: volLoopStart, loopEnd: volLoopEnd,
                        sustainEnabled: volType & 0x02 != 0, loopEnabled: volType & 0x04 != 0)
                }
                if panType & 0x01 != 0 {
                    panningEnvelope = Envelope(
                        points: envelopePoints(instrStart + 177, numPanPoints),
                        sustainPoint: panSustainPoint, loopStart: panLoopStart, loopEnd: panLoopEnd,
                        sustainEnabled: panType & 0x02 != 0, loopEnabled: panType & 0x04 != 0)
                }

                // Auto-Vibrato nur, wenn depth > 0 (sonst ohne Wirkung).
                autoVibrato = vibDepth > 0
                    ? AutoVibrato(type: vibType, sweep: vibSweep, depth: vibDepth, rate: vibRate)
                    : nil
            } else {
                keymap = []   // leer => sample(forNote:) liefert immer Sample 0
            }

            // Erst ALLE Sample-Header lesen, dann ALLE Sample-Daten (§4).
            let shStart = instrStart + max(instrumentSize, 29)
            struct RawSampleHeader {
                let length, loopStart, loopLength, volume, finetune, type, panning, relativeNote: Int
                let name: String
            }
            var rawHeaders = [RawSampleHeader]()
            rawHeaders.reserveCapacity(numSamples)
            for s in 0..<numSamples {
                let shp = shStart + s * sampleHeaderSize
                rawHeaders.append(RawSampleHeader(
                    length: dword(shp), loopStart: dword(shp + 4), loopLength: dword(shp + 8),
                    volume: byte(shp + 12), finetune: sbyte(shp + 13), type: byte(shp + 14),
                    panning: byte(shp + 15), relativeNote: sbyte(shp + 16), name: string(shp + 18, 22)))
            }

            var sdPos = shStart + numSamples * sampleHeaderSize
            var samples = [Sample]()
            samples.reserveCapacity(numSamples)
            for h in rawHeaders {
                let is16bit = (h.type & 0x10) != 0
                let availBytes = max(0, data.count - sdPos)
                let usableBytes = min(h.length, availBytes)

                // Delta-Dekodierung + Normalisierung (§5). Überlauf wrappt bewusst
                // auf die Bitbreite (&+ auf Int8/Int16).
                var pcm = [Float]()
                if is16bit {
                    let frames = usableBytes / 2
                    pcm.reserveCapacity(frames)
                    var old: Int16 = 0
                    for k in 0..<frames {
                        old = old &+ Int16(bitPattern: UInt16(word(sdPos + k * 2)))
                        pcm.append(Float(old) / 65536.0)
                    }
                } else {
                    let frames = usableBytes
                    pcm.reserveCapacity(frames)
                    var old: Int8 = 0
                    for k in 0..<frames {
                        old = old &+ Int8(bitPattern: UInt8(byte(sdPos + k) & 0xFF))
                        pcm.append(Float(old) / 256.0)
                    }
                }

                // Loop-Grenzen in Frames (16-bit: Bytes/2).
                let divisor = is16bit ? 2 : 1
                let loopType: LoopType
                switch h.type & 0x03 {
                case 1: loopType = .forward
                case 2: loopType = .pingpong
                default: loopType = .none
                }

                samples.append(Sample(
                    pcm: pcm,
                    loopStart: h.loopStart / divisor,
                    loopLength: h.loopLength / divisor,
                    loopType: loopType,
                    volume: h.volume,
                    finetune: h.finetune,
                    relativeNote: h.relativeNote,
                    panning: Float(h.panning) / 255.0,
                    c2spd: 8363,
                    name: h.name))

                sdPos += h.length // immer um die deklarierte Länge weiterrücken
            }

            instruments.append(Instrument(
                index: i + 1, name: instName, samples: samples, keymap: keymap,
                volumeEnvelope: volumeEnvelope, panningEnvelope: panningEnvelope,
                fadeout: fadeout, autoVibrato: autoVibrato))

            pos = sdPos
        }

        return Mod(
            name: name,
            length: patternTable.count,
            patternTable: patternTable,
            instruments: instruments,
            patterns: patterns,
            channelCount: numChannels,
            format: .xm,
            initialSpeed: defaultTempo > 0 ? defaultTempo : 6,
            initialTempo: defaultBPM >= 32 ? defaultBPM : 125,
            initialGlobalVolume: 64,
            channelPannings: [Float](repeating: 0.5, count: numChannels), // XM-Kanal-Default = Mitte
            linearFrequency: linearFrequency)
    }

    // Eine gepackte XM-Zelle in eine interne Note übersetzen.
    private static func makeNote(patternNote: Int, instr: Int, vol: Int,
                                 fxType: Int, fxParam: Int) -> Note {
        let key: Int
        switch patternNote {
        case 0:            key = -1              // keine Note
        case 1...96:       key = patternNote - 1 // 0-basiert (C-0=0, C-4=48)
        case 97:           key = Note.keyOff     // Key-Off (253)
        default:           key = -1              // 98..255 ungültig
        }
        let (effectId, effectData) = translateEffect(type: fxType, param: fxParam)
        return Note(instrument: instr, period: 0, effectId: effectId, effectData: effectData,
                    key: key, volume: -1, volCmd: vol)
    }

    // XM-Effekt-Typ (0x00..0x21) + Parameter auf interne (effectId, effectData)
    // übersetzen. 0x00..0x0D bleiben unverändert (ProTracker-kompatibel), die
    // E-Serie wird auf 0xE0|sub gemappt, XM-Buchstaben-Effekte (G..X) auf die
    // ModuleEffect.*-Konstanten. Nicht abbildbare Codes -> (0, 0).
    private static func translateEffect(type: Int, param: Int) -> (Int, Int) {
        switch type {
        case 0x00...0x0D:
            return (type, param)                             // Arpeggio..Pattern-Break (Dxx roh)
        case 0x0E:
            return (0xE0 | (param >> 4), param & 0x0F)       // Extended E-Serie
        case 0x0F:
            return (0x0F, param)                             // Set Speed/Tempo
        case 0x10:
            return (ModuleEffect.globalVolume, param)        // Gxx
        case 0x11:
            return (ModuleEffect.globalVolumeSlide, param)   // Hxy
        case 0x14:
            return (ModuleEffect.keyOff, param)              // Kxx
        case 0x15:
            return (ModuleEffect.setEnvelopePos, param)      // Lxx
        case 0x19:
            return (ModuleEffect.panSlide, param)            // Pxy
        case 0x1B:
            return (ModuleEffect.multiRetrig, param)         // Rxy
        case 0x1D:
            return (ModuleEffect.tremor, param)              // Txy
        case 0x21:
            switch param >> 4 {
            case 1: return (ModuleEffect.extraFinePortaUp, param & 0x0F)   // X1x
            case 2: return (ModuleEffect.extraFinePortaDown, param & 0x0F) // X2x
            default: return (0, 0)
            }
        default:
            return (0, 0)
        }
    }
}
