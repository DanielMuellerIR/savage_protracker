import Foundation

// Welches Tracker-Format ein geladenes Modul hat. Steuert im DSP das
// Frequenzmodell (Amiga-Paula-Perioden vs. ScreamTracker-3-Perioden) und
// dient UI/Quick-Look als Anzeigename.
public enum ModuleFormat: String, Sendable, Codable {
    case protracker     // klassisches 4-Kanal-ProTracker-MOD (M.K., FLT4, 4CHN)
    case soundtracker   // Ur-Soundtracker mit nur 15 Instrumenten (ohne Signatur)
    case multichannel   // MOD-Varianten mit 6/8/… Kanälen (6CHN, 8CHN, xxCH, FLT8, CD81, OKTA)
    case s3m            // ScreamTracker 3 (S3M)

    public var displayName: String {
        switch self {
        case .protracker: return "ProTracker MOD"
        case .soundtracker: return "Soundtracker (15 Samples)"
        case .multichannel: return "Multichannel MOD"
        case .s3m: return "ScreamTracker 3 (S3M)"
        }
    }
}

// Interne Effekt-IDs jenseits der ProTracker-Nibbles (0x00..0xEF). Der
// S3M-Parser übersetzt ScreamTracker-Buchstaben-Effekte, die kein direktes
// ProTracker-Gegenstück haben, auf diese Werte. Werte >= 0x100 kollidieren
// nie mit echten MOD-Effekten.
public enum ModuleEffect {
    public static let setSpeed = 0x100        // S3M Axx: Ticks pro Zeile (1..255)
    public static let setTempo = 0x101        // S3M Txx: BPM (32..255)
    public static let globalVolume = 0x102    // S3M Vxx: globale Lautstärke 0..64
    public static let tremor = 0x103          // S3M Ixy: x+1 Ticks an, y+1 Ticks aus
    public static let fineVibrato = 0x104     // S3M Uxy: Vibrato mit 1/4-Tiefe
    public static let volumeSlideS3M = 0x105  // S3M Dxy: inkl. Fine-Slides (DxF/DFy) und Memory
    public static let portaDownS3M = 0x106    // S3M Exx: inkl. Fine (EFx) / Extra-Fine (EEx)
    public static let portaUpS3M = 0x107      // S3M Fxx: inkl. Fine (FFx) / Extra-Fine (FEx)
}

public struct Note: Sendable, Codable {
    public let instrument: Int      // 0..99 (0 = kein Instrument)
    public let period: Int          // 12-Bit-Wert für Amiga-Perioden (MOD); 0 bei S3M
    public let effectId: Int        // Effekt-ID (inkl. Extended 0xE0..0xEF und ModuleEffect.*)
    public let effectData: Int      // Effekt-Datenbyte (0..255)
    // S3M-Notenschlüssel: Halbton-Index (Oktave*12 + Note, C-0 = 0). -1 = keine
    // Note, 254 = Note-Cut (^^). MOD-Dateien nutzen weiterhin `period`.
    public let key: Int
    // S3M-Volume-Column (0..64). -1 = keine Angabe.
    public let volume: Int

    // Sentinel für S3M-Note-Cut (^^) im `key`-Feld.
    public static let keyCut = 254

    public var hasEffect: Bool {
        return effectId != 0 || effectData != 0
    }

    public var effectHigh: Int {
        return (effectData >> 4) & 0x0F
    }

    public var effectLow: Int {
        return effectData & 0x0F
    }

    public init(instrument: Int, period: Int, effectId: Int, effectData: Int, key: Int = -1, volume: Int = -1) {
        self.instrument = instrument
        self.period = period
        self.effectId = effectId
        self.effectData = effectData
        self.key = key
        self.volume = volume
    }
}

public struct Row: Sendable, Codable {
    public let notes: [Note] // Immer exakt channelCount Noten (MOD klassisch: 4)

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
    // S3M: Abspielrate in Hz, bei der die Note C-4 klingt (Standard 8363).
    // MOD-Instrumente nutzen stattdessen `finetune`.
    public let c2spd: Int

    public init(index: Int, name: String, length: Int, finetune: Int, volume: Int, repeatOffset: Int, repeatLength: Int, bytes: [Int8], isLooped: Bool, c2spd: Int = 8363) {
        self.index = index
        self.name = name
        self.length = length
        self.finetune = finetune
        self.volume = volume
        self.repeatOffset = repeatOffset
        self.repeatLength = repeatLength
        self.bytes = bytes
        self.isLooped = isLooped
        self.c2spd = c2spd
    }
}

