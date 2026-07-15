import XCTest
@testable import SavageModPlayerCore

// Tests für die neuen Modul-Formate: Multichannel-MOD-Varianten (6CHN/8CHN/
// xxCH/FLT8), 15-Sample-Soundtracker und ScreamTracker 3 (S3M) — plus den
// Offline-WAV-Renderer, den das Quick-Look-Plugin nutzt.
final class MultiFormatTests: XCTestCase {

    // MARK: - Hilfen: synthetische Moduldateien

    // Minimales 31-Instrument-MOD mit gegebener Signatur und einem Pattern.
    private func makeMultichannelMod(signature: String, channels: Int) -> Data {
        let patternBytes = 64 * channels * 4
        var data = Data(repeating: 0, count: 1084 + patternBytes)
        data.replaceSubrange(0..<4, with: Data("Test".utf8))
        data[950] = 1 // Songlaenge
        data[952] = 0 // Playlist: Pattern 0
        data.replaceSubrange(1080..<1084, with: Data(signature.utf8))

        // Row 0: Note auf Kanal 1 (Period 428, Instrument 1) und auf dem
        // LETZTEN Kanal (Period 214) — verifiziert den Row-Stride.
        data[1084] = 0x01
        data[1085] = 0xAC // 0x1AC = 428
        data[1086] = 0x10
        let lastChannelOffset = 1084 + (channels - 1) * 4
        data[lastChannelOffset] = 0x00
        data[lastChannelOffset + 1] = 0xD6 // 0x0D6 = 214
        return data
    }

