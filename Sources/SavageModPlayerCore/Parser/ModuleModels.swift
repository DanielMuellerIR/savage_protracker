import Foundation

// Welches Tracker-Format ein geladenes Modul hat. Steuert im DSP das
// Frequenzmodell (Amiga-Paula-Perioden vs. ScreamTracker-3-Perioden) und
// dient UI/Quick-Look als Anzeigename.
public enum ModuleFormat: String, Sendable, Codable {
    case protracker     // klassisches 4-Kanal-ProTracker-MOD (M.K., FLT4, 4CHN)
    case soundtracker   // Ur-Soundtracker mit nur 15 Instrumenten (ohne Signatur)
    case multichannel   // MOD-Varianten mit 6/8/… Kanälen (6CHN, 8CHN, xxCH, FLT8, CD81, OKTA)
    case s3m            // ScreamTracker 3 (S3M)
    case xm             // FastTracker II Extended Module (XM) — Multi-Sample-Instrumente
    case it             // Impulse Tracker (IT); Parser- und DSP-Anbindung folgen separat

    public var displayName: String {
        switch self {
        case .protracker: return "ProTracker MOD"
        case .soundtracker: return "Soundtracker (15 Samples)"
        case .multichannel: return "Multichannel MOD"
        case .s3m: return "ScreamTracker 3 (S3M)"
        case .xm: return "FastTracker II (XM)"
        case .it: return "Impulse Tracker (IT)"
        }
    }
}

// IT speichert zwei Kompatibilitätsflags im Dateikopf. Sie beeinflussen die
// genaue Effektberechnung und gehören deshalb zu den Wiedergaberegeln des Songs.
public struct ITCompatibility: Sendable, Codable, Equatable {
    public let oldEffects: Bool
    public let compatibleGxx: Bool

    public init(oldEffects: Bool, compatibleGxx: Bool) {
        self.oldEffects = oldEffects
        self.compatibleGxx = compatibleGxx
    }
}

// Beschreibt die Tracker-Regeln unabhängig vom Dateiformat. So kann die Engine
// später gezielt die Semantik auswählen, ohne Formatdetails erneut abzuleiten.
public enum PlaybackSemantics: Sendable, Codable, Equatable {
    case proTracker
    case screamTracker3
    case fastTracker2(linearFrequency: Bool)
    case impulseTracker(ITCompatibility)
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

    // XM-spezifische Effekte (FastTracker II). Werte >= 0x108, damit sie sich
    // weder mit ProTracker-Nibbles noch mit den S3M-IDs oben überschneiden.
    public static let globalVolumeSlide = 0x108 // XM Hxy: globales Volume-Slide (Memory)
    public static let keyOff = 0x109            // XM Kxx: Key-Off nach xx Ticks (Fadeout)
    public static let setEnvelopePos = 0x10A    // XM Lxx: Volume-Envelope-Position setzen
    public static let panSlide = 0x10B          // XM Pxy: Panning-Slide (Memory)
    public static let multiRetrig = 0x10C       // XM Rxy: Retrigger mit Volume-Modus x
    public static let extraFinePortaUp = 0x10D  // XM X1x: Extra-Fine-Porta up (einmalig)
    public static let extraFinePortaDown = 0x10E // XM X2x: Extra-Fine-Porta down (einmalig)
}

// Tracker können statt einer Tonhöhe einen besonderen Notenbefehl speichern.
// Der String-Rohwert macht diese drei Bedeutungen auch in Codable-Daten eindeutig.
public enum SpecialNote: String, Sendable, Codable {
    case off
    case cut
    case fade
}

// Einige Tracker-Instrumente ordnen jeder spielbaren Ausgangsnote eine andere
// Zielnote und ein Sample zu. Dieser Werttyp bildet nur diese neutrale Tabelle
// ab; ein bestimmtes Dateiformat oder Wiedergabeverhalten kennt er noch nicht.
public struct NoteSampleMapping: Sendable, Codable, Equatable {
    public static let entryCount = 120

    // Ein einzelner Tabelleneintrag. Sample 0 bedeutet, dass kein Sample
    // ausgewählt ist; 1...99 sind echte, 1-basierte Sample-Nummern.
    public struct Entry: Sendable, Codable, Equatable {
        public let targetNote: Int
        public let sampleID: Int

        public init(targetNote: Int, sampleID: Int) throws {
            guard (0..<NoteSampleMapping.entryCount).contains(targetNote) else {
                throw ValidationError.invalidTargetNote(targetNote)
            }
            guard (0...99).contains(sampleID) else {
                throw ValidationError.invalidSampleID(sampleID)
            }

            self.targetNote = targetNote
            self.sampleID = sampleID
        }

