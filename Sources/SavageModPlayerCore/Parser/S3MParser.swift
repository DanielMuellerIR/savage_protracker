import Foundation

// Parser für ScreamTracker-3-Module (.s3m). Übersetzt das S3M-Format in das
// interne Mod-Datenmodell: Noten werden als Halbton-Keys (Note.key) abgelegt,
// Buchstaben-Effekte auf ProTracker-IDs bzw. ModuleEffect.*-IDs gemappt.
// Der DSP spielt S3M dann über das ST3-Periodenmodell (s3mMode) ab.
//
// Bewusste Vereinfachungen (dokumentiert, betreffen nur seltene Module):
// - AdLib-Instrumente (Typ >= 2) werden als stille Instrumente geladen.
// - Stereo-Samples nutzen nur den linken Kanal, 16-Bit-Samples werden auf
//   8 Bit reduziert (High-Byte) — passend zur 8-Bit-Engine des Players.
// - Qxy (Retrigger) ignoriert den Volume-Modifier x.
// - Txy mit x < 2 (Tempo-Slide) und "Fast Volume Slides" (ST3.00) fehlen.
public class S3MParser {
    public enum ParserError: Error, LocalizedError {
        case fileTooSmall
        case invalidSignature
        case emptySong
        case noChannels

        public var errorDescription: String? {
            switch self {
            case .fileTooSmall:
                return "Datei zu klein für ein gültiges S3M-Modul."
            case .invalidSignature:
                return "Keine SCRM-Signatur — kein ScreamTracker-3-Modul."
            case .emptySong:
                return "Leeres S3M-Modul: keine abspielbaren Songpositionen."
            case .noChannels:
                return "S3M-Modul ohne aktive PCM-Kanäle."
            }
        }
    }

    // Schneller Vorab-Check für den Format-Dispatch (ModuleLoader).
    public static func canParse(data: Data) -> Bool {
        guard data.count >= 0x60 else { return false }
        return data[0x2C] == 0x53 && data[0x2D] == 0x43 && data[0x2E] == 0x52 && data[0x2F] == 0x4D // "SCRM"
    }

