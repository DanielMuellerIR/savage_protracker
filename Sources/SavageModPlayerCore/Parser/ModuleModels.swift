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

    // IT-Buchstabenbefehle bleiben bis zur IT-DSP-Anbindung verlustfrei in
    // einem eigenen Bereich. command 1 = A, 2 = B, ... 26 = Z.
    public static let impulseTrackerCommandBase = 0x200

    public static func impulseTrackerCommand(_ command: Int) -> Int {
        impulseTrackerCommandBase + command
    }
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

// Zweiter, von der normalen Sample-Schleife unabhängiger Loop. IT hält diesen
// Sustain-Loop bis Note Off und wechselt danach zum normalen Loop oder Auslauf.
public struct SampleLoop: Sendable, Codable, Equatable {
    public let start: Int
    public let length: Int
    public let type: LoopType

    public init(start: Int, length: Int, type: LoopType) {
        self.start = start
        self.length = length
        self.type = type
    }
}

public enum ITSampleVibratoWaveform: Int, Sendable, Codable {
    case sine = 0
    case rampDown = 1
    case square = 2
    case random = 3
}

// Sample-eigenes IT-Vibrato. Anders als XM-Auto-Vibrato liegt es im Sample-
// Header. Speed liegt in 0...64, Depth in 0...127 und die Sweep-Rate in
// 0...255; IT nennt das erste Feld historisch „Speed“ und das letzte „Rate“.
public struct ITSampleVibrato: Sendable, Codable, Equatable {
    public let speed: Int
    public let depth: Int
    public let rate: Int
    public let waveform: ITSampleVibratoWaveform

    public init(speed: Int, depth: Int, rate: Int, waveform: ITSampleVibratoWaveform) {
        self.speed = speed
        self.depth = depth
        self.rate = rate
        self.waveform = waveform
    }
}

// IT-spezifische Sample-Metadaten. Stereo-PCM und Sustain-Loop bleiben direkt
// am neutralen Sample, weil auch andere Formate diese Fähigkeiten nutzen können.
public struct ITSampleProperties: Sendable, Codable, Equatable {
    public let c5Speed: Int
    public let globalVolume: Int
    public let defaultPanning: Int? // nil = Headerflag „kein Default-Pan“
    public let vibrato: ITSampleVibrato?

    public init(c5Speed: Int, globalVolume: Int, defaultPanning: Int?, vibrato: ITSampleVibrato? = nil) {
        self.c5Speed = c5Speed
        self.globalVolume = globalVolume
        self.defaultPanning = defaultPanning
        self.vibrato = vibrato
    }
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
    // IT-Stereo speichert den linken Kanal weiterhin in pcm und den rechten
    // verlustfrei separat. nil bedeutet Mono.
    public let rightPCM: [Float]?
    public let sustainLoop: SampleLoop?
    public let itProperties: ITSampleProperties?

    // Loopt genau dann, wenn ein echter (Vorwärts-/Ping-Pong-)Loop mit > 2 Frames
    // gesetzt ist — dieselbe Schwelle wie zuvor (repeatLength > 2), die Ein-Frame-
    // Sentinel-Loops als One-Shot behandelt.
    public var isLooped: Bool { loopType != .none && loopLength > 2 }

    public init(pcm: [Float], loopStart: Int, loopLength: Int, loopType: LoopType,
                volume: Int, finetune: Int, relativeNote: Int = 0, panning: Float = 0.5,
                c2spd: Int = 8363, name: String = "", rightPCM: [Float]? = nil,
                sustainLoop: SampleLoop? = nil, itProperties: ITSampleProperties? = nil) {
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
        self.rightPCM = rightPCM
        self.sustainLoop = sustainLoop
        self.itProperties = itProperties
    }
}

// Ein Hüllkurven-Punkt (Volume oder Panning): x = Tick-Position ab Note-Start,
// y = Wert 0..64. Kein Tupel, damit Codable-Konformanz erhalten bleibt.
public struct EnvelopePoint: Sendable, Codable, Equatable {
    public let frame: Int   // x: Tick-Position
    public let value: Int   // y: 0..64
    public init(frame: Int, value: Int) { self.frame = frame; self.value = value }
}

