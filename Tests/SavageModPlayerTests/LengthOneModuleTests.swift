import XCTest
@testable import SavageModPlayerCore

/// Regressionstests für Module mit nur EINER Song-Position (`mod.length == 1`).
///
/// Hintergrund (2026-07-09): Der Song-Positions-Slider stürzte bei Länge 1 ab,
/// weil `in: 0...(length-1)` den LEEREN Bereich `0...0` ergab und SwiftUIs
/// `Slider` daraufhin eine precondition auslöst. Der Crash selbst ist rein GUI
/// und nicht headless reproduzierbar; deshalb sichern diese Tests zweierlei ab:
/// (a) die Crash-verhindernde Arithmetik `SongPositionScale` (Bereich nie leer)
/// und (b) dass ein Länge-1-Modul die Engine sauber durchläuft (Parsen, Rendern,
/// Seek). Ersetzt die frühere GUI-Repro-Datei `audio/_ZZ_len1_crashtest.xm`.
final class LengthOneModuleTests: XCTestCase {

    /// Baut ein minimal gültiges M.K.-MOD mit wählbarer Songlänge. Pattern 0,
    /// Row 0, Kanal 0: Instrument 1, Note C-3, kein Effekt. Alle Song-Positionen
    /// zeigen auf Pattern 0.
    private func makeMod(songLength: Int) -> Data {
        var data = Data(repeating: 0, count: 1084 + 1024 + 8)
        // Instrument 1: Länge 2 Words (4 Bytes), Volume 64, kein Loop.
        data[20 + 22] = 0x00 // length hi
        data[20 + 23] = 0x02 // length lo (2 words = 4 bytes)
        data[20 + 25] = 64   // volume
        // Songlänge + Pattern-Table (alle Positionen auf Pattern 0).
        data[950] = UInt8(songLength)
        for i in 0..<songLength { data[952 + i] = 0 }
        // Signatur M.K.
        data.replaceSubrange(1080..<1084, with: Data("M.K.".utf8))
        // Pattern 0, Row 0, Kanal 0: Instrument 1, Period 428 (C-3).
        let period = 428
        data[1084 + 0] = UInt8((period >> 8) & 0x0F) // SampleHi=0, Period-Hi
        data[1084 + 1] = UInt8(period & 0xFF)         // Period-Lo
        data[1084 + 2] = UInt8((1 << 4) | 0)          // SampleLo=1, EffId=0
        data[1084 + 3] = 0                            // EffData
        return data
    }

    // MARK: - Crash-verhindernde Arithmetik (der eigentliche Bug)

    /// Für JEDE Song-Länge muss der Slider-Bereich nicht leer sein
    /// (lowerBound < upperBound) und der geklemmte Wert darin liegen — sonst
    /// crasht SwiftUIs Slider (genau der Länge-1-Fall 0...0).
    func testPositionScaleNeverEmptyRange() {
        for length in [0, 1, 2, 10, 64, 128] {
            for current in [-5, 0, length, length + 3] {
                let b = SongPositionScale.bounds(positionCount: length, current: current)
                XCTAssertLessThan(b.range.lowerBound, b.range.upperBound,
                                  "Länge \(length): Bereich darf nie leer sein (0...0 crasht den Slider)")
                XCTAssertTrue(b.range.contains(b.value),
                              "Länge \(length), current \(current): Wert muss im Bereich liegen")
            }
        }
    }

    /// Länge 1 muss 0...1 ergeben (nicht das crashende 0...0) und deaktiviert sein.
    func testPositionScaleLengthOne() {
        let b = SongPositionScale.bounds(positionCount: 1, current: 0)
        XCTAssertEqual(b.range, 0.0...1.0, "Länge 1 muss 0...1 ergeben, nicht das leere 0...0")
        XCTAssertEqual(b.value, 0.0)
        XCTAssertFalse(b.isEnabled, "Bei nur einer Position ist der Slider deaktiviert")
    }

    /// Ab zwei Positionen ist der Slider bedienbar, bei 0/1 nicht.
    func testPositionScaleEnabledOnlyWithChoice() {
        XCTAssertTrue(SongPositionScale.bounds(positionCount: 2, current: 0).isEnabled)
        XCTAssertFalse(SongPositionScale.bounds(positionCount: 1, current: 0).isEnabled)
        XCTAssertFalse(SongPositionScale.bounds(positionCount: 0, current: 0).isEnabled)
    }

    // MARK: - Engine durchläuft ein Länge-1-Modul sauber

    func testLengthOneModuleParses() throws {
        let mod = try ModParser.parse(data: makeMod(songLength: 1))
        XCTAssertEqual(mod.length, 1)
    }

    /// Headless-Render (kein Audio-Gerät nötig): darf nicht crashen und muss
    /// gültige, nicht-leere WAV-Daten liefern.
    func testLengthOneModuleRendersWithoutCrash() throws {
        let mod = try ModParser.parse(data: makeMod(songLength: 1))
        let wav = try ModuleRenderer.renderWavData(mod: mod, maxDurationSeconds: 5.0)
        XCTAssertGreaterThan(wav.count, 44, "WAV muss über den 44-Byte-RIFF-Header hinaus Daten haben")
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
    }

    /// Seek jenseits der einzigen Position muss auf 0 klemmen (kein Absturz).
    @MainActor
    func testLengthOneModuleSeekClampsToZero() throws {
        let mod = try ModParser.parse(data: makeMod(songLength: 1))
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(mod)
        coordinator.seek(toPosition: 5) // jenseits der einzigen Position
        XCTAssertEqual(coordinator.currentPosition, 0, "Seek muss bei Länge 1 auf Position 0 klemmen")
    }
}
