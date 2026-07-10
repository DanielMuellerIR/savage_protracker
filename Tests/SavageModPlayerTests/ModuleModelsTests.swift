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

    func testLoaderExtensionsRemainUnchangedUntilITParserIntegration() {
        XCTAssertEqual(ModuleLoader.supportedExtensions, Set(["mod", "s3m", "xm"]))
        XCTAssertFalse(ModuleLoader.supportedExtensions.contains("it"))
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