// Legt fest, ob eine Hüllkurve einen normalen Pegel-/Panwert, die Tonhöhe oder
// den Filter steuert. IT verwendet dasselbe dritte Envelope je nach Headerflag
// entweder für Pitch oder Filter; XM bleibt im neutralen Standardmodus.
public enum EnvelopeValueMode: String, Sendable, Codable {
    case standard
    case pitch
    case filter
}

// Formatneutrale Tracker-Hüllkurve mit linear interpolierten Punkten. XM nutzt
// einen einzelnen Sustain-Punkt; IT kann dagegen einen Sustain-Bereich sowie
// Carry und einen Pitch-/Filtermodus speichern.
public struct Envelope: Sendable, Codable, Equatable {
    public let points: [EnvelopePoint]
    public let sustainStart: Int    // Punkt-Index
    public let sustainEnd: Int      // Punkt-Index
    public let loopStart: Int       // Punkt-Index
    public let loopEnd: Int         // Punkt-Index
    public let sustainEnabled: Bool
    public let loopEnabled: Bool
    public let carryEnabled: Bool
    public let valueMode: EnvelopeValueMode

    // Kompatibler XM-Zugriff: Einpunkt-Sustain und IT-Sustain-Bereich beginnen
    // beide an diesem Index. Bestehender DSP- und CLI-Code bleibt damit stabil.
    public var sustainPoint: Int { sustainStart }

    public init(points: [EnvelopePoint], sustainPoint: Int, loopStart: Int, loopEnd: Int, sustainEnabled: Bool, loopEnabled: Bool) {
        self.init(
            points: points,
            sustainStart: sustainPoint,
            sustainEnd: sustainPoint,
            loopStart: loopStart,
            loopEnd: loopEnd,
            sustainEnabled: sustainEnabled,
            loopEnabled: loopEnabled
        )
    }

    public init(
        points: [EnvelopePoint],
        sustainStart: Int,
        sustainEnd: Int,
        loopStart: Int,
        loopEnd: Int,
        sustainEnabled: Bool,
        loopEnabled: Bool,
        carryEnabled: Bool = false,
        valueMode: EnvelopeValueMode = .standard
    ) {
        self.points = points
        self.sustainStart = sustainStart
        self.sustainEnd = sustainEnd
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.sustainEnabled = sustainEnabled
        self.loopEnabled = loopEnabled
        self.carryEnabled = carryEnabled
        self.valueMode = valueMode
    }

    private enum CodingKeys: String, CodingKey {
        case points
        case sustainPoint   // Legacy-Schlüssel bis Version 1.5.13
        case sustainStart, sustainEnd
        case loopStart, loopEnd
        case sustainEnabled, loopEnabled
        case carryEnabled, valueMode
    }

    // Alte Codable-Daten enthalten nur sustainPoint und keine IT-Felder. Der
    // Decoder bildet sie exakt auf einen Einpunkt-Sustain ohne Carry ab.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacySustainPoint = try values.decodeIfPresent(Int.self, forKey: .sustainPoint) ?? 0
        let sustainStart = try values.decodeIfPresent(Int.self, forKey: .sustainStart)
            ?? legacySustainPoint
        let sustainEnd = try values.decodeIfPresent(Int.self, forKey: .sustainEnd)
            ?? sustainStart

