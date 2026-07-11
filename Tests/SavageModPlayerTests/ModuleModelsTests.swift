import XCTest
@testable import SavageModPlayerCore

/// Sichert die reinen Datenmodelle für Tracker-Format und Wiedergaberegeln ab.
/// Parser, Loader und DSP werden in diesem Meilenstein bewusst noch nicht verdrahtet.
final class ModuleModelsTests: XCTestCase {

    func testModuleFormatRawValuesAndDisplayNames() {
        let expected: [(ModuleFormat, String, String)] = [
            (.protracker, "protracker", "ProTracker MOD"),
            (.soundtracker, "soundtracker", "Soundtracker (15 Samples)"),
            (.multichannel, "multichannel", "Multichannel MOD"),
            (.s3m, "s3m", "ScreamTracker 3 (S3M)"),
            (.xm, "xm", "FastTracker II (XM)"),
            (.it, "it", "Impulse Tracker (IT)"),
        ]

        for (format, rawValue, displayName) in expected {
            XCTAssertEqual(format.rawValue, rawValue)
            XCTAssertEqual(format.displayName, displayName)
        }
    }

    func testPlaybackSemanticFamiliesAreDistinct() {
        let semantics: [PlaybackSemantics] = [
            .proTracker,
            .screamTracker3,
            .fastTracker2(linearFrequency: true),
            .impulseTracker(ITCompatibility(oldEffects: false, compatibleGxx: false)),
        ]

        for firstIndex in semantics.indices {
            for secondIndex in semantics.indices where firstIndex != secondIndex {
                XCTAssertNotEqual(semantics[firstIndex], semantics[secondIndex])
            }
        }
    }

    func testFastTracker2FrequencyModesSurviveCodableRoundTrip() throws {
        try assertCodableRoundTrip(.fastTracker2(linearFrequency: false))
        try assertCodableRoundTrip(.fastTracker2(linearFrequency: true))
    }

    func testAllITCompatibilityFlagCombinationsSurviveCodableRoundTrip() throws {
        for oldEffects in [false, true] {
            for compatibleGxx in [false, true] {
                let compatibility = ITCompatibility(
                    oldEffects: oldEffects,
                    compatibleGxx: compatibleGxx
                )
                try assertCodableRoundTrip(.impulseTracker(compatibility))
            }
        }
    }

    func testLoaderExtensionsIncludeAllPublicNativeFormats() {
        XCTAssertEqual(ModuleLoader.supportedExtensions, Set(["mod", "s3m", "xm", "it"]))
    }

    func testSpecialNoteSentinelsAreDistinctAndOutsideRegularKeys() {
        XCTAssertEqual(Note.keyFade, 252)
        XCTAssertEqual(Note.keyOff, 253)
        XCTAssertEqual(Note.keyCut, 254)

        let sentinels = [Note.keyFade, Note.keyOff, Note.keyCut]

        XCTAssertEqual(Set(sentinels).count, sentinels.count)
        for sentinel in sentinels {
            XCTAssertFalse((0...119).contains(sentinel))
            XCTAssertNotEqual(sentinel, -1)
        }
    }

    func testSpecialNoteMappingIsExact() {
        XCTAssertEqual(makeNote(key: Note.keyOff).specialNote, .off)
        XCTAssertEqual(makeNote(key: Note.keyCut).specialNote, .cut)
        XCTAssertEqual(makeNote(key: Note.keyFade).specialNote, .fade)

        for regularKey in [-1, 0, 95, 119] {
            XCTAssertNil(makeNote(key: regularKey).specialNote)
        }
    }

    func testSpecialNotesSurviveNoteCodableRoundTrip() throws {
        let expected: [(Int, SpecialNote)] = [
            (Note.keyOff, .off),
            (Note.keyCut, .cut),
            (Note.keyFade, .fade),
        ]

        for (key, specialNote) in expected {
            let encoded = try JSONEncoder().encode(makeNote(key: key))
            let decoded = try JSONDecoder().decode(Note.self, from: encoded)
            XCTAssertEqual(decoded.key, key)
            XCTAssertEqual(decoded.specialNote, specialNote)
        }
    }