        private enum CodingKeys: String, CodingKey {
            case targetNote, sampleID
        }

        // Auch Daten von außen müssen dieselben Grenzen wie der öffentliche
        // Initializer einhalten. So kann Codable keine ungültigen Werte bauen.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                targetNote: values.decode(Int.self, forKey: .targetNote),
                sampleID: values.decode(Int.self, forKey: .sampleID)
            )
        }
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidEntryCount(Int)
        case invalidTargetNote(Int)
        case invalidSampleID(Int)
    }

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard entries.count == Self.entryCount else {
            throw ValidationError.invalidEntryCount(entries.count)
        }
        self.entries = entries
    }

    // Eine ungültige Ausgangsnote liefert nil statt einen Array-Zugriff außerhalb
    // der Grenzen auszulösen. Gültige Ausgangsnoten entsprechen dem Tabellenindex.
    public func entry(forSourceNote sourceNote: Int) -> Entry? {
        guard entries.indices.contains(sourceNote) else { return nil }
        return entries[sourceNote]
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    // Der öffentliche Initializer prüft auch beim Laden die feste Tabellenlänge.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entries: values.decode([Entry].self, forKey: .entries))
    }
}

public struct Note: Sendable, Codable {
    public let instrument: Int      // 0..99 (0 = kein Instrument)
    public let period: Int          // 12-Bit-Wert für Amiga-Perioden (MOD); 0 bei S3M
    public let effectId: Int        // Effekt-ID (inkl. Extended 0xE0..0xEF und ModuleEffect.*)
    public let effectData: Int      // Effekt-Datenbyte (0..255)
    // Explizite Präsenz der Effektspalte. nil behält die bisherige Inferenz
    // (effectId/effectData != 0) für alte Aufrufer und alte Codable-Daten bei;
    // true/false kann einen vorhandenen Nullparameter von einer leeren Zelle
    // unterscheiden.
    public let effectPresent: Bool?
    // S3M/XM/IT-Notenschlüssel: Halbton-Index (Oktave*12 + Note, C-0 = 0).
    // -1 bedeutet keine Note; 252...254 sind besondere Notenbefehle.
    public let key: Int
    // S3M-Volume-Column (0..64). -1 = keine Angabe.
    public let volume: Int
    // XM-Volume-Column: rohes Byte 0x00..0xFF (0 = nichts). XM kodiert hier eine
    // zweite Effektspalte (Set Volume, Vol-Slide, Vibrato, Panning, Tone-Porta),
    // die der DSP getrennt vom Haupteffekt auswertet. MOD/S3M lassen es 0.
    public let volCmd: Int

    // Sentinel für S3M-Note-Cut (^^) im `key`-Feld.
    public static let keyCut = 254
    // Sentinel für XM-Key-Off (Note 97) im `key`-Feld: gibt Sustain frei + startet Fadeout.
    public static let keyOff = 253
    // Sentinel für IT-Note-Fade im `key`-Feld: startet das Ausblenden der Stimme.
    public static let keyFade = 252

    // Leitet den besonderen Notenbefehl nur aus `key` ab. Dadurch bleibt das
    // bestehende Speicherformat von Note unverändert und enthält kein Zusatzfeld.
    public var specialNote: SpecialNote? {
        switch key {
        case Self.keyOff: return .off
        case Self.keyCut: return .cut
        case Self.keyFade: return .fade
        default: return nil
        }
    }

    public var hasEffect: Bool {
        return effectPresent ?? (effectId != 0 || effectData != 0)
    }

    public var effectHigh: Int {
        return (effectData >> 4) & 0x0F
    }

    public var effectLow: Int {
        return effectData & 0x0F
    }

    public init(instrument: Int, period: Int, effectId: Int, effectData: Int, key: Int = -1, volume: Int = -1, volCmd: Int = 0, effectPresent: Bool? = nil) {
        self.instrument = instrument
        self.period = period
        self.effectId = effectId
        self.effectData = effectData
        self.effectPresent = effectPresent
        self.key = key
        self.volume = volume
        self.volCmd = volCmd
    }

    private enum CodingKeys: String, CodingKey {
        case instrument, period, effectId, effectData, effectPresent
        case key, volume, volCmd
    }

