import Foundation

public struct Note: Sendable, Codable {
    public let instrument: Int      // 0..31 (0 = kein Instrument)
    public let period: Int          // 12-Bit-Wert für Amiga-Perioden
    public let effectId: Int        // Effekt-ID (inkl. Extended 0xE0..0xEF)
    public let effectData: Int      // Effekt-Datenbyte (0..255)

    public var hasEffect: Bool {
        return effectId != 0 || effectData != 0
    }

    public var effectHigh: Int {
        return (effectData >> 4) & 0x0F
    }

    public var effectLow: Int {
        return effectData & 0x0F
    }

    public init(instrument: Int, period: Int, effectId: Int, effectData: Int) {
        self.instrument = instrument
        self.period = period
        self.effectId = effectId
        self.effectData = effectData
    }
}

public struct Row: Sendable, Codable {
    public let notes: [Note] // Immer exakt 4 Kanäle

    public init(notes: [Note]) {
        self.notes = notes
    }
}

public struct Pattern: Sendable, Codable {
    public let rows: [Row] // Immer exakt 64 Zeilen

    public init(rows: [Row]) {
        self.rows = rows
    }
}

public struct Instrument: Sendable, Codable {
    public let index: Int
    public let name: String
    public let length: Int          // In Bytes
    public let finetune: Int        // -8..7
    public let volume: Int          // 0..64
    public let repeatOffset: Int    // In Bytes
    public let repeatLength: Int    // In Bytes
    public let bytes: [Int8]        // Signed 8-bit Sample-Daten
    public let isLooped: Bool

    public init(index: Int, name: String, length: Int, finetune: Int, volume: Int, repeatOffset: Int, repeatLength: Int, bytes: [Int8], isLooped: Bool) {
        self.index = index
        self.name = name
        self.length = length
        self.finetune = finetune
        self.volume = volume
        self.repeatOffset = repeatOffset
        self.repeatLength = repeatLength
        self.bytes = bytes
        self.isLooped = isLooped
    }
}

public struct Mod: Sendable, Codable {
    public let name: String
    public let length: Int          // Anzahl der Songpositionen in der Playlist
    public let patternTable: [Int]  // Playlist (Indizes der Patterns)
    public let instruments: [Instrument?] // 1-basiertes Array (Index 0 ist nil)
    public let patterns: [Pattern]

    public init(name: String, length: Int, patternTable: [Int], instruments: [Instrument?], patterns: [Pattern]) {
        self.name = name
        self.length = length
        self.patternTable = patternTable
        self.instruments = instruments
        self.patterns = patterns
    }
}

public class ModParser {
    public enum ParserError: Error, LocalizedError {
        case fileTooSmall
        case invalidSignature(String)
        case emptySong

        public var errorDescription: String? {
            switch self {
            case .fileTooSmall:
                return "Datei zu klein für ein gültiges MOD-Modul (mindestens 1084 Bytes)."
            case .invalidSignature(let sig):
                let clean = sig.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Unbekannte oder nicht unterstützte Signatur '\(clean)' (kein 4-Kanal-MOD)."
            case .emptySong:
                return "Leeres Modul: keine Songpositionen (Länge 0)."
            }
        }
    }

