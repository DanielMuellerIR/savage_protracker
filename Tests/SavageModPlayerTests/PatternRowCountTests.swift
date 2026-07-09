import XCTest
@testable import SavageModPlayerCore

/// Regressionstest für den Pattern-Reihenzahl-Bug (2026-07-09).
///
/// XM-Patterns haben variable Länge (1..256 Reihen); MOD/S3M immer 64. Der
/// Sequencer im Render-Block wrappte aber hartkodiert bei 64 Reihen — ein
/// kurzes Pattern (z. B. 30 Reihen) spielte danach ~34 leere Reihen weiter,
/// bevor es zur nächsten Position wechselte. Folge: Timing-Drift durch den
/// ganzen Song (bei _Starfish – Life Support_ Gesamtdauer 212,6 s statt
/// korrekter 178,8 s) und weiterlaufende Volume-Slides → laute, fehlplatzierte
/// Percussion. Fix: `ModPlayerCoordinator.patternRowCount(_:at:)` liefert die
/// echte Reihenzahl, beide Wrap-Stellen (Live-Block + Probe) nutzen sie.
final class PatternRowCountTests: XCTestCase {

    // Ein lautes, gelooptes Konstant-Sample als Instrument 1 (MOD-Stil).
    private func loudInstrument() -> Instrument {
        Instrument(index: 1, name: "loud", length: 64, finetune: 0, volume: 64,
                   repeatOffset: 0, repeatLength: 64,
                   bytes: [Int8](repeating: 100, count: 64), isLooped: true)
    }

    // Baut einen Mod mit zwei Positionen: Pattern 0 hat `firstPatternRows`
    // (leer), Pattern 1 hat 8 Reihen und triggert in Reihe 0 eine laute Note.
    private func makeMod(firstPatternRows: Int) -> Mod {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        func emptyRow() -> Row { Row(notes: [Note](repeating: empty, count: 4)) }

        // Pattern 0: nur leere Reihen (Stille), Länge = firstPatternRows.
        let pattern0 = Pattern(rows: (0..<firstPatternRows).map { _ in emptyRow() })

        // Pattern 1: Reihe 0 spielt Instrument 1, Note C-3 (Period 428) auf Kanal 0.
        let note = Note(instrument: 1, period: 428, effectId: 0, effectData: 0)
        var p1rows = [Row]()
        p1rows.append(Row(notes: [note, empty, empty, empty]))
        for _ in 1..<8 { p1rows.append(emptyRow()) }
        let pattern1 = Pattern(rows: p1rows)

        return Mod(name: "rowcount", length: 2, patternTable: [0, 1],
                   instruments: [nil, loudInstrument()],
                   patterns: [pattern0, pattern1], channelCount: 4)
    }

    // Findet den ersten Frame über der Schwelle in einer 16-Bit-Stereo-WAV.
    // Rückgabe in Sekunden (Signal-Einsatz), oder nil bei Stille.
    private func firstAudibleSecond(_ wav: Data, sampleRate: Double = 44100) -> Double? {
        let headerBytes = 44
        guard wav.count > headerBytes else { return nil }
        let samples = wav.subdata(in: headerBytes..<wav.count)
        let count = samples.count / 2
        return samples.withUnsafeBytes { raw -> Double? in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                if abs(Int(p[i])) > 800 { // ~0.024 von Vollausschlag
                    // i zählt Int16-Werte; Stereo -> 2 pro Frame.
                    let frame = i / 2
                    return Double(frame) / sampleRate
                }
            }
            return nil
        }
    }

    /// Die pure Reihenzahl-Funktion liefert die echte Pattern-Länge.
    func testPatternRowCountReportsRealLength() {
        let mod = makeMod(firstPatternRows: 8)
        XCTAssertEqual(ModPlayerCoordinator.patternRowCount(mod, at: 0), 8)
        XCTAssertEqual(ModPlayerCoordinator.patternRowCount(mod, at: 1), 8)
        // Position außerhalb der Order-Table wird geklemmt (kein Crash).
        XCTAssertEqual(ModPlayerCoordinator.patternRowCount(mod, at: 99), 8)
    }

    /// Globaler Zeilen-Index und Umkehrung müssen die echten Pattern-Längen
    /// nutzen (Pattern 0 = 30 Reihen, Pattern 1 = 8) — nicht 64. Davon hängt die
    /// korrekte Elapsed-/Gesamtzeit und die Positionsanzeige beim Seek ab (#9).
    func testCumulativeRowsUsesRealLengths() {
        let mod = makeMod(firstPatternRows: 30)
        XCTAssertEqual(ModPlayerCoordinator.cumulativeRows(mod, upTo: 0), 0)
        XCTAssertEqual(ModPlayerCoordinator.cumulativeRows(mod, upTo: 1), 30, "nicht 64")
        XCTAssertEqual(ModPlayerCoordinator.cumulativeRows(mod, upTo: 1, row: 3), 33)
        XCTAssertEqual(ModPlayerCoordinator.cumulativeRows(mod, upTo: 2), 38, "Gesamtreihen 30+8")

        // Round-Trip: globaler Index -> (Position, Zeile) -> derselbe Index.
        for (gr, pos, row) in [(0, 0, 0), (29, 0, 29), (30, 1, 0), (33, 1, 3)] {
            let t = ModPlayerCoordinator.positionAndRow(mod, forGlobalRow: gr)
            XCTAssertEqual(t.position, pos, "globalRow \(gr)")
            XCTAssertEqual(t.row, row, "globalRow \(gr)")
        }
        // Über das Songende hinaus wird auf die letzte Zeile geklemmt.
        let end = ModPlayerCoordinator.positionAndRow(mod, forGlobalRow: 999)
        XCTAssertEqual(end.position, 1)
        XCTAssertEqual(end.row, 7)
    }

    /// Kernregression: Bei einem kurzen ersten Pattern (8 Reihen) muss die Note
    /// aus Pattern 1 nach ~8 Reihen einsetzen — NICHT erst nach 64 Reihen. Bei
    /// Speed 6 / 125 BPM dauert eine Reihe 0,12 s, also ~0,96 s (8 Reihen) vs.
    /// dem alten Bug bei ~7,68 s (64 Reihen).
    func testShortPatternDoesNotPlayPhantomRows() throws {
        let mod = makeMod(firstPatternRows: 8)
        let wav = try ModuleRenderer.renderWavData(mod: mod, maxDurationSeconds: 20.0, normalize: false)
        let onset = try XCTUnwrap(firstAudibleSecond(wav), "Pattern 1 muss hörbares Signal liefern")
        XCTAssertLessThan(onset, 2.0,
                          "Note setzt bei ~0,96 s ein (8 Reihen); >2 s bedeutet: Phantom-Reihen bis 64 gespielt")
        XCTAssertGreaterThan(onset, 0.5,
                             "Die ersten 8 Reihen sind leer — vor ~0,96 s darf nichts klingen")
    }
}