    func test6CHNParsesWithSixChannels() throws {
        let mod = try ModParser.parse(data: makeMultichannelMod(signature: "6CHN", channels: 6))
        XCTAssertEqual(mod.channelCount, 6)
        XCTAssertEqual(mod.format, .multichannel)
        XCTAssertEqual(mod.patterns[0].rows.count, 64)
        XCTAssertEqual(mod.patterns[0].rows[0].notes.count, 6)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[0].period, 428)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[5].period, 214)
        // LRRL-Panning wird periodisch fortgesetzt
        XCTAssertEqual(mod.channelPannings.count, 6)
        XCTAssertEqual(mod.channelPannings[4], 0.1, accuracy: 0.001)
    }

    func test8CHNAndCD81ParseWithEightChannels() throws {
        for sig in ["8CHN", "CD81", "OKTA"] {
            let mod = try ModParser.parse(data: makeMultichannelMod(signature: sig, channels: 8))
            XCTAssertEqual(mod.channelCount, 8, "Signatur \(sig)")
            XCTAssertEqual(mod.patterns[0].rows[0].notes[7].period, 214, "Signatur \(sig)")
        }
    }

    func testSixteenChannelSignatureParses() throws {
        let mod = try ModParser.parse(data: makeMultichannelMod(signature: "16CH", channels: 16))
        XCTAssertEqual(mod.channelCount, 16)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[15].period, 214)
    }

    func testFLT8CombinesPatternPairs() throws {
        // FLT8: zwei GESPEICHERTE 4-Kanal-Patterns bilden EIN logisches
        // 8-Kanal-Pattern; Playlist-Eintraege sind halbiert zu lesen.
        var data = Data(repeating: 0, count: 1084 + 2 * 1024)
        data[950] = 1
        data[952] = 0
        data.replaceSubrange(1080..<1084, with: Data("FLT8".utf8))
        // Stored Pattern 0 (Kanal 1-4), Row 0 Kanal 1: Period 428
        data[1084] = 0x01
        data[1085] = 0xAC
        // Stored Pattern 1 (Kanal 5-8), Row 0 Kanal 1 -> logischer Kanal 5: 214
        data[1084 + 1024] = 0x00
        data[1084 + 1024 + 1] = 0xD6

        let mod = try ModParser.parse(data: data)
        XCTAssertEqual(mod.channelCount, 8)
        XCTAssertEqual(mod.format, .multichannel)
        XCTAssertEqual(mod.patterns.count, 1)
        XCTAssertEqual(mod.patterns[0].rows[0].notes.count, 8)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[0].period, 428)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[4].period, 214)
    }

    func testSoundtracker15Heuristic() throws {
        // Ur-Soundtracker: 15 Instrumente, KEINE Signatur, Patterns ab 600.
        var data = Data(repeating: 0, count: 600 + 1024)
        data.replaceSubrange(0..<9, with: Data("OLDSCHOOL".utf8))
        // Instrument 1: Laenge 2 Words (4 Bytes), Volume 64, Loop 2 Words
        data[42] = 0x00; data[43] = 0x02
        data[45] = 64
        data[48] = 0x00; data[49] = 0x02
        data[470] = 1   // Songlaenge
        data[471] = 120 // Restart-Byte (typisch fuer alte Tracker)
        // Pattern 0, Row 0, Kanal 1: Period 428, Instrument 1
        data[600] = 0x01
        data[601] = 0xAC
        data[602] = 0x10

        let mod = try ModParser.parse(data: data)
        XCTAssertEqual(mod.format, .soundtracker)
        XCTAssertEqual(mod.channelCount, 4)
        XCTAssertEqual(mod.instruments.count, 16) // nil + 15
        XCTAssertEqual(mod.instruments[1]?.primarySample?.volume, 64)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[0].period, 428)
        XCTAssertEqual(mod.patterns[0].rows[0].notes[0].instrument, 1)
    }

    func testGarbageWithoutSignatureStillRejected() {
        // Beliebige Binaerdaten ohne Signatur duerfen NICHT als
        // 15-Sample-Soundtracker durchgehen (Volume-Plausibilitaet reisst).
        var data = Data(repeating: 0xEE, count: 4096)
        data.replaceSubrange(1080..<1084, with: Data("XYZ!".utf8))
        XCTAssertThrowsError(try ModParser.parse(data: data))
    }

    // MARK: - S3M

    // Baut ein minimales, gueltiges S3M: 2 aktive Kanaele (L/R), 1 Instrument
    // (4 Samples, unsigned), 1 Pattern mit Note+Volume+Effekt, Orders [0, --].
    private func makeS3M() -> Data {
        var data = Data(repeating: 0, count: 0x104)
        data.replaceSubrange(0..<8, with: Data("S3M TEST".utf8))
        data[0x1C] = 0x1A
        data[0x1D] = 16          // Typ: Modul
        data[0x20] = 2           // ordNum
        data[0x22] = 1           // insNum
        data[0x24] = 1           // patNum
        data[0x2A] = 2           // ffi: unsigned Samples
        data.replaceSubrange(0x2C..<0x30, with: Data("SCRM".utf8))
        data[0x30] = 48          // Global Volume
        data[0x31] = 5           // Initial Speed
        data[0x32] = 150         // Initial Tempo
        data[0x33] = 0x80 | 48   // Master Volume, Bit 7 = Stereo
        // Kanal-Settings: Kanal 0 = L1, Kanal 1 = R1, Rest unbenutzt
        data[0x40] = 0
        data[0x41] = 8
        for i in 2..<32 { data[0x40 + i] = 255 }
        // Orders: Pattern 0, dann Ende-Marker
        data[0x60] = 0
        data[0x61] = 255
        // Instrument-Parapointer -> 0x70, Pattern-Parapointer -> 0xD0
        data[0x62] = 0x07
        data[0x64] = 0x0D

        // Instrument bei 0x70: Typ 1, Sample bei 0x100 (memseg 0x10), 4 Bytes
        data[0x70] = 1
        data[0x7E] = 0x10        // memseg low word -> 0x10 * 16 = 0x100
        data[0x80] = 4           // Laenge
        data[0x8C] = 64          // Volume
        data[0x90] = 0xAB        // c2spd = 0x20AB = 8363
        data[0x91] = 0x20
        data.replaceSubrange(0xBC..<0xC0, with: Data("SCRS".utf8)) // 0x70 + 0x4C

        // Pattern bei 0xD0: Row 0 mit Note C-4/Inst 1/Vol 32/Effekt A03 auf
        // Kanal 0. Row 1 enthält D00 (präsent trotz Nullparameter), Row 2
        // eine Note ohne Effekt; danach bleiben die Rows leer.
        var p = 0xD0
        data[p] = 0x30; p += 1   // gepackte Laenge (unbenutzt beim Lesen)
        data[p] = 0x00; p += 1
        data[p] = 0xE0; p += 1   // what: Kanal 0 + Note/Inst + Vol + Cmd
        data[p] = 0x40; p += 1   // Note: Oktave 4, C -> Key 48
        data[p] = 0x01; p += 1   // Instrument 1
        data[p] = 32; p += 1     // Volume-Column
        data[p] = 0x01; p += 1   // Cmd A (Set Speed)
        data[p] = 0x03; p += 1   // Info 3
        data[p] = 0x00; p += 1   // Ende Row 0
        data[p] = 0xA0; p += 1   // Row 1: Kanal 0 + Note/Inst + Cmd
        data[p] = 0x40; p += 1   // C-4
        data[p] = 0x01; p += 1   // Instrument 1
        data[p] = 0x04; p += 1   // Cmd D (Volume Slide)
        data[p] = 0x00; p += 1   // D00
        data[p] = 0x00; p += 1   // Ende Row 1
        data[p] = 0x20; p += 1   // Row 2: nur Note/Instrument
        data[p] = 0x40; p += 1
        data[p] = 0x01; p += 1
        data[p] = 0x00; p += 1   // Ende Row 2
        // Rows 3..63 leer (Nullbytes reichen)

        // Sampledaten bei 0x100 (unsigned)
        data[0x100] = 0x80
        data[0x101] = 0xFF
        data[0x102] = 0x80
        data[0x103] = 0x00
        return data
    }

    func testS3MParsing() throws {
        let mod = try S3MParser.parse(data: makeS3M())
        XCTAssertEqual(mod.name, "S3M TEST")
        XCTAssertEqual(mod.format, .s3m)
        XCTAssertEqual(mod.channelCount, 2)
        XCTAssertEqual(mod.length, 1) // 255-Marker gefiltert
        XCTAssertEqual(mod.initialSpeed, 5)
        XCTAssertEqual(mod.initialTempo, 150)
        XCTAssertEqual(mod.initialGlobalVolume, 48)
        // Stereo-Defaults: L/R
        XCTAssertEqual(mod.channelPannings[0], 0.2, accuracy: 0.001)
        XCTAssertEqual(mod.channelPannings[1], 0.8, accuracy: 0.001)

        // Instrument: c2spd + unsigned->signed-Wandlung (jetzt als normalisierter
        // Float, int8/256 — 0x80,0xFF,0x80,0x00 unsigned -> 0,127,0,-128 signed).
        let inst = try XCTUnwrap(mod.instruments[1])
        let smp = try XCTUnwrap(inst.primarySample)
        XCTAssertEqual(smp.c2spd, 8363)
        XCTAssertEqual(smp.volume, 64)
        XCTAssertEqual(smp.pcm, [0, Float(127) / 256, 0, Float(-128) / 256])

        // Note: Key, Volume-Column, uebersetzter Effekt
        let note = mod.patterns[0].rows[0].notes[0]
        XCTAssertEqual(note.key, 48)
        XCTAssertEqual(note.instrument, 1)
        XCTAssertEqual(note.volume, 32)
        XCTAssertEqual(note.effectId, ModuleEffect.setSpeed)
        XCTAssertEqual(note.effectData, 3)
        XCTAssertEqual(note.effectPresent, true)

        let d00 = mod.patterns[0].rows[1].notes[0]
        XCTAssertEqual(d00.effectId, ModuleEffect.volumeSlideS3M)
        XCTAssertEqual(d00.effectData, 0)
        XCTAssertEqual(d00.effectPresent, true)
        XCTAssertTrue(d00.hasEffect)

        let noEffect = mod.patterns[0].rows[2].notes[0]
        XCTAssertEqual(noEffect.effectPresent, false)
        XCTAssertFalse(noEffect.hasEffect)

        let empty = mod.patterns[0].rows[3].notes[0]
        XCTAssertNil(empty.effectPresent)
        XCTAssertFalse(empty.hasEffect)
    }

    func testModuleLoaderDispatch() throws {
        // ModuleLoader erkennt S3M am SCRM-Header, MOD an der Signatur.
        XCTAssertEqual(try ModuleLoader.parse(data: makeS3M()).format, .s3m)
        let modData = makeMultichannelMod(signature: "M.K.", channels: 4)
        XCTAssertEqual(try ModuleLoader.parse(data: modData).format, .protracker)
    }

    // MARK: - S3M-DSP

    func testS3MPeriodFormula() {
        // C-4 bei Standard-C2Spd 8363 ist die ST3-Referenzperiode 1712.
        XCTAssertEqual(DSPChannel.s3mPeriod(key: 48, c2spd: 8363), 1712, accuracy: 0.5)
        // Eine Oktave hoeher halbiert die Periode.
        XCTAssertEqual(DSPChannel.s3mPeriod(key: 60, c2spd: 8363), 856, accuracy: 0.5)
        // Doppelte Abspielrate halbiert ebenfalls.
        XCTAssertEqual(DSPChannel.s3mPeriod(key: 48, c2spd: 16726), 856, accuracy: 0.5)
    }

    private func makeS3MChannel() -> DSPChannel {
        let ch = DSPChannel(index: 1)
        ch.s3mMode = true
        ch.periodScale = 4
        ch.periodMin = 64
        ch.periodMax = 32767
        return ch
    }

    func testS3MVolumeSlideUsesSharedMemory() {
        let ch = makeS3MChannel()
        ch.volume = 32
        ch.currentVolume = 32

        // D21: x=2 -> Slide up 2 pro Tick (> 0)
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.volumeSlideS3M, effectData: 0x20), instruments: [nil])
        ch.performTick(tick: 1, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentVolume, 34, accuracy: 0.001)

        // D00: Parameter 0 -> Memory wiederholt den letzten Slide
        ch.volume = ch.currentVolume
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.volumeSlideS3M, effectData: 0x00), instruments: [nil])
        ch.performTick(tick: 1, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentVolume, 36, accuracy: 0.001)
    }

    func testS3MFineVolumeSlideAppliesOnce() {
        let ch = makeS3MChannel()
        ch.volume = 32
        ch.currentVolume = 32
        // D3F: Fine-Slide up 3 — einmalig beim Row-Start, nicht pro Tick.
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.volumeSlideS3M, effectData: 0x3F), instruments: [nil])
        XCTAssertEqual(ch.volume, 35, accuracy: 0.001)
        let after = ch.currentVolume
        ch.performTick(tick: 1, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentVolume, after, accuracy: 0.001)
    }

    func testS3MPortamentoScalesTimesFour() {
        let ch = makeS3MChannel()
        ch.period = 1712
        ch.currentPeriod = 1712
        // F08: Porta up um 8*4 = 32 Perioden-Einheiten pro Tick > 0.
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.portaUpS3M, effectData: 0x08), instruments: [nil])
        ch.performTick(tick: 0, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentPeriod, 1712, accuracy: 0.001) // Tick 0: kein Slide
        ch.performTick(tick: 1, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentPeriod, 1680, accuracy: 0.001)
    }

    func testS3MFinePortaAppliesOnceAndAudibly() {
        let ch = makeS3MChannel()
        ch.period = 1712
        ch.currentPeriod = 1712
        ch.playing = true
        // FF2: Fine-Porta up 2*4 = 8 Einheiten, einmalig auf Tick 0.
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.portaUpS3M, effectData: 0xF2), instruments: [nil])
        XCTAssertEqual(ch.period, 1704, accuracy: 0.001)
        // Ohne anstehende Note muss auch currentPeriod sofort folgen.
        XCTAssertEqual(ch.currentPeriod, 1704, accuracy: 0.001)
        ch.performTick(tick: 1, sampleRate: 44100, clockRate: 14317056)
        XCTAssertEqual(ch.currentPeriod, 1704, accuracy: 0.001) // kein weiterer Slide
    }

    func testTremorGatesVolume() {
        let ch = makeS3MChannel()
        ch.volume = 64
        ch.currentVolume = 64
        // I11: 2 Ticks an, 2 Ticks aus.
        ch.playNote(Note(instrument: 0, period: 0, effectId: ModuleEffect.tremor, effectData: 0x11), instruments: [nil])
        var pattern: [Float] = []
        for t in 0..<4 {
            ch.performTick(tick: t, sampleRate: 44100, clockRate: 14317056)
            pattern.append(ch.currentVolume)
        }
        XCTAssertEqual(pattern, [64, 64, 0, 0])
    }

    func testS3MNoteCutStopsSample() {
        let ch = makeS3MChannel()
        ch.playing = true
        ch.playNote(Note(instrument: 0, period: 0, effectId: 0, effectData: 0, key: Note.keyCut), instruments: [nil])
        XCTAssertFalse(ch.playing)
    }

    func testVolumeColumnOverridesInstrumentDefault() {
        let ch = makeS3MChannel()
        let inst = Instrument(index: 1, name: "T", length: 4, finetune: 0, volume: 64,
                              repeatOffset: 0, repeatLength: 0, bytes: [10, 20, 30, 40],
                              isLooped: false, c2spd: 8363)
        ch.playNote(Note(instrument: 1, period: 0, effectId: 0, effectData: 0, key: 48, volume: 20), instruments: [nil, inst])
        XCTAssertEqual(ch.volume, 20, accuracy: 0.001)
        // Und die Periode kommt aus Key + C2Spd.
        XCTAssertEqual(ch.period, 1712, accuracy: 0.5)
    }

    // Braucht die AVAudioEngine-gebundene Live-Klasse — entfällt unter Linux.