    public static func parse(data: Data) throws -> Mod {
        guard data.count >= 1084 else {
            throw ParserError.fileTooSmall
        }

        // 1. Songname parsen (Offset 0, 20 Bytes)
        // Amiga-Strings sind roh/Latin-1, nicht UTF-8 — UTF-8-Dekodierung
        // verstuemmelte High-Bytes (z.B. © 0xA9 -> "?"). isoLatin1 mappt jedes
        // Byte direkt auf U+00XX und stimmt mit der JS-Variante (fromCodePoint) ueberein.
        let nameBytes = data.subdata(in: 0..<20).filter { $0 != 0 }
        let name = (String(bytes: nameBytes, encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Signatur prüfen (Offset 1080, 4 Bytes)
        let sigBytes = data.subdata(in: 1080..<1084)
        let sig = String(decoding: sigBytes, as: UTF8.self)
        // Nur echte 4-Kanal-Signaturen. 6CHN/8CHN/FLT8 haben groessere Row-/
        // Pattern-Strides (channels*4 Bytes pro Row) — sie hier zu akzeptieren
        // wuerde Notizen UND Sampledaten aus falschen Offsets lesen (Garbage).
        // Bis echtes Multichannel-Parsing existiert, werden sie sauber abgelehnt.
        let validSigs = ["M.K.", "M!K!", "FLT4", "4CHN"]
        guard validSigs.contains(sig) else {
            throw ParserError.invalidSignature(sig)
        }

        // 3. Playlist / PatternTable parsen (Offset 950)
        let songLength = Int(data[950])
        // Eine leere Playlist (length 0) ergibt ein nicht abspielbares Mod und
        // wuerde in der UI patternTable[-1] indizieren -> Crash. Sauber ablehnen.
        guard songLength > 0 else {
            throw ParserError.emptySong
        }
        var patternTable = [Int]()
        for i in 0..<songLength {
            if 952 + i < data.count {
                patternTable.append(Int(data[952 + i]))
            } else {
                break
            }
        }

        let maxPatternIndex = patternTable.max() ?? 0

        // 4. Instrumenten-Header parsen (Offset 20, 31 Instrumente zu je 30 Bytes)
        var instruments: [Instrument?] = [nil] // Index 0 ist leer
        var sampleStartOffset = 1084 + (maxPatternIndex + 1) * 1024

        for i in 0..<31 {
            let offset = 20 + i * 30
            let header = data.subdata(in: offset..<(offset + 30))

            // Wie der Songname: roh/Latin-1 dekodieren (parity zur JS-Variante).
            let instNameBytes = header.subdata(in: 0..<22).filter { $0 != 0 }
            let instName = (String(bytes: instNameBytes, encoding: .isoLatin1) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Big-Endian Words
            let instLength = 2 * Int(UInt16(header[22]) << 8 | UInt16(header[23]))

            // Finetune (signed 4-bit nibble)
            var finetune = Int(header[24] & 0x0F)
            if finetune > 7 { finetune -= 16 }

            let volume = Int(header[25])
            let repeatOffset = 2 * Int(UInt16(header[26]) << 8 | UInt16(header[27]))
            let repeatLength = 2 * Int(UInt16(header[28]) << 8 | UInt16(header[29]))

            // Sample-Bytes extrahieren
            let start = min(sampleStartOffset, data.count)
            let end = min(start + instLength, data.count)
            let sampleData = data.subdata(in: start..<end)

            // Convert to signed Int8
            let bytes = sampleData.map { Int8(bitPattern: $0) }
            sampleStartOffset += instLength

            // Eine Probe loopt genau dann, wenn die Loop-Laenge > 1 Word (> 2 Bytes)
            // ist. Ein repeatOffset > 0 allein markiert KEINEN Loop — sonst wuerde
            // ein One-Shot mit gesetztem Offset, aber 2-Byte-Sentinel-Laenge faelsch
            // eine winzige Region loopen (Brummen statt Ausklang).
            let isLooped = repeatLength > 2

            let instrument = Instrument(
                index: i + 1,
                name: instName,
                length: instLength,
                finetune: finetune,
                volume: volume,
                repeatOffset: repeatOffset,
                repeatLength: repeatLength,
                bytes: bytes,
                isLooped: isLooped
            )
            instruments.append(instrument)
        }

        // 5. Patterns parsen (Ab Offset 1084, jedes Pattern ist 1024 Bytes groß)
        var patterns = [Pattern]()
        for p in 0...maxPatternIndex {
            let patternOffset = 1084 + p * 1024
            if patternOffset >= data.count { break }

            var rows = [Row]()
            for r in 0..<64 {
                let rowOffset = patternOffset + r * 16
                if rowOffset >= data.count { break }

                var notes = [Note]()
                for c in 0..<4 {
                    let noteOffset = rowOffset + c * 4
                    if noteOffset + 3 >= data.count {
                        // Fehlende Kanäle bleiben leer, damit jede Zeile
                        // weiterhin exakt die 4 ProTracker-Kanäle besitzt.
                        notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
                        continue
                    }

                    let b0 = data[noteOffset]
                    let b1 = data[noteOffset + 1]
                    let b2 = data[noteOffset + 2]
                    let b3 = data[noteOffset + 3]

                    // Instrumenten-Index: Splitting über Byte 0 und Byte 2
                    let instrument = Int(b0 & 0xF0) | Int(b2 >> 4)

                    // Period (12-bit)
                    let period = Int(b0 & 0x0F) << 8 | Int(b1)

                    // Effekt
                    var effectId = Int(b2 & 0x0F)
                    var effectData = Int(b3)

                    if effectId == 0x0E {
                        effectId = 0xE0 | (effectData >> 4)
                        effectData &= 0x0F
                    }

                    notes.append(Note(
                        instrument: instrument,
                        period: period,
                        effectId: effectId,
                        effectData: effectData
                    ))
                }

                // Jede Zeile muss für UI und DSP exakt 4 Noten liefern.
                while notes.count < 4 {
                    notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
                }
                rows.append(Row(notes: notes))
            }

            // Jedes Pattern muss exakt 64 Zeilen liefern.
            while rows.count < 64 {
                rows.append(Row(notes: [
                    Note(instrument: 0, period: 0, effectId: 0, effectData: 0),
                    Note(instrument: 0, period: 0, effectId: 0, effectData: 0),
                    Note(instrument: 0, period: 0, effectId: 0, effectData: 0),
                    Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
                ]))
            }
            patterns.append(Pattern(rows: rows))
        }

        return Mod(
            name: name,
            length: songLength,
            patternTable: patternTable,
            instruments: instruments,
            patterns: patterns
        )
    }

    public static func generateDemoMod() -> Mod {
        var instruments = [Instrument?]()
        instruments.append(nil) // index 0

        // Square wave sample bytes
        var bytes = [Int8](repeating: 0, count: 256)
        for i in 0..<256 {
            bytes[i] = i < 128 ? 64 : -64
        }

        let demoInst = Instrument(
            index: 1,
            name: "Cyber Synth Osc",
            length: 256,
            finetune: 0,
            volume: 64,
            repeatOffset: 0,
            repeatLength: 256,
            bytes: bytes,
            isLooped: true
        )
        instruments.append(demoInst)

        for i in 2...31 {
            instruments.append(Instrument(
                index: i,
                name: "Empty Sample \(i)",
                length: 0,
                finetune: 0,
                volume: 0,
                repeatOffset: 0,
                repeatLength: 0,
                bytes: [],
                isLooped: false
            ))
        }

        var rows = [Row]()
        // C-major scale note periods: C-3 (214), E-3 (171), G-3 (144), C-4 (107)
        let melody = [214, 171, 144, 107, 144, 171]
        for r in 0..<64 {
            var notes = [Note]()

            // Channel 1: Lead Melody
            if r % 4 == 0 {
                let notePeriod = melody[(r / 4) % melody.count]
                notes.append(Note(instrument: 1, period: notePeriod, effectId: 0, effectData: 0))
            } else {
                notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
            }

            // Channel 2: Arpeggio Chords
            if r % 8 == 0 {
                notes.append(Note(instrument: 1, period: 214, effectId: 0x00, effectData: 0x47))
            } else {
                notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
            }

            // Channels 3 & 4 empty
            notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
            notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))

            rows.append(Row(notes: notes))
        }

        let pattern = Pattern(rows: rows)

        return Mod(
            name: "Cyber Synth Demo",
            length: 1,
            patternTable: [0],
            instruments: instruments,
            patterns: [pattern]
        )
    }
}
