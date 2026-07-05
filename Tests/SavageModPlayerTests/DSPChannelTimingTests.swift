import XCTest
@testable import SavageModPlayerCore

/// Prüft die ProTracker-Tick-Timing-Regel in `DSPChannel.performTick`:
/// Porta-Slides (1xx/2xx/3xx) und der Vibrato-/Tremolo-Sinusindex dürfen NUR
/// auf Ticks > 0 fortschreiten, NIE auf Tick 0. Andernfalls macht jede Row
/// einen Schritt zu viel (6 statt 5 bei Speed 6) und der Index driftet.
/// Dieselbe Logik existiert im HTML-Worklet (mod-player-worklet.js); beide
/// Varianten müssen sample-genau gleich laufen.
final class DSPChannelTimingTests: XCTestCase {

    // Werte sind für das Timing irrelevant, müssen aber > 0 sein.
    private let sampleRate = 44100.0
    private let clockRate = 3546894.6 // PAULA_FREQUENCY (wie im Worklet)

    /// Spielt eine komplette Row bei Speed 6 ab (Ticks 0..5).
    private func playRow(_ ch: DSPChannel, ticksPerRow: Int = 6) {
        for tick in 0..<ticksPerRow {
            ch.performTick(tick: tick, sampleRate: sampleRate, clockRate: clockRate)
        }
    }

    /// 2xx Porta-Down: pro Row bei Speed 6 genau 5 Schritte (Tick 1..5),
    /// NICHT 6. Bei delta=4 → +20, nicht +24.
    func testSlideDownAppliesFiveStepsPerRow() {
        let ch = DSPChannel(index: 1)
        ch.period = 300
        ch.currentPeriod = 300
        ch.periodDelta = 4 // 2xx: positiver Delta = Periode steigt
        ch.portamento = false

        playRow(ch)

        XCTAssertEqual(ch.currentPeriod, 320, accuracy: 0.0001,
                       "Slide muss 5 Schritte (Tick 1..5) machen, nicht 6")
    }