    func testNoteSampleMappingAcceptsAllBoundaryValuesAndQueriesSafely() throws {
        var entries = try (0..<NoteSampleMapping.entryCount).map {
            try NoteSampleMapping.Entry(targetNote: $0, sampleID: 0)
        }
        entries[0] = try NoteSampleMapping.Entry(targetNote: 119, sampleID: 99)
        let mapping = try NoteSampleMapping(entries: entries)

        XCTAssertEqual(NoteSampleMapping.entryCount, 120)
        XCTAssertEqual(mapping.entry(forSourceNote: 0), entries[0])
        XCTAssertEqual(mapping.entry(forSourceNote: 119), entries[119])
        XCTAssertNil(mapping.entry(forSourceNote: -1))
        XCTAssertNil(mapping.entry(forSourceNote: 120))
    }

    func testNoteSampleMappingRejectsWrongEntryCounts() throws {
        let entry = try NoteSampleMapping.Entry(targetNote: 0, sampleID: 0)

        for count in [0, 119, 121] {
            XCTAssertThrowsError(try NoteSampleMapping(entries: Array(repeating: entry, count: count))) {
                XCTAssertEqual($0 as? NoteSampleMapping.ValidationError, .invalidEntryCount(count))
            }
        }
    }

    func testNoteSampleMappingEntryRejectsInvalidTargetNotes() {
        for targetNote in [-1, 120] {
            XCTAssertThrowsError(try NoteSampleMapping.Entry(targetNote: targetNote, sampleID: 0)) {
                XCTAssertEqual($0 as? NoteSampleMapping.ValidationError, .invalidTargetNote(targetNote))
            }
        }
    }

    func testNoteSampleMappingEntryRejectsInvalidSampleIDs() {
        for sampleID in [-1, 100] {
            XCTAssertThrowsError(try NoteSampleMapping.Entry(targetNote: 0, sampleID: sampleID)) {
                XCTAssertEqual($0 as? NoteSampleMapping.ValidationError, .invalidSampleID(sampleID))
            }
        }
    }

    func testNoteSampleMappingSurvivesCodableRoundTrip() throws {
        let entries = try (0..<NoteSampleMapping.entryCount).map {
            try NoteSampleMapping.Entry(targetNote: 119 - $0, sampleID: $0 % 100)
        }
        let original = try NoteSampleMapping(entries: entries)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteSampleMapping.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testNoteSampleMappingDecodingRejectsInvalidValues() throws {
        let validEntry = try NoteSampleMapping.Entry(targetNote: 0, sampleID: 0)
        let validEntries = Array(repeating: validEntry, count: NoteSampleMapping.entryCount)

        try assertMappingDecodeFails(
            entries: Array(validEntries.dropLast()),
            expected: .invalidEntryCount(119)
        )

        var invalidTargetNote = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try NoteSampleMapping(entries: validEntries))
        ) as! [String: Any]
        var targetEntries = invalidTargetNote["entries"] as! [[String: Any]]
        targetEntries[0]["targetNote"] = 120
        invalidTargetNote["entries"] = targetEntries
        try assertMappingDecodeFails(
            jsonObject: invalidTargetNote,
            expected: .invalidTargetNote(120)
        )

