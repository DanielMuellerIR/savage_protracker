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

    // MARK: - XM lineares Frequenzmodell (M2)

    /// Lineare Periodenformel: C-4 (realNote 48) ohne Finetune -> Periode 4608.
    func testXMLinearPeriodReference() {
        XCTAssertEqual(DSPChannel.xmLinearPeriod(realNote: 48, finetune: 0), 4608, accuracy: 0.001)
        // Eine Oktave höher (realNote 60) -> 64 Einheiten pro Halbton * 12 = 768
        // weniger.
        XCTAssertEqual(DSPChannel.xmLinearPeriod(realNote: 60, finetune: 0), 3840, accuracy: 0.001)
        // Finetune -128 hebt die Periode um 64 (‑128/2), +127 senkt um 63.5.
        XCTAssertEqual(DSPChannel.xmLinearPeriod(realNote: 48, finetune: -128), 4672, accuracy: 0.001)
        XCTAssertEqual(DSPChannel.xmLinearPeriod(realNote: 48, finetune: 127), 4544.5, accuracy: 0.001)
    }

    /// Im xmLinearMode muss die Abspielfrequenz exponentiell sein: C-4 -> 8363 Hz,
    /// eine Oktave höher -> 16726 Hz. sampleSpeed = Hz / sampleRate.
    func testXMLinearFrequencyIsExponential() {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        ch.periodMin = 1
        ch.periodMax = 7680

        ch.period = 4608
        ch.currentPeriod = 4608
        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.sampleSpeed, 8363.0 / sampleRate, accuracy: 1e-6, "C-4 muss 8363 Hz ergeben")

        ch.period = 3840
        ch.currentPeriod = 3840
        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.sampleSpeed, 16726.0 / sampleRate, accuracy: 1e-6, "Oktave höher = doppelte Frequenz")
    }

    /// playNote muss im xmLinearMode Key + Sample-relativeNote + Finetune zur
    /// Periode verrechnen (nicht das S3M-Modell nutzen).
    func testXMPlayNoteUsesLinearPeriodWithRelativeNote() {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        ch.periodMin = 1
        ch.periodMax = 7680
        // Sample mit relativeNote +12 (eine Oktave hoch) und Finetune 0.
        let smp = Sample(pcm: [0.1, 0.2, 0.3], loopStart: 0, loopLength: 0,
                         loopType: .none, volume: 64, finetune: 0, relativeNote: 12)
        let inst = Instrument(index: 1, name: "XM", samples: [smp])
        // Note C-4 (key 48) + relativeNote 12 -> realNote 60 -> Periode 3840.
        ch.playNote(Note(instrument: 1, period: 0, effectId: 0, effectData: 0, key: 48),
                    instruments: [nil, inst])
        XCTAssertEqual(ch.period, 3840, accuracy: 0.001)
    }

    /// Key-Off (Note 97 / Note.keyOff) setzt keyReleased und retriggert die Note
    /// nicht (Sample-Position/Periode unverändert). Ohne Volume-Hüllkurve stoppt der
    /// Ton nach FT2-Quirk sofort, MIT Hüllkurve läuft er (Fadeout) weiter.
    func testXMKeyOffWithoutVolumeEnvelopeStopsImmediately() {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        // Instrument OHNE Volume-Hüllkurve.
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)])
        ch.instrument = inst
        ch.period = 4608
        ch.currentPeriod = 4608
        ch.sampleIndex = 100
        ch.playing = true
        ch.playNote(Note(instrument: 0, period: 0, effectId: 0, effectData: 0, key: Note.keyOff),
                    instruments: [nil])
        XCTAssertTrue(ch.keyReleased)
        XCTAssertFalse(ch.playing, "Key-Off ohne Volume-Hüllkurve stoppt sofort (FT2-Quirk)")
        XCTAssertEqual(ch.sampleIndex, 100, "Key-Off darf das Sample nicht neu starten")
        XCTAssertEqual(ch.period, 4608, accuracy: 0.001)
    }

    /// Mit aktiver Volume-Hüllkurve läuft Key-Off als Fadeout weiter (Ton bleibt
    /// zunächst spielend), und der Fadeout senkt fadeVolume pro Tick.
    func testXMKeyOffWithVolumeEnvelopeFadesOut() {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        let env = Envelope(points: [EnvelopePoint(frame: 0, value: 64)],
                           sustainPoint: 0, loopStart: 0, loopEnd: 0,
                           sustainEnabled: false, loopEnabled: false)
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)],
                              volumeEnvelope: env, fadeout: 4096)
        ch.instrument = inst
        ch.period = 4608
        ch.currentPeriod = 4608
        ch.fadeVolume = 65536
        ch.playing = true
        ch.playNote(Note(instrument: 0, period: 0, effectId: 0, effectData: 0, key: Note.keyOff),
                    instruments: [nil])
        XCTAssertTrue(ch.keyReleased)
        XCTAssertTrue(ch.playing, "Key-Off mit Volume-Hüllkurve fadet aus, stoppt nicht sofort")
        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.fadeVolume, 65536 - 4096, "Fadeout senkt fadeVolume pro Tick um instrument.fadeout")
        XCTAssertLessThan(ch.xmVolumeScale, 1.0, "xmVolumeScale sinkt mit dem Fadeout")
    }

    /// Die Volume-Hüllkurve wird pro Tick linear zwischen den Punkten interpoliert
    /// (Punkte (0,64)->(4,0): fällt in 4 Ticks von voll auf null).
    func testXMVolumeEnvelopeInterpolates() {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        ch.periodMin = 1
        ch.periodMax = 7680
        let env = Envelope(points: [EnvelopePoint(frame: 0, value: 64), EnvelopePoint(frame: 4, value: 0)],
                           sustainPoint: 0, loopStart: 0, loopEnd: 0,
                           sustainEnabled: false, loopEnabled: false)
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2, 0.3], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)],
                              volumeEnvelope: env)
        ch.playNote(Note(instrument: 1, period: 0, effectId: 0, effectData: 0, key: 48),
                    instruments: [nil, inst])
        XCTAssertEqual(ch.envVolumeFactor, 1.0, accuracy: 1e-5, "Startwert Tick 0")
        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate) // liest pos0=64, steppt auf 1
        XCTAssertEqual(ch.envVolumeFactor, 1.0, accuracy: 1e-5)
        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate) // pos1 -> 48/64
        XCTAssertEqual(ch.envVolumeFactor, 48.0 / 64.0, accuracy: 1e-5)
        ch.performTick(tick: 2, sampleRate: sampleRate, clockRate: clockRate) // pos2 -> 32/64
        XCTAssertEqual(ch.envVolumeFactor, 0.5, accuracy: 1e-5)
    }

    // MARK: - XM Volume-Column + Effekte (M4)

    private func makeXMChannel() -> DSPChannel {
        let ch = DSPChannel(index: 1)
        ch.xmLinearMode = true
        ch.periodMin = 1
        ch.periodMax = 7680
        return ch
    }

    /// Volume-Column Set Volume (0x10..0x50) setzt die Lautstärke direkt.
    func testXMVolumeColumnSetVolume() {
        let ch = makeXMChannel()
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)])
        // volCmd 0x40 -> Volume 48.
        ch.playNote(Note(instrument: 1, period: 0, effectId: 0, effectData: 0, key: 48, volCmd: 0x40),
                    instruments: [nil, inst])
        XCTAssertEqual(ch.volume, 48, accuracy: 0.001, "Volume-Column 0x40 -> Volume 48")
    }

    /// Volume-Column Vol-Slide up (0x70..0x7F) gleitet ab Tick 1.
    func testXMVolumeColumnVolumeSlide() {
        let ch = makeXMChannel()
        ch.volume = 32
        ch.currentVolume = 32
        // volCmd 0x73 -> +3 pro Tick.
        ch.playNote(Note(instrument: 0, period: 0, effectId: 0, effectData: 0, volCmd: 0x73),
                    instruments: [nil])
        ch.performTick(tick: 0, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentVolume, 32, accuracy: 0.001, "Tick 0: kein Slide")
        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertEqual(ch.currentVolume, 35, accuracy: 0.001, "Tick 1: +3")
    }

    /// XM 1xx nutzt Effekt-Memory: 100 wiederholt den letzten 1xx-Parameter.
    /// Starfish Row 60..63 im ersten Pattern ist 105,100,100,100; ohne Memory
    /// steigt die Tonhöhe nur eine Row und bleibt dann hörbar falsch stehen.
    func testXMPortaUpZeroReusesPreviousParameter() {
        let ch = makeXMChannel()
        ch.period = 4608
        ch.currentPeriod = 4608

        ch.playNote(Note(instrument: 0, period: 0, effectId: 0x01, effectData: 0x05),
                    instruments: [nil])
        playRow(ch, ticksPerRow: 4)
        XCTAssertEqual(ch.currentPeriod, 4548, accuracy: 0.001,
                       "105: XM-Slide-Up macht bei Speed 4 drei Schritte à 5*4")

        ch.playNote(Note(instrument: 0, period: 0, effectId: 0x01, effectData: 0x00),
                    instruments: [nil])
        playRow(ch, ticksPerRow: 4)
        XCTAssertEqual(ch.currentPeriod, 4488, accuracy: 0.001,
                       "100 muss den gespeicherten 05-Parameter weiterverwenden")
    }

    /// XM A00 wiederholt analog den letzten Axy-Parameter. Das verhindert, dass
    /// kombinierte FT2-Volume-Slide-Folgen nach einer Row abbrechen.
    func testXMVolumeSlideZeroReusesPreviousParameter() {
        let ch = makeXMChannel()
        ch.volume = 32
        ch.currentVolume = 32

        ch.playNote(Note(instrument: 0, period: 0, effectId: 0x0A, effectData: 0x20),
                    instruments: [nil])
        playRow(ch, ticksPerRow: 4)
        XCTAssertEqual(ch.currentVolume, 38, accuracy: 0.001)

        ch.playNote(Note(instrument: 0, period: 0, effectId: 0x0A, effectData: 0x00),
                    instruments: [nil])
        playRow(ch, ticksPerRow: 4)
        XCTAssertEqual(ch.currentVolume, 44, accuracy: 0.001,
                       "A00 muss den gespeicherten A20-Parameter weiterverwenden")
    }

    /// XM Rxy: Retrigger alle y Ticks verändert die Lautstärke nach der
    /// FT2-Modus-Tabelle (Modus 1 = -1 je Retrigger); R00 nutzt das getrennte
    /// Nibble-Memory. MOD E9x retriggt dagegen ohne Volume-Änderung.
    func testXMMultiRetrigAppliesVolumeModeAndMemory() {
        let ch = makeXMChannel()
        ch.volume = 32
        ch.currentVolume = 32

        // R12: Modus 1 (-1), Intervall 2 → bei Speed 6 Retrigger auf Tick 2 und 4.
        ch.playNote(Note(instrument: 0, period: 0,
                         effectId: ModuleEffect.multiRetrig, effectData: 0x12),
                    instruments: [nil])
        ch.playing = true
        playRow(ch, ticksPerRow: 6)
        XCTAssertEqual(ch.currentVolume, 30, accuracy: 0.001,
                       "R12 muss zweimal retriggen und je -1 anwenden")

        // R00 muss beide gemerkten Nibbles (Modus 1, Intervall 2) weiterverwenden.
        ch.playNote(Note(instrument: 0, period: 0,
                         effectId: ModuleEffect.multiRetrig, effectData: 0x00),
                    instruments: [nil])
        ch.playing = true
        playRow(ch, ticksPerRow: 6)
        XCTAssertEqual(ch.currentVolume, 28, accuracy: 0.001,
                       "R00 muss den gespeicherten R12-Parameter weiterverwenden")

        // MOD E9x nutzt denselben Retrigger-Mechanismus, darf die Lautstärke
        // aber nicht verändern.
        let modChannel = DSPChannel(index: 0)
        modChannel.volume = 32
        modChannel.currentVolume = 32
        modChannel.playNote(Note(instrument: 0, period: 0,
                                 effectId: 0xE9, effectData: 2),
                            instruments: [nil])
        modChannel.playing = true
        playRow(modChannel, ticksPerRow: 6)
        XCTAssertEqual(modChannel.currentVolume, 32, accuracy: 0.001,
                       "E92 retriggt ohne Volume-Änderung")
    }

    /// Volume-Column Set Panning (0xC0..0xCF) setzt das Panorama (y<<4)/255.
    func testXMVolumeColumnSetPanning() {
        let ch = makeXMChannel()
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)])
        // volCmd 0xC8 -> Panning (8<<4)/255 = 128/255.
        ch.playNote(Note(instrument: 1, period: 0, effectId: 0, effectData: 0, key: 48, volCmd: 0xC8),
                    instruments: [nil, inst])
        XCTAssertEqual(ch.panning, 128.0 / 255.0, accuracy: 0.001)
    }

    /// XM Kxx (Effekt-Spalte) mit Tick-Parameter löst Key-Off auf dem Tick aus.
    func testXMKeyOffEffectAtTick() {
        let ch = makeXMChannel()
        let env = Envelope(points: [EnvelopePoint(frame: 0, value: 64)],
                           sustainPoint: 0, loopStart: 0, loopEnd: 0,
                           sustainEnabled: false, loopEnabled: false)
        let inst = Instrument(index: 1, name: "X",
                              samples: [Sample(pcm: [0.1, 0.2], loopStart: 0, loopLength: 0,
                                               loopType: .none, volume: 64, finetune: 0)],
                              volumeEnvelope: env, fadeout: 2048)
        ch.instrument = inst
        // K02 (ModuleEffect.keyOff, Param 2) -> Key-Off auf Tick 2.
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.keyOff, effectData: 2),
                    instruments: [nil])
        XCTAssertFalse(ch.keyReleased, "vor Tick 2 noch nicht losgelassen")
        ch.performTick(tick: 1, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertFalse(ch.keyReleased)
        ch.performTick(tick: 2, sampleRate: sampleRate, clockRate: clockRate)
        XCTAssertTrue(ch.keyReleased, "Tick 2: Kxx löst Key-Off aus")
    }
}