#if canImport(AVFoundation) && canImport(Combine)
    // Optionaler Realwelt-Test: parst alle .s3m rekursiv aus audio/
    // (gitignoriert, lokal) und rendert je 2 Sekunden — es muss hoerbares
    // Signal entstehen.
    @MainActor
    func testRealS3MFilesParseAndRender() throws {
        let audioDirPath = "audio"
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioDirPath) else { return }
        let root = URL(fileURLWithPath: audioDirPath, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let s3mFiles = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "s3m",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        guard !s3mFiles.isEmpty else { return }

        for url in s3mFiles {
            let fileName = url.lastPathComponent
            let mod = try ModuleLoader.parse(data: Data(contentsOf: url))
            XCTAssertEqual(mod.format, .s3m, fileName)
            XCTAssertGreaterThan(mod.length, 0, fileName)
            XCTAssertGreaterThan(mod.channelCount, 0, fileName)

            let coordinator = ModPlayerCoordinator()
            let probes = coordinator.renderProbe(mod: mod, durationSeconds: 2.0)
            let peak = probes.flatMap { $0.channelOutputs }.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "\(fileName) rendert nur Stille")

            // Zusaetzlich den ECHTEN Quick-Look-Pfad pruefen: die gerenderte
            // WAV muss hoerbares Signal enthalten (nicht nur RIFF-Header).
            let wav = try ModuleRenderer.renderWavData(mod: mod, maxDurationSeconds: 5.0)
            let payload = wav.subdata(in: 44..<wav.count)
            let wavPeak = payload.withUnsafeBytes { buf -> Int in
                buf.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0
            }
            // Nach Peak-Normalisierung muss die Vorschau ordentlich
            // ausgesteuert sein (Ziel ~29000, Toleranz fuer Gain-Deckel).
            XCTAssertGreaterThan(wavPeak, 8000, "\(fileName): WAV (Quick-Look-Pfad) ist zu leise")
            print("✓ S3M geparst + gerendert: \(fileName) (\"\(mod.name)\"), \(mod.channelCount) Kanäle, Probe-Peak \(peak), WAV-Peak \(wavPeak), WAV \(wav.count) Bytes")
        }
    }