        var invalidSampleID = invalidTargetNote
        var sampleEntries = validEntries.map { ["targetNote": $0.targetNote, "sampleID": $0.sampleID] }
        sampleEntries[0]["sampleID"] = 100
        invalidSampleID["entries"] = sampleEntries
        try assertMappingDecodeFails(
            jsonObject: invalidSampleID,
            expected: .invalidSampleID(100)
        )
    }

    func testLegacyXMEnvelopeMapsSustainPointWithoutChangingSemantics() throws {
        let legacyJSON = #"{"points":[{"frame":0,"value":64},{"frame":12,"value":32}],"sustainPoint":1,"loopStart":0,"loopEnd":1,"sustainEnabled":true,"loopEnabled":true}"#
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(envelope.sustainPoint, 1)
        XCTAssertEqual(envelope.sustainStart, 1)
        XCTAssertEqual(envelope.sustainEnd, 1)
        XCTAssertTrue(envelope.sustainEnabled)
        XCTAssertTrue(envelope.loopEnabled)
        XCTAssertFalse(envelope.carryEnabled)
        XCTAssertEqual(envelope.valueMode, .standard)
    }

    func testITEnvelopeRangeCarryAndModesSurviveCodableRoundTrip() throws {
        let points = [
            EnvelopePoint(frame: 0, value: 0),
            EnvelopePoint(frame: 5, value: 32),
            EnvelopePoint(frame: 10, value: 64),
        ]

        for mode in [EnvelopeValueMode.standard, .pitch, .filter] {
            let original = Envelope(
                points: points,
                sustainStart: 1,
                sustainEnd: 2,
                loopStart: 0,
                loopEnd: 2,
                sustainEnabled: true,
                loopEnabled: true,
                carryEnabled: true,
                valueMode: mode
            )
            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Envelope.self, from: encoded)

            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.sustainPoint, 1)
        }
    }

    func testITInstrumentActionsAndPropertiesSurviveCodableRoundTrip() throws {
        XCTAssertEqual(NewNoteAction.cut.rawValue, 0)
        XCTAssertEqual(NewNoteAction.continuePlaying.rawValue, 1)
        XCTAssertEqual(NewNoteAction.noteOff.rawValue, 2)
        XCTAssertEqual(NewNoteAction.noteFade.rawValue, 3)
        XCTAssertEqual(DuplicateCheckType.off.rawValue, 0)
        XCTAssertEqual(DuplicateCheckType.note.rawValue, 1)
        XCTAssertEqual(DuplicateCheckType.sample.rawValue, 2)
        XCTAssertEqual(DuplicateCheckType.instrument.rawValue, 3)
        XCTAssertEqual(DuplicateCheckAction.cut.rawValue, 0)
        XCTAssertEqual(DuplicateCheckAction.noteOff.rawValue, 1)
        XCTAssertEqual(DuplicateCheckAction.noteFade.rawValue, 2)

        let mapping = try NoteSampleMapping(entries: try (0..<120).map {
            try NoteSampleMapping.Entry(targetNote: 119 - $0, sampleID: ($0 % 99) + 1)
        })
        let pitchEnvelope = Envelope(
            points: [EnvelopePoint(frame: 0, value: 32), EnvelopePoint(frame: 8, value: 40)],
            sustainStart: 0,
            sustainEnd: 1,
            loopStart: 0,
            loopEnd: 1,
            sustainEnabled: true,
            loopEnabled: true,
            carryEnabled: true,
            valueMode: .filter
        )
        let properties = ITInstrumentProperties(
            newNoteAction: .noteFade,
            duplicateCheckType: .instrument,
            duplicateCheckAction: .noteOff,
            globalVolume: 128,
            defaultPanning: 64,
            pitchPanSeparation: -32,
            pitchPanCenter: 119,
            randomVolumeVariation: 100,
            randomPanningVariation: 100,
            initialFilterCutoff: 127,
            initialFilterResonance: 127
        )
        let instrument = Instrument(
            index: 1,
            name: "IT",
            samples: [],
            fadeout: 128,
            pitchEnvelope: pitchEnvelope,
            noteSampleMapping: mapping,
            itProperties: properties
        )

        let decoded = try JSONDecoder().decode(
            Instrument.self,
            from: JSONEncoder().encode(instrument)
        )
        XCTAssertEqual(decoded.pitchEnvelope, pitchEnvelope)
        XCTAssertEqual(decoded.noteSampleMapping, mapping)
        XCTAssertEqual(decoded.itProperties, properties)
        XCTAssertEqual(decoded.fadeout, 128)
    }

    func testITSampleStereoSustainAndVibratoSurviveCodableRoundTrip() throws {
        let sustainLoop = SampleLoop(start: 1, length: 3, type: .pingpong)
        let properties = ITSampleProperties(
            c5Speed: 9_999_999,
            globalVolume: 64,
            defaultPanning: 0,
            vibrato: ITSampleVibrato(speed: 64, depth: 64, rate: 64, waveform: .random)
        )
        let sample = Sample(
            pcm: [-0.5, 0.0, 0.5, 0.25],
            loopStart: 0,
            loopLength: 4,
            loopType: .forward,
            volume: 64,
            finetune: 0,
            rightPCM: [0.5, 0.0, -0.5, -0.25],
            sustainLoop: sustainLoop,
            itProperties: properties
        )

        let decoded = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(decoded.pcm, sample.pcm)
        XCTAssertEqual(decoded.rightPCM, sample.rightPCM)
        XCTAssertEqual(decoded.sustainLoop, sustainLoop)
        XCTAssertEqual(decoded.itProperties, properties)
        XCTAssertEqual(decoded.itProperties?.vibrato?.waveform, .random)
    }

    func testModuleSemanticsChannelVolumesAndGlobalVolumeScale() throws {
        let emptyPattern = Pattern(rows: [])
        let formats: [(ModuleFormat, Bool, PlaybackSemantics)] = [
            (.protracker, false, .proTracker),
            (.soundtracker, false, .proTracker),
            (.multichannel, false, .proTracker),
            (.s3m, false, .screamTracker3),
            (.xm, false, .fastTracker2(linearFrequency: false)),
            (.xm, true, .fastTracker2(linearFrequency: true)),
        ]

        for (format, linearFrequency, semantics) in formats {
            let module = Mod(
                name: "Legacy",
                length: 1,
                patternTable: [0],
                instruments: [nil],
                patterns: [emptyPattern],
                channelCount: 3,
                format: format,
                linearFrequency: linearFrequency
            )
            XCTAssertEqual(module.channelVolumes, [64, 64, 64])
            XCTAssertEqual(module.samplePool.count, 1)
            XCTAssertNil(module.samplePool[0])
            XCTAssertEqual(module.channelSurrounds, [false, false, false])
            XCTAssertEqual(module.channelDisabled, [false, false, false])
            XCTAssertEqual(module.globalVolumeScale, .tracker64)
            XCTAssertEqual(module.playbackSemantics, semantics)
        }

        let compatibility = ITCompatibility(oldEffects: true, compatibleGxx: false)
        let module = Mod(
            name: "IT",
            length: 1,
            patternTable: [0],
            instruments: [nil],
            patterns: [emptyPattern],
            channelCount: 2,
            format: .it,
            initialGlobalVolume: 128,
            channelPannings: [0.0, 1.0],
            channelVolumes: [12, 34],
            channelSurrounds: [true, false],
            channelDisabled: [false, true],
            playbackSemantics: .impulseTracker(compatibility)
        )
        XCTAssertEqual(module.channelVolumes, [12, 34])
        XCTAssertEqual(module.channelSurrounds, [true, false])
        XCTAssertEqual(module.channelDisabled, [false, true])
        XCTAssertEqual(module.globalVolumeScale, .impulseTracker128)
        XCTAssertEqual(module.playbackSemantics, .impulseTracker(compatibility))

        let decoded = try JSONDecoder().decode(Mod.self, from: JSONEncoder().encode(module))
        XCTAssertEqual(decoded.channelVolumes, [12, 34])
        XCTAssertEqual(decoded.channelSurrounds, [true, false])
        XCTAssertEqual(decoded.channelDisabled, [false, true])
        XCTAssertEqual(decoded.playbackSemantics, .impulseTracker(compatibility))
    }

    func testUsedChannelCountIgnoresReservedEmptyChannelsAndUnusedPatterns() {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        let audible = Note(instrument: 1, period: 428, effectId: 0, effectData: 0)
        let effectOnly = Note(instrument: 0, period: 0, effectId: 0, effectData: 0, effectPresent: true)

        var playedNotes = [Note](repeating: empty, count: 64)
        playedNotes[2] = audible
        playedNotes[17] = effectOnly
        var unusedNotes = [Note](repeating: empty, count: 64)
        unusedNotes[63] = audible

        let module = Mod(
            name: "Kanaltest",
            length: 1,
            patternTable: [0],
            instruments: [nil],
            patterns: [
                Pattern(rows: [Row(notes: playedNotes)]),
                Pattern(rows: [Row(notes: unusedNotes)])
            ],
            channelCount: 64,
            format: .it
        )

        XCTAssertEqual(module.usedChannelCount, 2)
    }

    func testUsedChannelCountFallsBackToDeclaredCountForEmptySong() {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        let module = Mod(
            name: "Leer",
            length: 1,
            patternTable: [0],
            instruments: [nil],
            patterns: [Pattern(rows: [Row(notes: [empty, empty, empty, empty])])],
            channelCount: 4
        )

        XCTAssertEqual(module.usedChannelCount, 4)
    }

    func testLegacyModuleCodableDefaultsNewM1Fields() throws {
        let module = Mod(
            name: "Legacy",
            length: 0,
            patternTable: [],
            instruments: [nil],
            patterns: [],
            channelCount: 2,
            format: .xm,
            linearFrequency: true
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(module)) as? [String: Any]
        )
        object.removeValue(forKey: "channelVolumes")
        object.removeValue(forKey: "samplePool")
        object.removeValue(forKey: "channelSurrounds")
        object.removeValue(forKey: "channelDisabled")
        object.removeValue(forKey: "playbackSemantics")

        let decoded = try JSONDecoder().decode(
            Mod.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.channelVolumes, [64, 64])
        XCTAssertEqual(decoded.samplePool.count, 1)
        XCTAssertNil(decoded.samplePool[0])
        XCTAssertEqual(decoded.channelSurrounds, [false, false])
        XCTAssertEqual(decoded.channelDisabled, [false, false])
        XCTAssertEqual(decoded.playbackSemantics, .fastTracker2(linearFrequency: true))
    }

    /// Erstellt eine ansonsten leere Note, damit der jeweilige Schlüssel isoliert
    /// geprüft wird und keine Effekt- oder Instrumentdaten das Ergebnis beeinflussen.
    private func makeNote(key: Int) -> Note {
        Note(instrument: 0, period: 0, effectId: 0, effectData: 0, key: key)
    }

    /// Kodiert und dekodiert einen Wert wie bei einer späteren Speicherung.
    private func assertCodableRoundTrip(
        _ original: PlaybackSemantics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackSemantics.self, from: encoded)
        XCTAssertEqual(decoded, original, file: file, line: line)
    }

    /// Baut ein JSON-Objekt aus gültigen Einträgen und prüft den erwarteten,
    /// kontrollierten Validierungsfehler beim Dekodieren.
    private func assertMappingDecodeFails(
        entries: [NoteSampleMapping.Entry],
        expected: NoteSampleMapping.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let jsonObject: [String: Any] = [
            "entries": entries.map { ["targetNote": $0.targetNote, "sampleID": $0.sampleID] },
        ]
        try assertMappingDecodeFails(jsonObject: jsonObject, expected: expected, file: file, line: line)
    }

    private func assertMappingDecodeFails(
        jsonObject: [String: Any],
        expected: NoteSampleMapping.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        XCTAssertThrowsError(try JSONDecoder().decode(NoteSampleMapping.self, from: data), file: file, line: line) {
            XCTAssertEqual($0 as? NoteSampleMapping.ValidationError, expected, file: file, line: line)
        }
    }
}