        self.init(
            points: try values.decode([EnvelopePoint].self, forKey: .points),
            sustainStart: sustainStart,
            sustainEnd: sustainEnd,
            loopStart: try values.decode(Int.self, forKey: .loopStart),
            loopEnd: try values.decode(Int.self, forKey: .loopEnd),
            sustainEnabled: try values.decode(Bool.self, forKey: .sustainEnabled),
            loopEnabled: try values.decode(Bool.self, forKey: .loopEnabled),
            carryEnabled: try values.decodeIfPresent(Bool.self, forKey: .carryEnabled) ?? false,
            valueMode: try values.decodeIfPresent(EnvelopeValueMode.self, forKey: .valueMode)
                ?? .standard
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(points, forKey: .points)
        // Der Legacy-Schlüssel hält neue Daten für ältere Savage-Versionen lesbar.
        try values.encode(sustainStart, forKey: .sustainPoint)
        try values.encode(sustainStart, forKey: .sustainStart)
        try values.encode(sustainEnd, forKey: .sustainEnd)
        try values.encode(loopStart, forKey: .loopStart)
        try values.encode(loopEnd, forKey: .loopEnd)
        try values.encode(sustainEnabled, forKey: .sustainEnabled)
        try values.encode(loopEnabled, forKey: .loopEnabled)
        try values.encode(carryEnabled, forKey: .carryEnabled)
        try values.encode(valueMode, forKey: .valueMode)
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

public enum NewNoteAction: Int, Sendable, Codable {
    case cut = 0
    case continuePlaying = 1
    case noteOff = 2
    case noteFade = 3
}

public enum DuplicateCheckType: Int, Sendable, Codable {
    case off = 0
    case note = 1
    case sample = 2
    case instrument = 3
}

public enum DuplicateCheckAction: Int, Sendable, Codable {
    case cut = 0
    case noteOff = 1
    case noteFade = 2
}

// IT-Instrumentparameter, die NNA/Duplicate-Handling und die Startparameter
// einer Stimme bestimmen. Rohe Header-Flags werden schon im Parser in optionale
// Werte übersetzt; nil bedeutet bei Pan oder Filter ausdrücklich „nicht nutzen“.
public struct ITInstrumentProperties: Sendable, Codable, Equatable {
    public let newNoteAction: NewNoteAction
    public let duplicateCheckType: DuplicateCheckType
    public let duplicateCheckAction: DuplicateCheckAction
    public let globalVolume: Int
    public let defaultPanning: Int?
    public let pitchPanSeparation: Int
    public let pitchPanCenter: Int
    public let randomVolumeVariation: Int
    public let randomPanningVariation: Int
    public let initialFilterCutoff: Int?
    public let initialFilterResonance: Int?
    // Native IT-MIDI-Routingfelder. Der Core bewahrt sie zur sichtbaren
    // Kompatibilitätsmeldung, erzeugt aber bewusst keine externe MIDI-Ausgabe.
    public let midiChannel: Int
    public let midiProgram: Int
    public let midiBank: Int

    public init(
        newNoteAction: NewNoteAction,
        duplicateCheckType: DuplicateCheckType,
        duplicateCheckAction: DuplicateCheckAction,
        globalVolume: Int,
        defaultPanning: Int?,
        pitchPanSeparation: Int,
        pitchPanCenter: Int,
        randomVolumeVariation: Int,
        randomPanningVariation: Int,
        initialFilterCutoff: Int?,
        initialFilterResonance: Int?,
        midiChannel: Int = 0,
        midiProgram: Int = 0,
        midiBank: Int = 0
    ) {
        self.newNoteAction = newNoteAction
        self.duplicateCheckType = duplicateCheckType
        self.duplicateCheckAction = duplicateCheckAction
        self.globalVolume = globalVolume
        self.defaultPanning = defaultPanning
        self.pitchPanSeparation = pitchPanSeparation
        self.pitchPanCenter = pitchPanCenter
        self.randomVolumeVariation = randomVolumeVariation
        self.randomPanningVariation = randomPanningVariation
        self.initialFilterCutoff = initialFilterCutoff
        self.initialFilterResonance = initialFilterResonance
        self.midiChannel = midiChannel
        self.midiProgram = midiProgram
        self.midiBank = midiBank
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
    public let pitchEnvelope: Envelope?
    public let fadeout: Int             // XM: 0..0x8000, pro Tick ab Key-Off; sonst 0
    public let autoVibrato: AutoVibrato?
    public let noteSampleMapping: NoteSampleMapping?
    public let itProperties: ITInstrumentProperties?

    public init(index: Int, name: String, samples: [Sample], keymap: [UInt8] = [],
                volumeEnvelope: Envelope? = nil, panningEnvelope: Envelope? = nil,
                fadeout: Int = 0, autoVibrato: AutoVibrato? = nil,
                pitchEnvelope: Envelope? = nil, noteSampleMapping: NoteSampleMapping? = nil,
                itProperties: ITInstrumentProperties? = nil) {
        self.index = index
        self.name = name
        self.samples = samples
        self.keymap = keymap
        self.volumeEnvelope = volumeEnvelope
        self.panningEnvelope = panningEnvelope
        self.pitchEnvelope = pitchEnvelope
        self.fadeout = fadeout
        self.autoVibrato = autoVibrato
        self.noteSampleMapping = noteSampleMapping
        self.itProperties = itProperties
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

public enum GlobalVolumeScale: Int, Sendable, Codable {
    case tracker64 = 64
    case impulseTracker128 = 128
}

// Header-Metadaten, die nur IT besitzt und für Parser-, Effekt- und spätere
// Kompatibilitätsentscheidungen verlustfrei erhalten bleiben müssen.
public struct ITModuleProperties: Sendable, Codable, Equatable {
    public let createdWithVersion: Int
    public let compatibleWithVersion: Int
    public let usesInstruments: Bool
    public let stereo: Bool
    public let volumeZeroMixOptimization: Bool
    public let linearSlides: Bool
    public let patternHighlight: Int
    public let mixVolume: Int
    public let panSeparation: Int
    public let pitchWheelDepth: Int
    public let hasSongMessage: Bool
    public let songMessageLength: Int
    public let songMessageOffset: Int
    public let usesMIDIPitchController: Bool
    public let hasEmbeddedMIDIConfiguration: Bool
    public let unknownHeaderFlags: Int
    public let unknownSpecialFlags: Int
    public let hasUnsupportedExtensions: Bool

    public init(
        createdWithVersion: Int,
        compatibleWithVersion: Int,
        usesInstruments: Bool,
        stereo: Bool,
        volumeZeroMixOptimization: Bool,
        linearSlides: Bool,
        patternHighlight: Int,
        mixVolume: Int,
        panSeparation: Int,
        pitchWheelDepth: Int,
        hasSongMessage: Bool,
        songMessageLength: Int,
        songMessageOffset: Int,
        usesMIDIPitchController: Bool,
        hasEmbeddedMIDIConfiguration: Bool,
        unknownHeaderFlags: Int,
        unknownSpecialFlags: Int,
        hasUnsupportedExtensions: Bool = false
    ) {
        self.createdWithVersion = createdWithVersion
        self.compatibleWithVersion = compatibleWithVersion
        self.usesInstruments = usesInstruments
        self.stereo = stereo
        self.volumeZeroMixOptimization = volumeZeroMixOptimization
        self.linearSlides = linearSlides
        self.patternHighlight = patternHighlight
        self.mixVolume = mixVolume
        self.panSeparation = panSeparation
        self.pitchWheelDepth = pitchWheelDepth
        self.hasSongMessage = hasSongMessage
        self.songMessageLength = songMessageLength
        self.songMessageOffset = songMessageOffset
        self.usesMIDIPitchController = usesMIDIPitchController
        self.hasEmbeddedMIDIConfiguration = hasEmbeddedMIDIConfiguration
        self.unknownHeaderFlags = unknownHeaderFlags
        self.unknownSpecialFlags = unknownSpecialFlags
        self.hasUnsupportedExtensions = hasUnsupportedExtensions
    }
}

public struct Mod: Sendable, Codable {
    public let name: String
    public let length: Int          // Anzahl der Songpositionen in der Playlist
    public let patternTable: [Int]  // Playlist (Indizes der Patterns)
    public let instruments: [Instrument?] // 1-basiertes Array (Index 0 ist nil)
    // IT besitzt einen globalen, instrumentübergreifenden Sample-Pool. Andere
    // Formate belassen ihn beim kompatiblen Eintrag [nil].
    public let samplePool: [Sample?]
    public let patterns: [Pattern]
    public let channelCount: Int    // Kanäle pro Row (MOD klassisch 4, S3M bis 32)
    public let format: ModuleFormat
    public let initialSpeed: Int    // Ticks pro Zeile beim Start (MOD: 6)
    public let initialTempo: Int    // BPM beim Start (MOD: 125)
    // Globale Start-Lautstärke 0..64 (S3M-Header; MOD hat das Konzept nicht -> 64).
    public let initialGlobalVolume: Int
    // Start-Panning pro Kanal (0 = links, 1 = rechts). Immer channelCount Einträge.
    public let channelPannings: [Float]
    // Kanal-Startlautstärken 0...64. Immer channelCount Einträge.
    public let channelVolumes: [Int]
    // IT kann einen Kanal als Surround markieren oder seine Notenausgabe
    // deaktivieren, während Effekte weiterlaufen. Andere Formate nutzen false.
    public let channelSurrounds: [Bool]
    public let channelDisabled: [Bool]
    // XM: true = lineare Frequenztabelle, false = Amiga-Periodentabelle. Andere
    // Formate lassen es false (sie nutzen ihr eigenes Perioden-/Clock-Modell).
    public let linearFrequency: Bool
    // IT benötigt Headerflags im Profil und muss es deshalb explizit setzen.
    // Bestehende Formate werden aus ihren unveränderten Feldern abgeleitet.
    public let playbackSemantics: PlaybackSemantics?
    public let itProperties: ITModuleProperties?

    public var globalVolumeScale: GlobalVolumeScale {
        format == .it ? .impulseTracker128 : .tracker64
    }

    // Die Dateiformate reservieren unterschiedlich viele logische Kanäle. Gerade
    // IT hält immer 64 Header-Kanäle vor, obwohl ein konkreter Song oft nur einen
    // Teil davon mit Noten, Instrumenten oder Effekten belegt. Die UI verwendet
    // diesen Wert deshalb als verständliche Anzeige, ohne den DSP-Kanalumfang zu
    // verändern.
    public var usedChannelCount: Int {
        // Leere oder ausschließlich aus leeren Patterns bestehende Dateien sollen
        // nicht mit "0 Kanäle" erscheinen. Dann ist die deklarierte Kanalzahl die
        // einzig sinnvolle Information.
        let used = usedChannelIndices
        return used.isEmpty ? channelCount : used.count
    }

    // Tatsaechlich im Song belegte Kanalindizes. IT kann zwischen benutzten
    // Kanaelen reservierte Luecken enthalten; die UI blendet diese aus, behaelt
    // aber die Originalindizes fuer Beschriftung, Mute/Solo und Scope-Daten.
    public var usedChannelIndices: [Int] {
        var usedChannels = Set<Int>()

        for patternIndex in patternTable where patterns.indices.contains(patternIndex) {
            for row in patterns[patternIndex].rows {
                for (channel, note) in row.notes.enumerated() where noteUsesChannel(note) {
                    usedChannels.insert(channel)
                }
            }
        }

        return usedChannels.sorted()
    }

    public var displayChannelIndices: [Int] {
        let used = usedChannelIndices
        return used.isEmpty ? Array(0..<max(1, channelCount)) : used
    }

    public var displayChannelCount: Int {
        displayChannelIndices.count
    }

    // Liefert fuer die Instrumentvorschau ein wirklich spielbares Sample samt
    // Zielnote. IT-Instrumente halten ihre Samples im globalen Sample-Pool und
    // nicht in Instrument.samples; der alte Vorschaupfad blieb dort daher stumm.
    // Wenn C-5 nicht belegt ist, wird der erste gueltige Mapping-Eintrag genutzt.
    public func previewSelection(instrumentIndex: Int) -> (sample: Sample, targetNote: Int)? {
        guard instruments.indices.contains(instrumentIndex),
              let instrument = instruments[instrumentIndex] else { return nil }

        if format == .it, let mapping = instrument.noteSampleMapping {
            let preferredSourceNote = 60
            let candidates = [preferredSourceNote] + mapping.entries.indices.filter { $0 != preferredSourceNote }
            for sourceNote in candidates {
                let entry = mapping.entries[sourceNote]
                guard entry.sampleID > 0, samplePool.indices.contains(entry.sampleID),
                      let sample = samplePool[entry.sampleID], !sample.pcm.isEmpty else { continue }
                return (sample, entry.targetNote)
            }
            return nil
        }

        let sourceNote = format == .it ? 60 : 48
        guard let sample = instrument.sample(forNote: sourceNote), !sample.pcm.isEmpty else { return nil }
        return (sample, sourceNote)
    }

    public var playableInstrumentIndices: [Int] {
        instruments.indices.dropFirst().filter { previewSelection(instrumentIndex: $0) != nil }
    }

    private func noteUsesChannel(_ note: Note) -> Bool {
        note.instrument != 0
            || note.period != 0
            || note.key != -1
            || note.volume != -1
            || note.volCmd != 0
            || note.hasEffect
    }

    // Sichtbare, nicht-fatale Einschränkungen. Der Parser behält das spielbare
    // PCM/Pattern-Material, verschweigt aber externe MIDI-/Pluginpfade und
    // unbekannte OpenMPT-Erweiterungen nicht.
    public var compatibilityWarnings: [String] {
        guard format == .it, let properties = itProperties else { return [] }
        var warnings = [String]()
        if properties.compatibleWithVersion > 0x0215
            || properties.createdWithVersion > 0x0215 {
            warnings.append(
                "Die Datei stammt aus einer neueren IT-/Tracker-Version; Erweiterungen können eingeschränkt sein."
            )
        }
        if properties.usesMIDIPitchController {
            warnings.append("Externe MIDI-Pitchsteuerung wird nicht wiedergegeben.")
        }
        if properties.hasEmbeddedMIDIConfiguration {
            warnings.append(
                "Eingebettete MIDI-Makros sind auf die gebräuchlichen IT-Filtermakros beschränkt."
            )
        }
        if instruments.compactMap({ $0?.itProperties }).contains(where: { $0.midiChannel > 0 }) {
            warnings.append("MIDI-/Plugin-Instrumente werden nicht ausgegeben; PCM-Instrumente bleiben hörbar.")
        }
        if properties.hasUnsupportedExtensions
            || properties.unknownHeaderFlags != 0
            || properties.unknownSpecialFlags != 0 {
            warnings.append("Unbekannte MPTM-/IT-Erweiterungen wurden erkannt und werden ignoriert.")
        }
        return warnings
    }

    public init(
        name: String,
        length: Int,
        patternTable: [Int],
        instruments: [Instrument?],
        samplePool: [Sample?] = [nil],
        patterns: [Pattern],
        channelCount: Int = 4,
        format: ModuleFormat = .protracker,
        initialSpeed: Int = 6,
        initialTempo: Int = 125,
        initialGlobalVolume: Int = 64,
        channelPannings: [Float] = [],
        linearFrequency: Bool = false,
        channelVolumes: [Int] = [],
        channelSurrounds: [Bool] = [],
        channelDisabled: [Bool] = [],
        playbackSemantics: PlaybackSemantics? = nil,
        itProperties: ITModuleProperties? = nil
    ) {
        self.linearFrequency = linearFrequency
        self.name = name
        self.length = length
        self.patternTable = patternTable
        self.instruments = instruments
        self.samplePool = samplePool
        self.patterns = patterns
        self.channelCount = channelCount
        self.format = format
        self.initialSpeed = initialSpeed
        self.initialTempo = initialTempo
        self.initialGlobalVolume = initialGlobalVolume
        self.channelPannings = channelPannings.count == channelCount
            ? channelPannings
            : Mod.defaultAmigaPannings(channelCount: channelCount)
        self.channelVolumes = channelVolumes.count == channelCount
            ? channelVolumes
            : Array(repeating: 64, count: max(0, channelCount))
        self.channelSurrounds = channelSurrounds.count == channelCount
            ? channelSurrounds
            : Array(repeating: false, count: max(0, channelCount))
        self.channelDisabled = channelDisabled.count == channelCount
            ? channelDisabled
            : Array(repeating: false, count: max(0, channelCount))
        self.playbackSemantics = playbackSemantics ?? Self.inferredSemantics(
            format: format,
            linearFrequency: linearFrequency
        )
        self.itProperties = itProperties
    }

    private static func inferredSemantics(
        format: ModuleFormat,
        linearFrequency: Bool
    ) -> PlaybackSemantics? {
        switch format {
        case .protracker, .soundtracker, .multichannel:
            return .proTracker
        case .s3m:
            return .screamTracker3
        case .xm:
            return .fastTracker2(linearFrequency: linearFrequency)
        case .it:
            // Old Effects und Compatible Gxx dürfen nie geraten werden.
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, length, patternTable, instruments, samplePool, patterns, channelCount
        case format, initialSpeed, initialTempo, initialGlobalVolume
        case channelPannings, channelVolumes, channelSurrounds, channelDisabled
        case linearFrequency, playbackSemantics, itProperties
    }

    // Alte gespeicherte Module besitzen weder Kanal-Volumes noch ein explizites
    // Wiedergabeprofil. Der normale Initializer stellt dafür dieselben Defaults
    // wie die bisherigen Parser her.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: values.decode(String.self, forKey: .name),
            length: values.decode(Int.self, forKey: .length),
            patternTable: values.decode([Int].self, forKey: .patternTable),
            instruments: values.decode([Instrument?].self, forKey: .instruments),
            samplePool: values.decodeIfPresent([Sample?].self, forKey: .samplePool) ?? [nil],
            patterns: values.decode([Pattern].self, forKey: .patterns),
            channelCount: values.decodeIfPresent(Int.self, forKey: .channelCount) ?? 4,
            format: values.decodeIfPresent(ModuleFormat.self, forKey: .format) ?? .protracker,
            initialSpeed: values.decodeIfPresent(Int.self, forKey: .initialSpeed) ?? 6,
            initialTempo: values.decodeIfPresent(Int.self, forKey: .initialTempo) ?? 125,
            initialGlobalVolume: values.decodeIfPresent(Int.self, forKey: .initialGlobalVolume) ?? 64,
            channelPannings: values.decodeIfPresent([Float].self, forKey: .channelPannings) ?? [],
            linearFrequency: values.decodeIfPresent(Bool.self, forKey: .linearFrequency) ?? false,
            channelVolumes: values.decodeIfPresent([Int].self, forKey: .channelVolumes) ?? [],
            channelSurrounds: values.decodeIfPresent([Bool].self, forKey: .channelSurrounds) ?? [],
            channelDisabled: values.decodeIfPresent([Bool].self, forKey: .channelDisabled) ?? [],
            playbackSemantics: values.decodeIfPresent(PlaybackSemantics.self, forKey: .playbackSemantics),
            itProperties: values.decodeIfPresent(ITModuleProperties.self, forKey: .itProperties)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(length, forKey: .length)
        try values.encode(patternTable, forKey: .patternTable)
        try values.encode(instruments, forKey: .instruments)
        try values.encode(samplePool, forKey: .samplePool)
        try values.encode(patterns, forKey: .patterns)
        try values.encode(channelCount, forKey: .channelCount)
        try values.encode(format, forKey: .format)
        try values.encode(initialSpeed, forKey: .initialSpeed)
        try values.encode(initialTempo, forKey: .initialTempo)
        try values.encode(initialGlobalVolume, forKey: .initialGlobalVolume)
        try values.encode(channelPannings, forKey: .channelPannings)
        try values.encode(channelVolumes, forKey: .channelVolumes)
        try values.encode(channelSurrounds, forKey: .channelSurrounds)
        try values.encode(channelDisabled, forKey: .channelDisabled)
        try values.encode(linearFrequency, forKey: .linearFrequency)
        try values.encodeIfPresent(playbackSemantics, forKey: .playbackSemantics)
        try values.encodeIfPresent(itProperties, forKey: .itProperties)
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
