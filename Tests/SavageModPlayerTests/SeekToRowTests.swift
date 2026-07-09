import XCTest
@testable import SavageModPlayerCore

/// Tests für den zeilengenauen Sprung (Grid-Klick auf eine Zeile) und die
/// Tempo-Rekonstruktion, damit ein Sprung mitten in den Song im richtigen Tempo
/// startet (z.B. Starfish: Speed 8 wird in Pattern-Pos 0, Zeile 0 gesetzt).
final class SeekToRowTests: XCTestCase {

    // Mod mit 2 Positionen; Pattern 0 setzt in Zeile 3 Speed 8 (Effekt 0F08 auf Kanal 0).
    private func makeMod() -> Mod {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        func emptyRow() -> Row { Row(notes: [Note](repeating: empty, count: 4)) }
        var p0 = [Row]()
        for r in 0..<10 {
            if r == 3 {
                // Set Speed 8 (Fxx, xx=8) auf Kanal 0.
                let speedNote = Note(instrument: 0, period: 0, effectId: 0x0F, effectData: 8)
                p0.append(Row(notes: [speedNote, empty, empty, empty]))
            } else {
                p0.append(emptyRow())
            }
        }
        let pattern0 = Pattern(rows: p0)
        let pattern1 = Pattern(rows: (0..<8).map { _ in emptyRow() })
        return Mod(name: "seek", length: 2, patternTable: [0, 1],
                   instruments: [nil], patterns: [pattern0, pattern1], channelCount: 4)
    }

    /// Speed 8 ab Zeile 3; davor der Modul-Default (6). Bestätigt, dass die
    /// Rekonstruktion Set-Speed-Effekte bis zur Zielzeile anwendet.
    func testReconstructGlobalParamsAppliesSpeedUpToRow() {
        let mod = makeMod()
        XCTAssertEqual(ModPlayerCoordinator.reconstructGlobalParams(mod, toPosition: 0, row: 2).speed, 6,
                       "Vor dem Speed-Effekt gilt der Modul-Default")
        XCTAssertEqual(ModPlayerCoordinator.reconstructGlobalParams(mod, toPosition: 0, row: 3).speed, 8,
                       "Ab der Effekt-Zeile gilt Speed 8")
        XCTAssertEqual(ModPlayerCoordinator.reconstructGlobalParams(mod, toPosition: 0, row: 9).speed, 8)
        // Spätere Position erbt den zuletzt gesetzten Speed.
        XCTAssertEqual(ModPlayerCoordinator.reconstructGlobalParams(mod, toPosition: 1, row: 0).speed, 8)
    }

    /// Seek im gestoppten Zustand merkt Position+Zeile vor und zeigt sie an;
    /// out-of-range wird geklemmt (kein Crash).
    @MainActor
    func testSeekToRowWhileStoppedClampsAndShows() {
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(makeMod())

        coordinator.seek(toPosition: 0, row: 5)
        XCTAssertEqual(coordinator.currentPosition, 0)
        XCTAssertEqual(coordinator.currentRow, 5)

        // Zeile jenseits der Pattern-Länge -> auf letzte Zeile (9) geklemmt.
        coordinator.seek(toPosition: 0, row: 99)
        XCTAssertEqual(coordinator.currentRow, 9)

        // Position jenseits der Songlänge -> auf letzte Position (1) geklemmt.
        coordinator.seek(toPosition: 42, row: 0)
        XCTAssertEqual(coordinator.currentPosition, 1)
    }
}
