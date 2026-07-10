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
}