    public static func parse(data: Data) throws -> Mod {
        guard data.count >= 0x60 else { throw ParserError.fileTooSmall }
        guard canParse(data: data) else { throw ParserError.invalidSignature }

        // Little-Endian-Leser mit Bounds-Guard (korrupte Dateien liefern 0
        // statt zu crashen; die Struktur-Checks unten fangen den Rest).
        func byte(_ o: Int) -> Int { o >= 0 && o < data.count ? Int(data[o]) : 0 }
        func word(_ o: Int) -> Int { byte(o) | (byte(o + 1) << 8) }
        func dword(_ o: Int) -> Int { word(o) | (word(o + 2) << 16) }

        // ---- Header ----
        let nameBytes = data.subdata(in: 0..<28).filter { $0 != 0 }
        let name = (String(bytes: nameBytes, encoding: .isoLatin1) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ordNum = word(0x20)
        let insNum = word(0x22)
        let patNum = word(0x24)
        let ffi = word(0x2A)            // 1 = signed Samples (alt), 2 = unsigned
        let globalVolume = byte(0x30)
        let initialSpeed = byte(0x31)
        let initialTempo = byte(0x32)
        let masterVolume = byte(0x33)   // Bit 7 = Stereo
        let defaultPanFlag = byte(0x35) // 0xFC = Pan-Sektion vorhanden

        guard 0x60 + ordNum + insNum * 2 + patNum * 2 <= data.count else {
            throw ParserError.fileTooSmall
        }

        // ---- Kanal-Settings (32 Bytes ab 0x40) ----
        // Werte 0..15 sind PCM-Kanäle (0-7 = Links 1-8, 8-15 = Rechts 1-8),
        // 16..31 AdLib, 255 unbenutzt. Wir spielen nur PCM-Kanäle und
        // verdichten sie auf ein kompaktes 0..N-1-Layout.
        var channelMap = [Int](repeating: -1, count: 32)
        var channelIsRight = [Bool]()
        var channelCount = 0
        for i in 0..<32 {
            let setting = byte(0x40 + i)
            if setting < 16 {
                channelMap[i] = channelCount
                channelIsRight.append(setting >= 8)
                channelCount += 1
            }
        }
        guard channelCount > 0 else { throw ParserError.noChannels }

        // ---- Order-Liste ----
        // 254 (++) = Skip-Marker, 255 (--) = Ende. Beide werden entfernt;
        // damit Bxx (Position Jump) weiter stimmt, merken wir uns pro
        // Original-Index den Ziel-Index in der gefilterten Liste.
        var patternTable = [Int]()
        var rawIsMarker = [Bool](repeating: false, count: ordNum)
        for i in 0..<ordNum {
            let v = byte(0x60 + i)
            if v >= 254 {
                rawIsMarker[i] = true
            } else {
                patternTable.append(v)
            }
        }
        guard !patternTable.isEmpty else { throw ParserError.emptySong }

        // orderMap[original] = Index in patternTable; Marker zeigen auf den
        // nächsten echten Eintrag (ST3 spielt dort weiter).
        var orderMap = [Int](repeating: 0, count: max(1, ordNum))
        var filtered = 0
        for i in 0..<ordNum {
            orderMap[i] = min(filtered, patternTable.count - 1)
            if !rawIsMarker[i] { filtered += 1 }
        }

        // ---- Parapointer ----
        let instParaOffset = 0x60 + ordNum
        let patParaOffset = instParaOffset + insNum * 2

        // ---- Default-Panning ----
        // Mono: alles Mitte. Stereo: L/R nach Kanal-Setting. Eine Pan-Sektion
        // (dp == 0xFC, 32 Bytes hinter den Pattern-Parapointern) übersteuert.
        let stereo = (masterVolume & 0x80) != 0
        var pannings = (0..<channelCount).map { i -> Float in
            stereo ? (channelIsRight[i] ? 0.8 : 0.2) : 0.5
        }
        if defaultPanFlag == 0xFC {
            let panOffset = patParaOffset + patNum * 2
            for i in 0..<32 {
                let target = channelMap[i]
                guard target >= 0 else { continue }
                let p = byte(panOffset + i)
                if p & 0x20 != 0 {
                    pannings[target] = Float(p & 0x0F) / 15.0
                }
            }
        }

        // ---- Instrumente ----
        var instruments: [Instrument?] = [nil]
        for i in 0..<insNum {
            let off = word(instParaOffset + i * 2) * 16
            let type = byte(off)
            let hasSCRS = byte(off + 0x4C) == 0x53 && byte(off + 0x4D) == 0x43
                && byte(off + 0x4E) == 0x52 && byte(off + 0x4F) == 0x53

            let instNameBytes = (0..<28).map { UInt8(byte(off + 0x30 + $0)) }.filter { $0 != 0 }
            let instName = (String(bytes: instNameBytes, encoding: .isoLatin1) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard type == 1, hasSCRS, off > 0 else {
                // Leer-/AdLib-Instrument: Platzhalter, damit die Indizes stimmen.
                instruments.append(Instrument(
                    index: i + 1, name: instName, length: 0, finetune: 0,
                    volume: 0, repeatOffset: 0, repeatLength: 0, bytes: [],
                    isLooped: false
                ))
                continue
            }

            let memseg = (byte(off + 0x0D) << 16) | word(off + 0x0E)
            let sampleOffset = memseg * 16
            var length = dword(off + 0x10)
            var loopStart = dword(off + 0x14)
            var loopEnd = dword(off + 0x18)
            let volume = min(64, byte(off + 0x1C))
            let flags = byte(off + 0x1F) // 1 = Loop, 2 = Stereo, 4 = 16 Bit
            var c2spd = dword(off + 0x20)
            if c2spd <= 0 { c2spd = 8363 }

            let is16Bit = (flags & 4) != 0
            let bytesPerSample = is16Bit ? 2 : 1
            // Nur so viele Samples übernehmen, wie wirklich in der Datei liegen.
            if sampleOffset < data.count {
                length = min(length, (data.count - sampleOffset) / bytesPerSample)
            } else {
                length = 0
            }

            var bytes = [Int8]()
            bytes.reserveCapacity(length)
            for s in 0..<length {
                let raw: Int
                if is16Bit {
                    // 16 Bit -> 8 Bit: High-Byte des Little-Endian-Words.
                    raw = byte(sampleOffset + s * 2 + 1)
                } else {
                    raw = byte(sampleOffset + s)
                }
                // ffi == 2: unsigned PCM -> signed umklappen. ffi == 1 (alte
                // signed Module) bleibt unverändert.
                let signed = ffi == 2 ? raw ^ 0x80 : raw
                bytes.append(Int8(bitPattern: UInt8(signed & 0xFF)))
            }

            loopEnd = min(loopEnd, length)
            loopStart = min(loopStart, length)
            let repeatLength = max(0, loopEnd - loopStart)
            let isLooped = (flags & 1) != 0 && repeatLength > 2

            instruments.append(Instrument(
                index: i + 1,
                name: instName,
                length: bytes.count,
                finetune: 0,
                volume: volume,
                repeatOffset: loopStart,
                repeatLength: repeatLength,
                bytes: bytes,
                isLooped: isLooped,
                c2spd: c2spd
            ))
        }

        // ---- Patterns (gepackt) ----
        let emptyNote = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        var patterns = [Pattern]()
        for p in 0..<patNum {
            let para = word(patParaOffset + p * 2)
            var grid = (0..<64).map { _ in [Note](repeating: emptyNote, count: channelCount) }

            if para > 0 {
                var pos = para * 16 + 2 // 2 Bytes gepackte Länge überspringen
                var row = 0
                while row < 64 && pos < data.count {
                    let what = byte(pos); pos += 1
                    if what == 0 {
                        row += 1
                        continue
                    }
                    var noteByte = 255
                    var instByte = 0
                    var volByte = -1
                    var cmd = 0
                    var info = 0
                    if what & 32 != 0 {
                        noteByte = byte(pos)
                        instByte = byte(pos + 1)
                        pos += 2
                    }
                    if what & 64 != 0 {
                        volByte = byte(pos)
                        pos += 1
                    }
                    if what & 128 != 0 {
                        cmd = byte(pos)
                        info = byte(pos + 1)
                        pos += 2
                    }

                    let target = channelMap[what & 31]
                    guard target >= 0 else { continue }

                    let key: Int
                    switch noteByte {
                    case 255: key = -1                                  // keine Note
                    case 254: key = Note.keyCut                         // ^^
                    default: key = (noteByte >> 4) * 12 + (noteByte & 0x0F)
                    }

                    let (effectId, effectData) = translateEffect(cmd: cmd, info: info, orderMap: orderMap)

                    grid[row][target] = Note(
                        instrument: instByte,
                        period: 0,
                        effectId: effectId,
                        effectData: effectData,
                        key: key,
                        volume: volByte >= 0 ? min(64, volByte) : -1
                    )
                }
            }

            patterns.append(Pattern(rows: grid.map { Row(notes: $0) }))
        }

        return Mod(
            name: name,
            length: patternTable.count,
            patternTable: patternTable,
            instruments: instruments,
            patterns: patterns,
            channelCount: channelCount,
            format: .s3m,
            initialSpeed: initialSpeed > 0 ? initialSpeed : 6,
            initialTempo: initialTempo >= 32 ? initialTempo : 125,
            initialGlobalVolume: (1...64).contains(globalVolume) ? globalVolume : 64,
            channelPannings: pannings
        )
    }

    // S3M-Buchstaben-Effekt (cmd 1 = A, 2 = B, …) auf interne Effekt-IDs
    // übersetzen. Nicht abbildbare/exotische Effekte werden zu (0, 0) = kein
    // Effekt.
    private static func translateEffect(cmd: Int, info: Int, orderMap: [Int]) -> (Int, Int) {
        switch cmd {
        case 1: // Axx: Set Speed (Ticks/Zeile)
            return (ModuleEffect.setSpeed, info)
        case 2: // Bxx: Position Jump — durch die gefilterte Order-Liste remappen
            let target = info < orderMap.count ? orderMap[info] : 0
            return (0x0B, target)
        case 3: // Cxx: Pattern Break (Zielzeile als BCD, wie MOD Dxx)
            return (0x0D, info)
        case 4: // Dxy: Volume Slide (inkl. Fine-Slides + Memory)
            return (ModuleEffect.volumeSlideS3M, info)
        case 5: // Exx: Portamento Down
            return (ModuleEffect.portaDownS3M, info)
        case 6: // Fxx: Portamento Up
            return (ModuleEffect.portaUpS3M, info)
        case 7: // Gxx: Tone Portamento (DSP skaliert x4 im s3mMode)
            return (0x03, info)
        case 8: // Hxy: Vibrato
            return (0x04, info)
        case 9: // Ixy: Tremor
            return (ModuleEffect.tremor, info)
        case 10: // Jxy: Arpeggio
            return (0x00, info)
        case 11: // Kxy: Vibrato + Volume Slide
            return (0x06, info)
        case 12: // Lxy: Tone Portamento + Volume Slide
            return (0x05, info)
        case 15: // Oxx: Sample Offset
            return (0x09, info)
        case 17: // Qxy: Retrigger alle y Ticks (Volume-Modifier x entfällt)
            let y = info & 0x0F
            return y > 0 ? (0xE9, y) : (0, 0)
        case 18: // Rxy: Tremolo
            return (0x07, info)
        case 19: // Sxy: Extended
            let sub = (info >> 4) & 0x0F
            let x = info & 0x0F
            switch sub {
            case 0x8: return (0xE8, x)  // Panning (16 Stufen)
            case 0xB: return (0xE6, x)  // Pattern Loop
            case 0xC: return (0xEC, x)  // Note Cut auf Tick x
            case 0xD: return (0xED, x)  // Note Delay bis Tick x
            case 0xE: return (0xEE, x)  // Pattern Delay
            default: return (0, 0)
            }
        case 20: // Txx: Set Tempo (BPM); x < 2 wäre Tempo-Slide (unsupported)
            return (ModuleEffect.setTempo, info)
        case 21: // Uxy: Fine Vibrato
            return (ModuleEffect.fineVibrato, info)
        case 22: // Vxx: Global Volume
            return (ModuleEffect.globalVolume, info)
        case 24: // Xxx: Panning 0..0x80; 0xA4 = Surround (als Mitte behandelt)
            if info == 0xA4 { return (0x08, 128) }
            return (0x08, min(255, info * 2))
        default:
            return (0, 0)
        }
    }
}