#endif

    // MARK: - Instrument-Vorschau (eigener Render-Pfad, previewInstrument)

    func testITPreviewUsesC5SpeedAtNativePitch() {
        let sample = Sample(
            pcm: [0.25], loopStart: 0, loopLength: 0, loopType: .none,
            volume: 64, finetune: 0,
            itProperties: ITSampleProperties(c5Speed: 44_100, globalVolume: 64, defaultPanning: nil)
        )

        XCTAssertEqual(
            RenderEngine.itPreviewSampleSpeed(
                sample: sample, targetNote: 60, linearFrequency: true, sampleRate: 44_100
            ),
            1.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RenderEngine.itPreviewSampleSpeed(
                sample: sample, targetNote: 72, linearFrequency: true, sampleRate: 44_100
            ),
            2.0,
            accuracy: 0.000_001
        )
    }

    // Der Preview-Render-Block muss (a) hoerbares Signal liefern, solange das
    // Frame-Budget laeuft, und (b) danach exakt Stille — sonst wuerde ein
    // gelooptes Instrument endlos droehnen. Laeuft rein rechnerisch ueber einen
    // Float-Stereopuffer, ohne echtes Audiogeraet.
    func testPreviewRenderBlockProducesSignalThenSilence() throws {
        // Konstantes, nicht-gelooptes Sample: jeder gueltige Index liefert Signal.
        let inst = Instrument(index: 1, name: "P", length: 64, finetune: 0, volume: 64,
                              repeatOffset: 0, repeatLength: 0,
                              bytes: [Int8](repeating: 50, count: 64),
                              isLooped: false, c2spd: 8363)
        let ch = DSPChannel(index: 1)
        ch.instrument = inst
        // Renderer liest jetzt ch.sample (Float-PCM) — beim manuellen Kanal-Setup
        // mitsetzen, wie es playNote/previewInstrument im echten Pfad tun.
        ch.sample = inst.primarySample
        ch.volume = 64
        ch.currentVolume = 64
        ch.period = 214
        ch.currentPeriod = 214
        ch.sampleIndex = 0.0
        ch.sampleSpeed = 0.375 // ~ 3546894.6 / 214 / 44100 (MOD/PAL-Takt)
        ch.playing = true

        let budget = 40
        let voice = PreviewVoice(framesLeft: budget)
        let block = RenderEngine.createPreviewRenderBlock(
            channel: ch, voice: voice, useInterpolation: false)

        let frames: UInt32 = 128
        let buffer = StereoRenderBuffer(capacity: Int(frames))
        block(frames, buffer.left, buffer.right)

        let left = buffer.left
        let right = buffer.right
        // Innerhalb des Budgets: Signal, und mittig (L == R).
        for i in 0..<budget {
            XCTAssertGreaterThan(abs(left[i]), 0.01, "Frame \(i) sollte Signal tragen")
            XCTAssertEqual(left[i], right[i], accuracy: 0.0, "mittig gepannt")
        }
        // Nach dem Budget: exakt Stille.
        for i in budget..<Int(frames) {
            XCTAssertEqual(left[i], 0.0, "Frame \(i) nach Budget muss still sein")
        }
    }

    // Ein gestoppter Kanal darf auch bei einem geloopten Sample nichts mehr
    // ausgeben. Der Preview-Block ruft dafuer denselben privaten Sample-Renderer
    // wie Live-, Probe- und Offline-Wiedergabe auf, braucht aber kein Audiogeraet.
    func testStoppedLoopedSampleRendersSilence() throws {
        let inst = Instrument(index: 1, name: "Loop", length: 8, finetune: 0, volume: 64,
                              repeatOffset: 2, repeatLength: 4,
                              bytes: [Int8](repeating: 50, count: 8),
                              isLooped: true)
        let sample = try XCTUnwrap(inst.primarySample)
        XCTAssertTrue(sample.isLooped, "Die Regression braucht einen echten Sample-Loop")
        let ch = DSPChannel(index: 1)
        ch.instrument = inst
        ch.sample = sample
        ch.volume = 64
        ch.currentVolume = 64
        ch.period = 214
        ch.currentPeriod = 214
        ch.sampleIndex = 2.0
        ch.sampleSpeed = 0.375
        ch.playing = false

        let frames: UInt32 = 32
        let voice = PreviewVoice(framesLeft: Int(frames))
        let block = RenderEngine.createPreviewRenderBlock(
            channel: ch, voice: voice, useInterpolation: false)
        let buffer = StereoRenderBuffer(capacity: Int(frames))

        block(frames, buffer.left, buffer.right)

        let left = buffer.left
        for frame in 0..<Int(frames) {
            XCTAssertEqual(left[frame], 0.0, accuracy: 0.0,
                           "Gestoppter Loop war in Frame \(frame) noch hoerbar")
        }
    }

    // MARK: - Offline-WAV-Renderer (Quick-Look-Pfad)

    func testRenderWavDataProducesValidRiff() throws {
        let mod = ModParser.generateDemoMod()
        let wav = try ModuleRenderer.renderWavData(mod: mod, maxDurationSeconds: 1.0)

        XCTAssertGreaterThan(wav.count, 44) // Header + Nutzdaten
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self), "WAVE")
        // data-Chunk-Laenge muss zur Dateigroesse passen. loadUnaligned, weil die
        // Basisadresse eines Data-Slices nicht zwingend 4-Byte-ausgerichtet ist:
        // load(as:) crasht dann unter Linux hart ("misaligned raw pointer"),
        // waehrend Darwin es toleriert.
        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), wav.count - 44)
        // Es muss hoerbares Signal drin sein (Demo-Mod ist nicht still).
        let payload = wav.subdata(in: 44..<min(wav.count, 44 + 88200))
        let hasSignal = payload.withUnsafeBytes { buf -> Bool in
            let samples = buf.bindMemory(to: Int16.self)
            return samples.contains { abs(Int($0)) > 100 }
        }
        XCTAssertTrue(hasSignal)
    }

    func testRenderWavRespectsS3MMod() throws {
        // Kompletter Durchstich: synthetisches S3M -> Loader -> WAV-Render.
        let mod = try ModuleLoader.parse(data: makeS3M())
        let wav = try ModuleRenderer.renderWavData(mod: mod, maxDurationSeconds: 1.0)
        XCTAssertGreaterThan(wav.count, 44)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }
}