    // Alte gespeicherte Noten enthalten kein effectPresent-Feld. Mit
    // decodeIfPresent bleiben sie ohne Migration lesbar und nutzen wieder die
    // historische Inferenz in hasEffect.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        instrument = try values.decode(Int.self, forKey: .instrument)
        period = try values.decode(Int.self, forKey: .period)
        effectId = try values.decode(Int.self, forKey: .effectId)
        effectData = try values.decode(Int.self, forKey: .effectData)
        effectPresent = try values.decodeIfPresent(Bool.self, forKey: .effectPresent)
        key = try values.decodeIfPresent(Int.self, forKey: .key) ?? -1
        volume = try values.decodeIfPresent(Int.self, forKey: .volume) ?? -1
        volCmd = try values.decodeIfPresent(Int.self, forKey: .volCmd) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(instrument, forKey: .instrument)
        try values.encode(period, forKey: .period)
        try values.encode(effectId, forKey: .effectId)
        try values.encode(effectData, forKey: .effectData)
        try values.encodeIfPresent(effectPresent, forKey: .effectPresent)
        try values.encode(key, forKey: .key)
        try values.encode(volume, forKey: .volume)
        try values.encode(volCmd, forKey: .volCmd)
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

// Loop-Verhalten eines Samples. XM kennt zusätzlich Ping-Pong (bidirektional);
// MOD/S3M nutzen nur .none / .forward.
public enum LoopType: Int, Sendable, Codable {
    case none = 0
    case forward = 1
    case pingpong = 2
}

// Ein einzelnes PCM-Sample mit Tuning- und Loop-Angaben. Das ist die Einheit,
// die der DSP tatsächlich abspielt. MOD/S3M-Instrumente enthalten genau eins;
// XM-Instrumente bis zu 16, ausgewählt per Keymap (siehe Instrument).
//
// PCM ist auf ~[-0.5, 0.5] normalisiert (8-Bit: int8/256, 16-Bit: int16/65536)
// — dieselbe Amplituden-Skala wie der frühere Int8/256-Pfad, damit die MOD-
// Wiedergabe (und die JS↔Swift-Parität) bitgleich bleibt. Float statt Int8,
// damit XM-16-Bit-Samples verlustfrei bleiben (Entscheidung 2026-07-09).
public struct Sample: Sendable, Codable {
    public let pcm: [Float]         // Normalisierte Sample-Daten (Frames)
    public let loopStart: Int       // Loop-Start in FRAMES
    public let loopLength: Int      // Loop-Länge in FRAMES
    public let loopType: LoopType
    public let volume: Int          // 0..64
    public let finetune: Int        // MOD: -8..7 ; XM: -128..127 ; S3M: 0
    public let relativeNote: Int    // XM: Halbton-Offset auf die gespielte Note; sonst 0
    public let panning: Float       // 0..1 (0.5 = Mitte)
    // S3M: Abspielrate in Hz, bei der C-4 klingt (Standard 8363). MOD/XM nutzen
    // stattdessen finetune + Perioden-/Frequenzmodell.
    public let c2spd: Int
    public let name: String

    // Loopt genau dann, wenn ein echter (Vorwärts-/Ping-Pong-)Loop mit > 2 Frames
    // gesetzt ist — dieselbe Schwelle wie zuvor (repeatLength > 2), die Ein-Frame-
    // Sentinel-Loops als One-Shot behandelt.
    public var isLooped: Bool { loopType != .none && loopLength > 2 }

    public init(pcm: [Float], loopStart: Int, loopLength: Int, loopType: LoopType,
                volume: Int, finetune: Int, relativeNote: Int = 0, panning: Float = 0.5,
                c2spd: Int = 8363, name: String = "") {
        self.pcm = pcm
        self.loopStart = loopStart
        self.loopLength = loopLength
        self.loopType = loopType
        self.volume = volume
        self.finetune = finetune
        self.relativeNote = relativeNote
        self.panning = panning
        self.c2spd = c2spd
        self.name = name
    }
}

// Ein Hüllkurven-Punkt (Volume oder Panning): x = Tick-Position ab Note-Start,
// y = Wert 0..64. Kein Tupel, damit Codable-Konformanz erhalten bleibt.
public struct EnvelopePoint: Sendable, Codable {
    public let frame: Int   // x: Tick-Position
    public let value: Int   // y: 0..64
    public init(frame: Int, value: Int) { self.frame = frame; self.value = value }
}

// XM-Hüllkurve (Volume oder Panning): stückweise lineare Interpolation zwischen
// den Punkten, optional mit Sustain-Punkt (hält bis Key-Off) und Loop.
public struct Envelope: Sendable, Codable {
    public let points: [EnvelopePoint]
    public let sustainPoint: Int
    public let loopStart: Int       // Punkt-Index
    public let loopEnd: Int         // Punkt-Index
    public let sustainEnabled: Bool
    public let loopEnabled: Bool

