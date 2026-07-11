import XCTest
import AVFoundation
@testable import SavageModPlayerCore

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

    // Ein rein synthetischer Ablauf, der alle fuer IT-003 verpflichtenden
    // Sequencer-Zweige wirklich erreicht: Tempo/Speed/Global Volume, Pattern-
    // Loop, Pattern-Delay sowie kombinierten Position-Jump + Pattern-Break.
    private func makeTraceMod() -> Mod {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        func effect(_ id: Int, _ data: Int) -> Note {
            Note(instrument: 0, period: 0, effectId: id, effectData: data)
        }
        func emptyRow() -> Row { Row(notes: [Note](repeating: empty, count: 4)) }

        let pattern0 = Pattern(rows: [
            Row(notes: [
                effect(0x0F, 3),
                effect(0x0F, 150),
                effect(ModuleEffect.globalVolume, 32),
                effect(0xE6, 0)
            ]),
            Row(notes: [empty, empty, empty, effect(0xE6, 1)]),
            Row(notes: [effect(0xEE, 2), empty, empty, empty]),
            Row(notes: [effect(0x0B, 1), effect(0x0D, 5), empty, empty])
        ])
        let pattern1 = Pattern(rows: (0..<8).map { _ in emptyRow() })
        return Mod(
            name: "sequencer-trace",
            length: 2,
            patternTable: [0, 1],
            instruments: [nil],
            patterns: [pattern0, pattern1],
            channelCount: 4
        )
    }

    // Treibt denselben Block wie App, WAV-Export und Quick Look ohne Engine oder
    // Audiogeraet. Der erste Aufruf rendert Frame 0; danach folgen 256 Frames,
    // sodass die Zustandsgrenzen exakt der bestehenden Probe-Abtastung entsprechen.
    private func renderBlockTraces(
        mod: Mod,
        durationSeconds: Double,
        sampleRate: Double = 44100.0
    ) throws -> [SequencerTraceSnapshot] {
        let channels = ModPlayerCoordinator.makeRenderChannels(for: mod)
        let state = ModPlayerCoordinator.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = 0.8
        state.useInterpolation = true
        state.palClock = true

        let channelCount = channels.count
        let peaks = UnsafeMutablePointer<Float>.allocate(capacity: channelCount)
        defer { peaks.deallocate() }
        peaks.initialize(repeating: 0, count: channelCount)
        let waves = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * 32)
        defer { waves.deallocate() }
        waves.initialize(repeating: 0, count: channelCount * 32)
        let masterWaves = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { masterWaves.deallocate() }
        masterWaves.initialize(repeating: 0, count: 128)

        let block = ModPlayerCoordinator.createRenderBlock(
            state: state,
            vuBuffer: RealtimeVUBuffer(pointer: peaks),
            waveBuffer: RealtimeWaveBuffer(channelWaves: waves, masterWaves: masterWaves),
            dspChannels: channels,
            mod: mod,
            sampleRate: sampleRate
        )
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 256))
        var isSilence = ObjCBool(false)
        var timestamp = AudioTimeStamp()
        let totalFrames = Int(sampleRate * durationSeconds)
        var renderedFrames = 0
        var traces: [SequencerTraceSnapshot] = []

        for frame in stride(from: 0, to: totalFrames, by: 256) {
            let frameCount = frame + 1 - renderedFrames
            pcm.frameLength = AVAudioFrameCount(frameCount)
            let status = block(
                &isSilence,
                &timestamp,
                UInt32(frameCount),
                pcm.mutableAudioBufferList
            )
            XCTAssertEqual(status, noErr)
            renderedFrames += frameCount
            traces.append(SequencerTraceSnapshot(frame: frame, state: state, mod: mod))
        }
        return traces
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

    /// Friert die heutige doppelte Sequencer-Implementierung vor dem Refactor
    /// zustandsgenau ein. Coverage-Marker verhindern, dass zwei wirkungslose
    /// Pfade durch lauter identische Defaultwerte versehentlich bestehen.
    @MainActor
    func testRenderBlockAndProbeProduceIdenticalSequencerTrace() throws {
        let mod = makeTraceMod()
        let duration = 0.6
        let coordinator = ModPlayerCoordinator()
        let probe = coordinator.renderProbe(mod: mod, durationSeconds: duration)
        let blockTraces = try renderBlockTraces(mod: mod, durationSeconds: duration)
        let probeTraces = probe.map(\.trace)

        XCTAssertEqual(probe.map(\.frame), Array(stride(from: 0, to: Int(44100 * duration), by: 256)),
                       "Die bestehende 256-Frame-Abtastung darf sich nicht aendern")
        XCTAssertEqual(blockTraces, probeTraces,
                       "Live-/Offline-Block und Probe muessen elementweise gleich bleiben")

        XCTAssertTrue(probeTraces.contains { $0.speed == 3 }, "F03/Speed nicht erreicht")
        XCTAssertTrue(probeTraces.contains { $0.tempo == 150 }, "F96/Tempo nicht erreicht")
        XCTAssertTrue(probeTraces.contains { $0.globalVolume == 32 }, "Global Volume nicht erreicht")
        XCTAssertTrue(probeTraces.contains { $0.patternLoopRow == 0 }, "E61-Loopziel nicht erreicht")
        XCTAssertTrue(probeTraces.contains { $0.patternDelay == 2 }, "EE2-Delay nicht erreicht")
        XCTAssertTrue(probeTraces.contains { $0.patternDelayCounter > 0 }, "EE2-Counter nicht aktiv")
        XCTAssertTrue(probeTraces.contains { $0.positionJump == 1 }, "B01-Jump nicht vorgemerkt")
        XCTAssertTrue(probeTraces.contains { $0.patternBreak == 5 }, "D05-Break nicht vorgemerkt")
        XCTAssertTrue(probeTraces.contains { $0.position == 1 && $0.pattern == 1 && $0.row == 5 },
                      "B01 und D05 muessen gemeinsam Position 1 / Pattern 1 / Row 5 erreichen")

        // E61 muss den vorgemerkten Wert auch wirklich verbrauchen: Zwischen
        // zwei benachbarten Snapshots geht Position 0 von Row 1 zur Loop-Row 0.
        let adjacentSnapshots = Array(zip(probeTraces, probeTraces.dropFirst()))
        XCTAssertTrue(adjacentSnapshots.contains { before, after in
            before.position == 0 && before.row == 1
                && after.position == 0 && after.row == 0
        }, "E61 muss innerhalb Position 0 tatsaechlich von Row 1 zu Row 0 springen")

        // EE2 erzeugt im heutigen Sequencer exakt drei zusaetzliche Tick-Wraps
        // von 2 auf 0, waehrend Position und Row unveraendert auf 0/2 bleiben.
        // Mit 735 Frames pro Tick liegt zwischen zwei 256-Frame-Snapshots nie
        // mehr als eine Tick-Grenze, daher kann die Abtastung keinen Wrap missen.
        let delayWrapCounters = adjacentSnapshots.compactMap { before, after -> Int? in
            guard before.position == 0, before.row == 2, before.tick == 2,
                  after.position == 0, after.row == 2, after.tick == 0 else { return nil }
            return after.patternDelayCounter
        }
        XCTAssertEqual(delayWrapCounters, [2, 1, 0],
                       "EE2 muss die heutigen drei Row-2-Wiederholungen exakt bewahren")
    }

    /// XM Hxy senkt (bzw. hebt) die globale Lautstärke auf jedem Folgetick der
    /// Zeile; H00 nutzt das Kanal-Memory. Läuft über den echten Render-Block,
    /// damit der SequencerCore-Pfad (Row-Reset + Per-Tick-Anwendung) geprüft ist.
    func testXMGlobalVolumeSlidePerTickWithMemory() throws {
        let empty = Note(instrument: 0, period: 0, effectId: 0, effectData: 0)
        func effect(_ id: Int, _ data: Int) -> Note {
            Note(instrument: 0, period: 0, effectId: id, effectData: data)
        }
        func emptyRow() -> Row { Row(notes: [Note](repeating: empty, count: 4)) }
        var rows: [Row] = [
            Row(notes: [effect(ModuleEffect.globalVolumeSlide, 0x04), empty, empty, empty]),
            Row(notes: [effect(ModuleEffect.globalVolumeSlide, 0x00), empty, empty, empty])
        ]
        rows += (0..<6).map { _ in emptyRow() }
        let mod = Mod(
            name: "hxy",
            length: 1,
            patternTable: [0],
            instruments: [nil],
            patterns: [Pattern(rows: rows)],
            channelCount: 4,
            format: .xm,
            linearFrequency: true
        )
        let traces = try renderBlockTraces(mod: mod, durationSeconds: 0.5)
        let afterRow0 = try XCTUnwrap(traces.first { $0.row == 1 })
        XCTAssertEqual(afterRow0.globalVolume, 44,
                       "H04 muss auf den fünf Folgeticks von Row 0 je 4 abziehen")
        let afterRow1 = try XCTUnwrap(traces.first { $0.row == 2 })
        XCTAssertEqual(afterRow1.globalVolume, 24,
                       "H00 muss den gemerkten 04-Parameter weiterverwenden")
        XCTAssertEqual(try XCTUnwrap(traces.last).globalVolume, 24,
                       "ohne weiteren H-Befehl bleibt die globale Lautstärke stehen")
    }
}