    /// Tick 0 darf den Slide nicht anwenden; Tick 1 schon.
    func testSlideDoesNotAdvanceOnTickZero() {
        let ch = DSPChannel(index: 1)
        ch.period = 300
        ch.currentPeriod = 300
        ch.periodDelta = 4
        ch.portamento = false

        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentPeriod, 300, accuracy: 0.0001,
                       "Auf Tick 0 darf kein Slide passieren")

        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentPeriod, 304, accuracy: 0.0001,
                       "Auf Tick 1 muss der erste Slide-Schritt passieren")
    }

    /// 3xx Tone-Portamento: ebenfalls 5 Schritte/Row, Ziel weit genug weg,
    /// damit der Clamp auf das Ziel den Bug nicht verdeckt.
    func testTonePortamentoAppliesFiveStepsPerRow() {
        let ch = DSPChannel(index: 1)
        ch.period = 400          // Zielperiode
        ch.currentPeriod = 300   // Startperiode
        ch.portamentoSpeed = 4
        ch.periodDelta = 4
        ch.portamento = true

        playRow(ch)

        XCTAssertEqual(ch.currentPeriod, 320, accuracy: 0.0001,
                       "Tone-Porta muss 5 Schritte Richtung Ziel machen, nicht 6")
    }

    /// Vibrato-Sinusindex: pro Row bei Speed 6 genau 5 Advances (Tick 1..5).
    /// Bei speed=4 → Index 20, nicht 24.
    func testVibratoIndexAdvancesFiveStepsPerRow() {
        let ch = DSPChannel(index: 1)
        ch.period = 300
        ch.currentPeriod = 300
        ch.vibrato = true
        ch.vibratoSpeed = 4
        ch.vibratoDepth = 8
        ch.vibratoIndex = 0

        playRow(ch)

        XCTAssertEqual(ch.vibratoIndex, 20, accuracy: 0.0001,
                       "Vibrato-Index muss 5x weiterdrehen, nicht 6x")
    }

    /// Vibrato darf den Index auf Tick 0 nicht weiterdrehen.
    func testVibratoIndexFrozenOnTickZero() {
        let ch = DSPChannel(index: 1)
        ch.period = 300
        ch.currentPeriod = 300
        ch.vibrato = true
        ch.vibratoSpeed = 4
        ch.vibratoIndex = 0

        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.vibratoIndex, 0, accuracy: 0.0001,
                       "Auf Tick 0 darf der Vibrato-Index nicht weiterdrehen")
    }

    /// Fine-Porta E1x wird auf die anstehende Note-Period angewandt (falls in
    /// dieser Row gesetzt), nicht auf die alte — Parität zur JS-Variante.
    func testFinePortaUsesPendingPeriod() {
        let ch = DSPChannel(index: 1)
        ch.period = 300
        ch.setPeriod = 200 // anstehende Note-Period
        ch.applyEffect(note: Note(instrument: 0, period: 0, effectId: 0xE1, effectData: 5))
        XCTAssertEqual(ch.setPeriod, 195, "E1x muss auf die anstehende Period (200-5) wirken")
    }

    /// 9xx-Sample-Offset-Memory: 900 (Parameter 0) wiederholt den letzten
    /// 9xx-Offset statt hart auf 0 zu springen.
    func testSampleOffsetMemoryReusesLastOffset() {
        let inst = Instrument(index: 1, name: "x", length: 4096, finetune: 0, volume: 64,
                              repeatOffset: 0, repeatLength: 0, bytes: [Int8](repeating: 1, count: 4096), isLooped: false)
        let ch = DSPChannel(index: 1)
        // 904 -> Offset 0x04 * 256 = 1024.
        ch.playNote(Note(instrument: 1, period: 428, effectId: 0x09, effectData: 0x04), instruments: [nil, inst])
        XCTAssertEqual(ch.sampleIndex, 1024, accuracy: 0.001)
        // 900 -> muss 1024 wiederholen, nicht 0.
        ch.playNote(Note(instrument: 1, period: 428, effectId: 0x09, effectData: 0x00), instruments: [nil, inst])
        XCTAssertEqual(ch.sampleIndex, 1024, accuracy: 0.001, "900 muss letzten Offset wiederholen")
    }

    /// Arpeggio (jetzt allokationsfrei via Skalare statt [Int]) muss weiterhin
    /// den Zyklus [0, x, y] ueber tick % 3 liefern.
    func testArpeggioCyclesWithoutArray() {
        let ch = DSPChannel(index: 1)
        ch.period = 400
        ch.currentPeriod = 400
        ch.arpActive = true
        ch.arpX = 4
        ch.arpY = 7

        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentPeriod, 400, accuracy: 0.01, "Tick 0: Grundton")

        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentPeriod, 400.0 / Float(pow(2.0, 4.0/12.0)), accuracy: 0.01, "Tick 1: +4 Halbtoene")

        ch.performTick(tick: 2, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentPeriod, 400.0 / Float(pow(2.0, 7.0/12.0)), accuracy: 0.01, "Tick 2: +7 Halbtoene")
    }

    /// Vibrato-Amplitude muss der ProTracker-Tabelle entsprechen: Peak =
    /// depth*255/128 Period-Einheiten (frueher mit sin() nur ~depth, halb so tief).
    func testVibratoDepthMatchesProTrackerAmplitude() {
        let ch = DSPChannel(index: 1)
        ch.period = 400
        ch.currentPeriod = 400
        ch.vibrato = true
        ch.vibratoSpeed = 1
        ch.vibratoDepth = 8
        var maxDelta: Float = 0
        for _ in 0..<128 { // > 64, deckt eine volle Sinusperiode ab
            ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
            maxDelta = max(maxDelta, abs(ch.currentPeriod - 400))
        }
        XCTAssertEqual(maxDelta, 8.0 * 255.0 / 128.0, accuracy: 0.01,
                       "Vibrato-Peak muss depth*255/128 sein")
    }

    /// Tremolo-Amplitude: Peak = depth*255/64 Volume-Einheiten (frueher ~depth,
    /// also ein Viertel so stark).
    func testTremoloDepthMatchesProTrackerAmplitude() {
        let ch = DSPChannel(index: 1)
        ch.volume = 32
        ch.currentVolume = 32
        ch.tremolo = true
        ch.tremoloSpeed = 1
        ch.tremoloDepth = 4
        var maxDelta: Float = 0
        for _ in 0..<128 {
            ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
            maxDelta = max(maxDelta, abs(ch.currentVolume - 32))
        }
        XCTAssertEqual(maxDelta, 4.0 * 255.0 / 64.0, accuracy: 0.01,
                       "Tremolo-Peak muss depth*255/64 sein")
    }

    /// Tremolo-Index: gleiche Regel wie Vibrato.
    func testTremoloIndexAdvancesFiveStepsPerRow() {
        let ch = DSPChannel(index: 1)
        ch.volume = 32
        ch.currentVolume = 32
        ch.tremolo = true
        ch.tremoloSpeed = 4
        ch.tremoloDepth = 8
        ch.tremoloIndex = 0

        playRow(ch)

        XCTAssertEqual(ch.tremoloIndex, 20, accuracy: 0.0001,
                       "Tremolo-Index muss 5x weiterdrehen, nicht 6x")
    }
}
