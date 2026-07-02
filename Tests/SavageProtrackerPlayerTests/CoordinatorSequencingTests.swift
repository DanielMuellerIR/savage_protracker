import XCTest
@testable import SavageProtrackerPlayerCore

/// Regressionstests fuer die Song-Sequenzierung im Render-/Probe-Pfad des
/// `ModPlayerCoordinator` (Pattern-Break, Wrap, Loop).
final class CoordinatorSequencingTests: XCTestCase {

    /// Baut ein minimal gueltiges 2-Positionen-M.K.-MOD. In Pattern 0, Row 0,
    /// Kanal 0 steht eine Note plus ein per Parameter waehlbarer Effekt.
    private func makeMod(effectId: UInt8, effectData: UInt8) -> Data {
        var data = Data(repeating: 0, count: 1084 + 1024 + 8)

        // Instrument 1: Laenge 2 Words? Wir setzen Laenge = 4 Bytes (Word 2),
        // Volume 64, kein Loop.
        data[20 + 22] = 0x00 // length hi
        data[20 + 23] = 0x02 // length lo (2 words = 4 bytes)
        data[20 + 25] = 64   // volume

        // Songlaenge 2, Pattern-Table [0, 0].
        data[950] = 2
        data[952] = 0
        data[953] = 0

        // Signatur M.K.
        data.replaceSubrange(1080..<1084, with: Data("M.K.".utf8))

        // Pattern 0, Row 0, Kanal 0: Instrument 1, Period 428 (C-3), + Effekt.
        // Byte-Layout: b0=Period-Hi(+SampleHi), b1=Period-Lo, b2=SampleLo<<4|EffId, b3=EffData
        let period = 428
        let b0 = UInt8((period >> 8) & 0x0F)            // SampleHi=0
        let b1 = UInt8(period & 0xFF)
        let b2 = UInt8((1 << 4) | (Int(effectId) & 0x0F)) // SampleLo=1
        let b3 = effectData
        let noteOffset = 1084
        data[noteOffset + 0] = b0
        data[noteOffset + 1] = b1
        data[noteOffset + 2] = b2
        data[noteOffset + 3] = b3

        return data
    }

    /// Pause haelt die Engine an, ohne den Zustand zu verwerfen; resume() setzt
    /// fort; stop() raeumt beide Flags auf. Braucht ein echtes Audio-Geraet —
    /// ohne (z.B. CI) startet play() nicht und der Test wird uebersprungen.
    @MainActor
    func testPauseAndResumeKeepPlaybackState() async throws {
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(ModParser.generateDemoMod())
        coordinator.play()
        guard coordinator.isPlaying else { return }

        try await Task.sleep(nanoseconds: 200_000_000)
        coordinator.pause()
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(coordinator.isPlaying, "Pause darf die Engine nicht abbauen")
        let pausedPosition = coordinator.currentPosition

        try await Task.sleep(nanoseconds: 200_000_000)
        coordinator.resume()
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(coordinator.isPlaying)
        // Nach dem Fortsetzen laeuft es an derselben Stelle weiter (die
        // Position kann nur >= der Pausen-Position sein, nie zurueckspringen).
        XCTAssertGreaterThanOrEqual(coordinator.currentPosition, pausedPosition)

        coordinator.stop()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertFalse(coordinator.isPaused)
    }