    public init(points: [EnvelopePoint], sustainPoint: Int, loopStart: Int, loopEnd: Int, sustainEnabled: Bool, loopEnabled: Bool) {
        self.points = points
        self.sustainPoint = sustainPoint
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.sustainEnabled = sustainEnabled
        self.loopEnabled = loopEnabled
    }
}

// XM-Auto-Vibrato (instrument-eigenes Vibrato, unabhängig vom Effekt 4xy):
// moduliert die Periode ab Note-Start mit optionaler Sweep-Anlauframpe.
public struct AutoVibrato: Sendable, Codable {
    public let type: Int    // 0 = Sine, 1 = Square, 2 = Ramp, 3 = Ramp (invertiert)
    public let sweep: Int   // Anlauf in Ticks bis zur vollen Tiefe
    public let depth: Int   // 0..15
    public let rate: Int    // 0..63 (Geschwindigkeit)
    public init(type: Int, sweep: Int, depth: Int, rate: Int) {
        self.type = type; self.sweep = sweep; self.depth = depth; self.rate = rate
    }
}

public struct Instrument: Sendable, Codable {
    public let index: Int
    public let name: String
    // Ein oder mehrere Samples. MOD/S3M: genau eins (oder leer als Platzhalter),
    // XM: bis zu 16, per keymap der gespielten Note zugeordnet.
    public let samples: [Sample]
    // 96 Einträge (Noten C-0..B-7) -> Sample-Index. Leer => immer Sample 0
    // (MOD/S3M). Nur XM füllt die Keymap.
    public let keymap: [UInt8]
    public let volumeEnvelope: Envelope?
    public let panningEnvelope: Envelope?
    public let fadeout: Int             // XM: 0..0x8000, pro Tick ab Key-Off; sonst 0
    public let autoVibrato: AutoVibrato?

    public init(index: Int, name: String, samples: [Sample], keymap: [UInt8] = [],
                volumeEnvelope: Envelope? = nil, panningEnvelope: Envelope? = nil,
                fadeout: Int = 0, autoVibrato: AutoVibrato? = nil) {
        self.index = index
        self.name = name
        self.samples = samples
        self.keymap = keymap
        self.volumeEnvelope = volumeEnvelope
        self.panningEnvelope = panningEnvelope
        self.fadeout = fadeout
        self.autoVibrato = autoVibrato
    }

    // Bequemer Konstruktor für Ein-Sample-Formate (MOD/S3M): baut intern genau
    // ein Sample aus Int8-Daten. Hält die parität-kritischen MOD/S3M-Parser und
    // -Tests nah an der alten API. `length` wird nicht mehr separat gespeichert —
    // die Sample-Länge ergibt sich aus pcm.count (deckungsgleich mit bytes.count).
    public init(index: Int, name: String, length: Int, finetune: Int, volume: Int,
                repeatOffset: Int, repeatLength: Int, bytes: [Int8], isLooped: Bool, c2spd: Int = 8363) {
        // Int8 -> normalisierter Float (identische Amplitude wie der alte /256-Pfad).
        let pcm = bytes.map { Float($0) / 256.0 }
        let sample = Sample(
            pcm: pcm,
            loopStart: repeatOffset,
            loopLength: repeatLength,
            loopType: isLooped ? .forward : .none,
            volume: volume,
            finetune: finetune,
            relativeNote: 0,
            panning: 0.5,
            c2spd: c2spd,
            name: name
        )
        self.init(index: index, name: name, samples: [sample])
    }

    // Erstes/primäres Sample (MOD/S3M haben genau eins). nil bei Platzhalter-
    // Instrumenten (z.B. leere/AdLib-S3M-Slots).
    public var primarySample: Sample? { samples.first }

    // Passendes Sample für eine 0-basierte Note (0..95) über die Keymap wählen.
    // Ohne Keymap (MOD/S3M) immer das erste Sample.
    public func sample(forNote note: Int) -> Sample? {
        guard !samples.isEmpty else { return nil }
        guard !keymap.isEmpty else { return samples[0] }
        let n = min(95, max(0, note))
        let idx = Int(keymap[n])
        return idx < samples.count ? samples[idx] : samples[0]
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
    // XM: true = lineare Frequenztabelle, false = Amiga-Periodentabelle. Andere
    // Formate lassen es false (sie nutzen ihr eigenes Perioden-/Clock-Modell).
    public let linearFrequency: Bool

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
        channelPannings: [Float] = [],
        linearFrequency: Bool = false
    ) {
        self.linearFrequency = linearFrequency
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