public struct Mod: Sendable, Codable {
    public let name: String
    public let length: Int          // Anzahl der Songpositionen in der Playlist
    public let patternTable: [Int]  // Playlist (Indizes der Patterns)
    public let instruments: [Instrument?] // 1-basiertes Array (Index 0 ist nil)
    public let patterns: [Pattern]
    public let channelCount: Int    // Kanäle pro Row (MOD klassisch 4, S3M bis 32)
    public let format: ModuleFormat
    public let initialSpeed: Int    // Ticks pro Zeile beim Start (MOD: 6)
    public let initialTempo: Int    // BPM beim Start (MOD: 125)
    // Globale Start-Lautstärke 0..64 (S3M-Header; MOD hat das Konzept nicht -> 64).
    public let initialGlobalVolume: Int
    // Start-Panning pro Kanal (0 = links, 1 = rechts). Immer channelCount Einträge.
    public let channelPannings: [Float]

    public init(
        name: String,
        length: Int,
        patternTable: [Int],
        instruments: [Instrument?],
        patterns: [Pattern],
        channelCount: Int = 4,
        format: ModuleFormat = .protracker,
        initialSpeed: Int = 6,
        initialTempo: Int = 125,
        initialGlobalVolume: Int = 64,
        channelPannings: [Float] = []
    ) {
        self.name = name
        self.length = length
        self.patternTable = patternTable
        self.instruments = instruments
        self.patterns = patterns
        self.channelCount = channelCount
        self.format = format
        self.initialSpeed = initialSpeed
        self.initialTempo = initialTempo
        self.initialGlobalVolume = initialGlobalVolume
        self.channelPannings = channelPannings.count == channelCount
            ? channelPannings
            : Mod.defaultAmigaPannings(channelCount: channelCount)
    }