    /// Seek im gestoppten Zustand merkt die Position vor; play() startet dort.
    @MainActor
    func testSeekWhileStoppedStartsPlaybackAtPosition() async throws {
        // makeMod liefert einen 2-Positionen-Song.
        let mod = try ModParser.parse(data: makeMod(effectId: 0x00, effectData: 0x00))
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(mod)

        coordinator.seek(toPosition: 1)
        XCTAssertEqual(coordinator.currentPosition, 1, "Slider-Position muss auch gestoppt sichtbar sein")

        coordinator.play()
        guard coordinator.isPlaying else { return } // kein Audio-Geraet -> skip
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coordinator.currentPosition, 1, "Wiedergabe muss an der vorgemerkten Position starten")
        coordinator.stop()
    }

    /// Relativer Zeitsprung (+30s) rechnet Sekunden in Zeilen um und springt
    /// zeilengenau; das Ziel wird ans Songende geklemmt.
    @MainActor
    func testSeekBySecondsJumpsForward() async throws {
        let mod = try ModParser.parse(data: makeMod(effectId: 0x00, effectData: 0x00))
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(mod)
        coordinator.play()
        guard coordinator.isPlaying else { return }

        try await Task.sleep(nanoseconds: 200_000_000)
        // Bei 125 BPM / Speed 6 dauert eine Zeile 0,12s -> +10s = ~83 Zeilen,
        // also mitten in Position 1 (weit genug vor dem Songende, damit der
        // Song waehrend der Pruef-Wartezeit nicht auf Position 0 wrappt).
        coordinator.seek(bySeconds: 10)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(coordinator.currentPosition, 1)
        coordinator.stop()
    }

    /// Vor dem Fix: ein Dxx mit BCD-Wert > 63 (z.B. D99 = 99) setzte rowIndex
    /// auf 99; der Wrap-Test `== 64` traf nie, also kletterte die Zeile endlos
    /// und der Song hing stumm fest. Jetzt muss rowIndex immer 0..63 bleiben.
    @MainActor
    func testOutOfRangePatternBreakDoesNotHang() throws {
        // Effekt 0x0D (Pattern Break), Daten 0x99 -> BCD 9*10+9 = 99 (> 63).
        let mod = try ModParser.parse(data: makeMod(effectId: 0x0D, effectData: 0x99))
        let coordinator = ModPlayerCoordinator()
        let samples = coordinator.renderProbe(mod: mod, durationSeconds: 3.0)

        XCTAssertFalse(samples.isEmpty, "Probe sollte Samples liefern")
        let maxRow = samples.map { $0.row }.max() ?? -1
        XCTAssertLessThanOrEqual(maxRow, 63, "rowIndex darf nie ueber 63 klettern (kein Hang)")
        XCTAssertGreaterThanOrEqual(samples.map { $0.row }.min() ?? -1, 0)
    }

    /// Hardware-freier Render-Smoke-Test: Das eingebaute Demo-Mod muss ueber
    /// renderProbe hoerbares Audio erzeugen. Laeuft OHNE audio/-Ordner und OHNE
    /// Audio-Geraet (reine Berechnung) — die DSP-Regression skippt also nie still,
    /// auch auf CI / frischem Checkout.
    @MainActor
    func testDemoModRenderProducesAudio() {
        let mod = ModParser.generateDemoMod()
        let coordinator = ModPlayerCoordinator()
        let samples = coordinator.renderProbe(mod: mod, durationSeconds: 2.0)
        XCTAssertFalse(samples.isEmpty)
        let peak = samples.flatMap { $0.channelOutputs }.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.001, "Demo-Mod muss hoerbares Audio rendern")
    }

    /// Regressionstest fuer die toten BPM-/Speed-Stepper: vor dem Fix hatten
    /// `coordinator.bpm`/`coordinator.speed` keinen `didSet`, der den Wert an den
    /// Echtzeit-Zustand durchreichte. Eine Stepper-Aenderung wurde deshalb nie
    /// wirksam und ausserdem beim naechsten VU-Poll wieder vom Render-Zustand
    /// ueberschrieben. Nach dem Fix muss eine gesetzte BPM/Speed bestehen bleiben,
    /// auch nachdem der VU-Poller mehrfach gelaufen ist.
    @MainActor
    func testTempoSteppersPersistThroughVUPoll() async throws {
        let mod = ModParser.generateDemoMod()
        let coordinator = ModPlayerCoordinator()
        coordinator.setMod(mod)
        coordinator.play()
        XCTAssertTrue(coordinator.isPlaying)

        // Vom Default (125 BPM / Speed 6) bewusst weg auf eindeutige Testwerte.
        coordinator.bpm = 140
        coordinator.speed = 4

        // Laenger warten als ein VU-Poll-Intervall (0,02 s), damit der Poller
        // mehrfach gelaufen ist und einen alten Render-Zustand wieder
        // zurueckschreiben koennte — was er nach dem Fix nicht mehr tut.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.bpm, 140, "Stepper-BPM darf nicht vom VU-Poll ueberschrieben werden")
        XCTAssertEqual(coordinator.speed, 4, "Stepper-Speed darf nicht vom VU-Poll ueberschrieben werden")

        coordinator.stop()
    }

    /// Ein wohlgeformtes Break (D32 = Zeile 32) muss exakt diese Zielzeile
    /// erreichen und NICHT umgelenkt werden.
    @MainActor
    func testInRangePatternBreakReachesTargetRow() throws {
        let mod = try ModParser.parse(data: makeMod(effectId: 0x0D, effectData: 0x32))
        let coordinator = ModPlayerCoordinator()
        let samples = coordinator.renderProbe(mod: mod, durationSeconds: 3.0)
        // Nach dem Break auf Position 0 Row 0 springt der Song auf Position 1,
        // Row 32 — diese Zeile muss in den Proben auftauchen.
        let reached = samples.contains { $0.position == 1 && $0.row == 32 }
        XCTAssertTrue(reached, "D32 muss Position 1 / Row 32 erreichen")
    }
}