    // Amiga-Standard-Panning LRRL, für mehr Kanäle periodisch fortgesetzt
    // (Kanal 1/4/5/8/... links, 2/3/6/7/... rechts, mit etwas Bleed).
    public static func defaultAmigaPannings(channelCount: Int) -> [Float] {
        return (0..<max(0, channelCount)).map { i in
            let pos = i % 4
            return (pos == 0 || pos == 3) ? 0.1 : 0.9
        }
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
                return "Datei zu klein für ein gültiges MOD-Modul."
            case .invalidSignature(let sig):
                let clean = sig.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Unbekannte oder nicht unterstützte Signatur '\(clean)' (kein unterstütztes Amiga-MOD)."
            case .emptySong:
                return "Leeres Modul: keine Songpositionen (Länge 0)."
            }
        }
    }

    // Ergebnis der Signatur-Erkennung: bestimmt, wie die Datei gelesen wird.
    private struct Layout {
        let channelCount: Int     // Logische Kanäle des Moduls (4, 6, 8, …)
        let instrumentCount: Int  // 31 (mit Signatur) oder 15 (Ur-Soundtracker)
        let format: ModuleFormat
        // FLT8 (StarTrekker) speichert 8 Kanäle als PAARE von 4-Kanal-Patterns:
        // logisches Pattern k = gespeicherte Patterns 2k (Kanal 1-4) und 2k+1
        // (Kanal 5-8). Die Playlist-Einträge zeigen auf das jeweils erste
        // gespeicherte Pattern und müssen halbiert werden.
        let flt8: Bool
    }

    // Signatur (Offset 1080) auf Layout mappen. Kein Treffer und keine
    // plausible 15-Sample-Struktur -> invalidSignature.
    private static func detectLayout(data: Data) throws -> Layout {
        if data.count >= 1084 {
            let sigBytes = data.subdata(in: 1080..<1084)
            let sig = String(decoding: sigBytes, as: UTF8.self)

            switch sig {
            case "M.K.", "M!K!", "FLT4", "4CHN":
                return Layout(channelCount: 4, instrumentCount: 31, format: .protracker, flt8: false)
            case "FLT8":
                return Layout(channelCount: 8, instrumentCount: 31, format: .multichannel, flt8: true)
            case "CD81", "OKTA", "OCTA":
                return Layout(channelCount: 8, instrumentCount: 31, format: .multichannel, flt8: false)
            default:
                break
            }

            // "xCHN" (2..9 Kanäle, z.B. 6CHN/8CHN)
            let chars = Array(sig)
            if chars.count == 4, chars[1] == "C", chars[2] == "H", chars[3] == "N",
               let n = chars[0].wholeNumberValue, n >= 2, n <= 9 {
                return Layout(channelCount: n, instrumentCount: 31, format: n == 4 ? .protracker : .multichannel, flt8: false)
            }
            // "xxCH" (10..32 Kanäle, z.B. 10CH..32CH)
            if chars.count == 4, chars[2] == "C", chars[3] == "H",
               let d1 = chars[0].wholeNumberValue, let d2 = chars[1].wholeNumberValue {
                let n = d1 * 10 + d2
                if n >= 10 && n <= 32 && n % 2 == 0 {
                    return Layout(channelCount: n, instrumentCount: 31, format: .multichannel, flt8: false)
                }
            }

            // Keine bekannte Signatur: unten die 15-Sample-Heuristik versuchen,
            // sonst mit genau dieser Signatur im Fehlertext ablehnen.
            if looksLikeSoundtracker15(data: data) {
                return Layout(channelCount: 4, instrumentCount: 15, format: .soundtracker, flt8: false)
            }
            throw ParserError.invalidSignature(sig)
        }

        // Zu klein für ein 31-Instrument-MOD: nur noch Ur-Soundtracker möglich.
        if looksLikeSoundtracker15(data: data) {
            return Layout(channelCount: 4, instrumentCount: 15, format: .soundtracker, flt8: false)
        }
        throw ParserError.fileTooSmall
    }

    // Ur-Soundtracker-Module (15 Instrumente) haben KEINE Signatur — sie sind
    // nur an einer durchgehend plausiblen Header-Struktur erkennbar. Die Checks
    // sind bewusst streng, damit beliebige Binärdaten nicht als Modul durchgehen.
    private static func looksLikeSoundtracker15(data: Data) -> Bool {
        // Mindestgröße: Header (600 Bytes) + ein volles Pattern (1024 Bytes).
        guard data.count >= 600 + 1024 else { return false }

        let songLength = Int(data[470])
        guard songLength >= 1 && songLength <= 128 else { return false }

        // Alle 128 Playlist-Einträge müssen gültige Pattern-Indizes sein.
        var maxPattern = 0
        for i in 0..<128 {
            let entry = Int(data[472 + i])
            guard entry < 64 else { return false }
            if i < songLength { maxPattern = max(maxPattern, entry) }
        }

        // Instrument-Header: Volume 0..64, Finetune-Byte 0 (das Feld gab es
        // im Ur-Soundtracker nicht), Sample-Länge in plausiblem Rahmen.
        var totalSampleBytes = 0
        for i in 0..<15 {
            let offset = 20 + i * 30
            let length = 2 * Int(UInt16(data[offset + 22]) << 8 | UInt16(data[offset + 23]))
            guard data[offset + 24] & 0xF0 == 0 else { return false }
            guard Int(data[offset + 25]) <= 64 else { return false }
            guard length <= 65536 else { return false }
            totalSampleBytes += length
        }

        // Die deklarierten Patterns müssen vollständig in der Datei liegen.
        let patternsEnd = 600 + (maxPattern + 1) * 1024
        guard data.count >= patternsEnd else { return false }
        // Und die Gesamtstruktur darf die Dateigröße nicht absurd verfehlen
        // (kleiner Puffer für Trailer-Bytes mancher Ripper).
        guard patternsEnd + totalSampleBytes <= data.count + 1024 else { return false }

        return true
    }

    public static func parse(data: Data) throws -> Mod {
        guard data.count >= 600 else {
            throw ParserError.fileTooSmall
        }

        let layout = try detectLayout(data: data)

        // Offsets aus dem Layout ableiten: 31 Instrumente -> Playlist ab 950,
        // Signatur 1080, Patterns ab 1084. 15 Instrumente (Ur-Soundtracker) ->
        // Playlist ab 470, KEINE Signatur, Patterns ab 600.
        let headerSize = 20 + layout.instrumentCount * 30
        let orderOffset = headerSize + 2
        let patternsOffset = orderOffset + 128 + (layout.instrumentCount == 31 ? 4 : 0)
        // FLT8 speichert physisch 4-Kanal-Patterns (Paare); alle anderen
        // Varianten speichern Rows mit channelCount*4 Bytes am Stück.
        let storedChannels = layout.flt8 ? 4 : layout.channelCount
        let storedPatternBytes = 64 * storedChannels * 4

        // 1. Songname parsen (Offset 0, 20 Bytes)
        // Amiga-Strings sind roh/Latin-1, nicht UTF-8 — UTF-8-Dekodierung
        // verstuemmelte High-Bytes (z.B. © 0xA9 -> "?"). isoLatin1 mappt jedes
        // Byte direkt auf U+00XX und stimmt mit der JS-Variante (fromCodePoint) ueberein.
        let nameBytes = data.subdata(in: 0..<20).filter { $0 != 0 }
        let name = (String(bytes: nameBytes, encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Playlist / PatternTable parsen
        let songLength = Int(data[headerSize])
        // Eine leere Playlist (length 0) ergibt ein nicht abspielbares Mod und
        // wuerde in der UI patternTable[-1] indizieren -> Crash. Sauber ablehnen.
        guard songLength > 0 else {
            throw ParserError.emptySong
        }
        var patternTable = [Int]()
        for i in 0..<songLength {
            if orderOffset + i < data.count {
                let raw = Int(data[orderOffset + i])
                // FLT8: Eintrag zeigt auf das erste 4-Kanal-Pattern des Paares.
                patternTable.append(layout.flt8 ? raw >> 1 : raw)
            } else {
                break
            }
        }

        let maxPatternIndex = patternTable.max() ?? 0
        // Anzahl physisch gespeicherter Patterns (FLT8: 2 pro logischem Pattern).
        let storedPatternCount = layout.flt8 ? (maxPatternIndex + 1) * 2 : maxPatternIndex + 1

        // 3. Instrumenten-Header parsen (Offset 20, je 30 Bytes)
        var instruments: [Instrument?] = [nil] // Index 0 ist leer
        var sampleStartOffset = patternsOffset + storedPatternCount * storedPatternBytes

        for i in 0..<layout.instrumentCount {
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
            // Ur-Soundtracker speichert den Repeat-Offset in BYTES, alle
            // 31-Instrument-Varianten in Words (x2).
            let repeatOffsetRaw = Int(UInt16(header[26]) << 8 | UInt16(header[27]))
            let repeatOffset = layout.instrumentCount == 15 ? repeatOffsetRaw : 2 * repeatOffsetRaw
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

        // 4. Physisch gespeicherte Patterns parsen (Row = storedChannels * 4 Bytes)
        var storedPatterns = [Pattern]()
        for p in 0..<storedPatternCount {
            let patternOffset = patternsOffset + p * storedPatternBytes
            if patternOffset >= data.count { break }

            var rows = [Row]()
            for r in 0..<64 {
                let rowOffset = patternOffset + r * storedChannels * 4
                if rowOffset >= data.count { break }

                var notes = [Note]()
                for c in 0..<storedChannels {
                    let noteOffset = rowOffset + c * 4
                    if noteOffset + 3 >= data.count {
                        // Fehlende Kanäle bleiben leer, damit jede Zeile
                        // weiterhin exakt storedChannels Noten besitzt.
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

                // Jede Zeile muss für UI und DSP exakt storedChannels Noten liefern.
                while notes.count < storedChannels {
                    notes.append(Note(instrument: 0, period: 0, effectId: 0, effectData: 0))
                }
                rows.append(Row(notes: notes))
            }

            // Jedes Pattern muss exakt 64 Zeilen liefern.
            while rows.count < 64 {
                rows.append(Row(notes: (0..<storedChannels).map { _ in
                    Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
                }))
            }
            storedPatterns.append(Pattern(rows: rows))
        }

        // 5. FLT8: Paare von 4-Kanal-Patterns zu logischen 8-Kanal-Patterns mischen.
        var patterns = [Pattern]()
        if layout.flt8 {
            var k = 0
            while k * 2 < storedPatterns.count {
                let first = storedPatterns[k * 2]
                // Fehlt die zweite Hälfte (abgeschnittene Datei), bleiben Kanal 5-8 leer.
                let second = k * 2 + 1 < storedPatterns.count ? storedPatterns[k * 2 + 1] : nil
                var rows = [Row]()
                for r in 0..<64 {
                    let tail = second?.rows[r].notes ?? (0..<4).map { _ in
                        Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
                    }
                    rows.append(Row(notes: first.rows[r].notes + tail))
                }
                patterns.append(Pattern(rows: rows))
                k += 1
            }
        } else {
            patterns = storedPatterns
        }

        return Mod(
            name: name,
            length: songLength,
            patternTable: patternTable,
            instruments: instruments,
            patterns: patterns,
            channelCount: layout.channelCount,
            format: layout.format,
            channelPannings: Mod.defaultAmigaPannings(channelCount: layout.channelCount)
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
