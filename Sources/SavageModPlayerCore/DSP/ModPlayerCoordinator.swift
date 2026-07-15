import Foundation

// Live-Wiedergabe für macOS/iOS: AVAudioEngine-Anbindung, UI-Zustand und die
// Instrument-Vorschau. Der plattformneutrale Renderkern liegt in
// RenderEngine.swift — CLI und Offline-Render (Quick Look, WAV) laufen ohne diese
// Klasse und bauen deshalb auch unter Linux, wo weder AVFoundation noch Combine
// existieren.
#if canImport(AVFoundation) && canImport(Combine)
import AVFoundation
import Combine

@MainActor
public final class ModPlayerCoordinator: ObservableObject {
    @Published public var isPlaying = false
    // Pausiert: Engine steht, aber der komplette Wiedergabezustand (Position,
    // Kanäle, Effekt-Memory) bleibt erhalten — resume() spielt nahtlos weiter.
    // isPlaying bleibt dabei true (die Engine ist weiterhin alloziert).
    @Published public var isPaused = false
    // Song-Position + aktuelle Zeile leben in einem EIGENEN ObservableObject
    // (row-rate), damit die ~20-Hz-Zeilenwechsel NICHT die ganze MainView.body neu
    // evaluieren — nur die positionsabhängigen Subviews beobachten `transport`.
    // War die eigentliche CPU-Grundlast (2026-07-09). Convenience-Accessoren unten
    // halten bestehende Aufrufer (seek etc.) unverändert.
    public let transport = TransportState()
    public var currentPosition: Int {
        get { transport.currentPosition }
        set { transport.currentPosition = newValue }
    }
    public var currentRow: Int {
        get { transport.currentRow }
        set { transport.currentRow = newValue }
    }
    // Die BPM-/Speed-Stepper in der UI schreiben in diese beiden Properties.
    // Damit eine Aenderung auch wirklich die laufende Wiedergabe beeinflusst,
    // muss sie an den Echtzeit-Zustand (`playbackState`) durchgereicht werden —
    // sonst liest der Render-Block weiter die alten `state.bpm`/`state.ticksPerRow`
    // und die Stepper waeren wirkungslos (sie wuerden ausserdem beim naechsten
    // VU-Poll wieder vom Render-Zustand ueberschrieben).
    @Published public var bpm = 125 {
        didSet {
            // Nur durchschreiben, wenn der Wert tatsaechlich von der UI kommt.
            // Der VU-Poller setzt `bpm` selbst aus `state.bpm` — in dem Fall sind
            // beide Werte schon gleich und wir sparen uns die Neuberechnung.
            guard let state = playbackState, state.bpm != bpm, bpm > 0 else { return }
            state.bpm = bpm
            // Tick-Laenge in Output-Frames neu bestimmen (gleiche Formel wie play()/seek()).
            let sampleRate = audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
            SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        }
    }
    @Published public var speed = 6 {
        didSet {
            // Analog zu `bpm`: Speed = Ticks pro Zeile an den Echtzeit-Zustand geben.
            guard let state = playbackState, state.ticksPerRow != speed, speed > 0 else { return }
            state.ticksPerRow = speed
            let sampleRate = audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
            SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        }
    }
    @Published public var trackName = "Kein Song geladen"

    // Kanalzahl des aktiven Moduls (4 bei klassischem MOD, bis 32 bei S3M).
    // Die UI leitet daraus Grid-Spalten, VU-Meter und Scopes ab.
    @Published public var channelCount = 4

    // Hochfrequenter (30 Hz) Visualisierungs-Zustand (VU, Oszilloskope, Spielzeit)
    // in EIGENEM ObservableObject — damit die 30-Hz-Updates NICHT die ganze
    // MainView.body neu evaluieren, sondern nur die beobachtenden Scope-/VU-/Zeit-
    // Subviews. War die Haupt-CPU-Last (2026-07-09). `let`: stabile Referenz.
    public let visualizerState = VisualizerState()

    // Sind die schweren Visualisierungen (Kanal-Oszis + Master-Oszi) gerade
    // sichtbar? Setzt die View im responsiven Kompaktmodus: bei kleinem Fenster
    // werden Grid/Oszis aus der Hierarchie entfernt. Der EIGENTLICHE CPU-Hebel ist
    // dann NICHT das Weglassen der Views (SwiftUI-Rendering ist billig), sondern
    // das Herunterschalten der Update-FREQUENZ: der 30-Hz-Tick schiebt sonst 30×/s
    // @Published-Werte durch SwiftUI — DAS war die Hauptlast (gemessen ~9 % von
    // ~15 %; Audio-DSP nur ~3-4 %). Ohne sichtbare Oszis reicht ~5 Hz für Uhr/VU.
    public var visualizersVisible = true {
        didSet {
            // Läuft der VU-Timer, bei einem Sichtbarkeitswechsel mit der passenden
            // Frequenz neu aufsetzen (30 Hz sichtbar ↔ 5 Hz kompakt).
            guard oldValue != visualizersVisible, vuUpdateTimer != nil else { return }
            startVUUpdates()
        }
    }

    // Update-Frequenz des VU-/Oszi-/Zeit-Ticks: 30 Hz für flüssige Oszilloskope,
    // im Kompaktmodus nur ~5 Hz (kein Oszi sichtbar) — senkt die SwiftUI-Last stark.
    private var vuUpdateInterval: TimeInterval { visualizersVisible ? 0.033 : 0.2 }

    // New parameters for user controls
    @Published public var stereoSeparation: Float = 0.8 {
        didSet {
            playbackState?.stereoSeparation = stereoSeparation
        }
    }
    @Published public var useInterpolation: Bool = true {
        didSet {
            playbackState?.useInterpolation = useInterpolation
        }
    }
    @Published public var palClock: Bool = true {
        didSet {
            playbackState?.palClock = palClock
        }
    }
    

    // Zaehlt bei jedem erreichten Songende hoch. Die UI beobachtet das per
    // onChange und wertet dort den loopMode aus (stop / Song wiederholen / naechster).
    @Published public var songEndPulse: Int = 0
    
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var lowPassFilterNode: AVAudioUnitEQ?

    // Getrennte Engine nur fuer die Instrument-Vorschau (previewInstrument).
    private var previewEngine: AVAudioEngine?
    private var previewSourceNode: AVAudioSourceNode?
    
    @Published public var ledFilterActive: Bool = false {
        didSet {
            lowPassFilterNode?.bypass = !ledFilterActive
        }
    }
    

    // Vorallozierte DSP-Kanäle. Wird in setMod() passend zur Kanalzahl des
    // Moduls neu aufgebaut (der Render-Block captured das Array bei play()).
    private var channels = [DSPChannel(index: 1), DSPChannel(index: 2), DSPChannel(index: 3), DSPChannel(index: 4)]
    public var activeMod: Mod?
    
    // ARC-managed state captured by the AVAudioSourceNode closure
    private var playbackState: RealtimePlaybackState?
    
    // Raw pointers for atomic visual synchronization (preallocated, thread-safe, lock-free)
    nonisolated(unsafe) private let peakLevelsPointer: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private let masterWavesPointer: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private let channelWavesPointer: UnsafeMutablePointer<Float>
    
    // Timer for VU meter visual updates
    private var vuUpdateTimer: Timer?
    
    public init() {
        // Puffer immer für die Maximal-Kanalzahl anlegen: so bleibt der
        // Echtzeit-Pfad allokationsfrei, egal wie viele Kanäle ein Modul hat.
        self.peakLevelsPointer = UnsafeMutablePointer<Float>.allocate(capacity: RenderEngine.maxChannels)
        for i in 0..<RenderEngine.maxChannels {
            self.peakLevelsPointer[i] = 0.0
        }
        self.masterWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        for i in 0..<128 {
            self.masterWavesPointer[i] = 0.0
        }
        self.channelWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: RenderEngine.maxChannels * 32) // je Kanal 32 Samples
        for i in 0..<(RenderEngine.maxChannels * 32) {
            self.channelWavesPointer[i] = 0.0
        }
    }
    
    deinit {
        peakLevelsPointer.deallocate()
        masterWavesPointer.deallocate()
        channelWavesPointer.deallocate()
    }
    
    // fallbackName: Anzeigename (i. d. R. der Dateiname), der genutzt wird, wenn
    // das Modul selbst keinen brauchbaren Titel im Header traegt. Viele Module —
    // gerade aus der Demoscene — haben ein leeres Titelfeld; frueher stand dann
    // stumpf "Unbekannter Track" oben. Der Dateiname ist fuer den Nutzer weit
    // aussagekraeftiger.
    public func setMod(_ mod: Mod, fallbackName: String? = nil) {
        stop()
        self.activeMod = mod
        // Header-Titel um Leerraum bereinigen; nur ein echter, nicht-leerer Titel
        // gewinnt, sonst der Dateiname-Fallback (und erst zuletzt der Default).
        let headerTitle = mod.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trackName = !headerTitle.isEmpty ? headerTitle
            : (fallbackName?.isEmpty == false ? fallbackName! : "Unbekannter Track")

        // Kanal-Setup passend zum Modul neu aufbauen (4 bei MOD, N bei S3M).
        let count = max(1, min(RenderEngine.maxChannels, mod.channelCount))
        // Nur der IT-Instrument-Modus braucht NNA-Hintergrundstimmen. Im
        // Sample-Modus bleibt die direkte 64-Kanal-Zuordnung deutlich billiger.
        let voiceCount = mod.format == .it && mod.itProperties?.usesInstruments == true
            ? RenderEngine.itVoiceCapacity
            : count
        self.channels = (1...voiceCount).map { DSPChannel(index: $0) }
        RenderEngine.configure(channels: self.channels, for: mod)
        self.channelCount = count
        self.visualizerState.resize(channelCount: count)
        // Einmal pro Song denselben Sequencer ohne Audio bis zum Endsignal
        // vortakten. Die fruehere Rows*Speed/BPM-Schaetzung ignorierte Bxx,
        // Pattern-Loops, Delays und Tempoaenderungen (Referenz-IT: 01:24 statt
        // korrekt 00:46). Die schnelle Tick-Probe ist von Blockgroessen frei.
        self.visualizerState.totalDuration = RenderEngine.sequencedDuration(of: mod)

        self.currentPosition = 0
        self.currentRow = 0
        // Eine fuer den alten Song vorgemerkte Startposition/-zeile gilt nicht mehr.
        self.pendingStartPosition = nil
        self.pendingStartRow = nil
        self.pendingGlobalVolume = nil
        // codereview-ok: by-design — neuer Song startet auf seinem Header-Tempo
        // (MOD: ProTracker-Default 125/6, S3M: Initial Speed/Tempo) und setzt
        // sein Tempo per Effekt selbst; mit dem didSet-Fix benigne, kein
        // Datenverlust an laufender Wiedergabe (2026-07-01)
        self.bpm = mod.initialTempo
        self.speed = mod.initialSpeed
    }

    
    public func play() {
        // Eine evtl. laufende Instrument-Vorschau weicht der Song-Wiedergabe.
        stopPreview()
        guard let mod = activeMod, mod.length > 0 else { return }
        if isPlaying { return }
        
        // Ensure channels are fresh
        for ch in channels {
            ch.reset()
        }
        // reset() stellt MOD-Defaults her -> Format-Konfiguration neu anwenden.
        RenderEngine.configure(channels: channels, for: mod)

        let engine = AVAudioEngine()
        self.audioEngine = engine
        
        let mixer = engine.mainMixerNode
        var sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0.0 || sampleRate.isNaN || sampleRate.isInfinite {
            sampleRate = 44100.0
        }
        
        // Define a guaranteed standard stereo format for our sourceNode
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            print("Fehler: Konnte standard stereo format nicht erstellen.")
            return
        }
        
        // Instantiate ARC-managed playback state
        let state = RealtimePlaybackState()
        state.position = 0
        state.rowIndex = -1
        // Start-Tempo aus den aktuellen Coordinator-Werten (self.bpm/self.speed)
        // statt stur aus dem Modul-Header: setMod() setzt beide beim Songwechsel
        // ohnehin auf die Header-Werte, aber eine im gestoppten Zustand per
        // Stepper gewaehlte Aenderung bleibt so erhalten und wird beim Play nicht
        // sofort wieder ueberschrieben. Song-eigene Tempo-Effekte (Fxx) greifen
        // waehrend der Wiedergabe weiterhin.
        state.tick = self.speed - 1
        state.ticksPerRow = self.speed
        state.bpm = self.bpm
        state.tempoMode = mod.itProperties?.openMPTExtensions?.tempoMode ?? .classic
        let headerRowsPerBeat = mod.itProperties.map { $0.patternHighlight & 0xFF } ?? 4
        state.rowsPerBeat = max(
            1,
            mod.itProperties?.openMPTExtensions?.rowsPerBeat
                ?? (headerRowsPerBeat > 0 ? headerRowsPerBeat : 4)
        )
        state.restartPosition = max(
            0,
            min(mod.length - 1, mod.itProperties?.openMPTExtensions?.restartPosition ?? 0)
        )
        SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        state.outputsUntilNextTick = 0.0
        state.positionJump = -1
        state.patternBreak = -1
        state.patternLoopRow = -1
        state.patternDelay = 0
        state.patternDelayCounter = 0
        state.patternDelaySeen = false
        state.tempoSlide = 0
        state.globalVolumeSlide = 0
        state.rowTickDelay = 0
        state.endReached = false
        state.endReachedFrame = .max
        if let states = channels.first?.itVoicePool?.patternChannels {
            for patternState in states {
                patternState.patternLoopCount = -1
                patternState.patternLoopStartRow = 0
                patternState.channelVolumeSlide = 0
                patternState.panningSlide = 0
            }
        }
        state.stereoSeparation = self.stereoSeparation
        state.useInterpolation = self.useInterpolation
        state.palClock = self.palClock
        state.globalVolume = Float(mod.initialGlobalVolume)
        state.clockRateOverride = (mod.format == .s3m || mod.format == .it) ? 14317056.0 : 0
        state.elapsedFrames = 0

        // Wurde im gestoppten Zustand per Slider eine Startposition gewaehlt,
        // dort direkt vor Zeile 0 stehen. Das ist unabhaengig von der variablen
        // Zeilenzahl des vorherigen OpenMPT-Patterns.
        if let startPos = pendingStartPosition, startPos >= 0, startPos < mod.length {
            if let startRow = pendingStartRow, startRow > 0 {
                // Zeilen-genauer Start (Grid-Klick): direkt auf (startPos, startRow)
                // setzen — eine Zeile davor auf dem letzten Tick, damit der erste
                // Tick-Boundary die Zielzeile frisch laedt und triggert.
                state.position = startPos
                state.rowIndex = startRow - 1
                state.tick = state.ticksPerRow - 1
                state.elapsedFrames = UInt64(Double(RenderEngine.cumulativeRows(mod, upTo: startPos, row: startRow) * state.ticksPerRow) * state.outputsPerTick)
            } else {
                state.position = startPos
                state.rowIndex = -1
                state.elapsedFrames = UInt64(Double(RenderEngine.cumulativeRows(mod, upTo: startPos) * mod.initialSpeed) * state.outputsPerTick)
            }
        }
        // Rekonstruiertes Global-Volume (Zeilen-Sprung) uebernehmen.
        if let gv = pendingGlobalVolume { state.globalVolume = Float(gv) }
        pendingStartPosition = nil
        pendingStartRow = nil
        pendingGlobalVolume = nil

        self.playbackState = state
        
        let dspChannels = channels
        let vuBuffer = RealtimeVUBuffer(pointer: peakLevelsPointer)
        let waveBuffer = RealtimeWaveBuffer(channelWaves: channelWavesPointer, masterWaves: masterWavesPointer)
        
        let renderBlock = RenderEngine.createRenderBlock(
            state: state,
            vuBuffer: vuBuffer,
            waveBuffer: waveBuffer,
            dspChannels: dspChannels,
            mod: mod,
            sampleRate: sampleRate
        )
        
        let sourceNode = AVAudioSourceNode(renderBlock: Self.makeSourceNodeRenderBlock(renderBlock))

        self.sourceNode = sourceNode
        engine.attach(sourceNode)
        
        let lowPass = AVAudioUnitEQ(numberOfBands: 1)
        let band = lowPass.bands[0]
        band.filterType = .lowPass
        band.frequency = 3200.0
        lowPass.bypass = !ledFilterActive
        self.lowPassFilterNode = lowPass
        
        engine.attach(lowPass)
        
        engine.connect(sourceNode, to: lowPass, format: stereoFormat)
        engine.connect(lowPass, to: mixer, format: stereoFormat)
        
        // iOS spezifisch: AudioSession aktivieren (Dummy-Aufruf auf macOS, funktioniert überall)
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Fehler bei iOS AVAudioSession Aktivierung: \(error)")
        }
        #endif
        
        do {
            try engine.start()
            // Gespeicherte Lautstaerke auf den neuen Mixer anwenden, damit die
            // Ausgabe sofort zum UI-Slider passt (nicht erst nach Slider-Bewegung).
            mixer.outputVolume = lastVolume * lastVolume
            isPlaying = true
            isPaused = false
            startVUUpdates()
        } catch {
            print("Fehler beim Starten der AVAudioEngine: \(error)")
            // Startet die Engine nicht, muessen die eben erzeugten Ressourcen
            // wieder abgebaut werden. Sonst bleiben audioEngine/sourceNode/
            // playbackState gesetzt, waehrend isPlaying==false ist — ein erneuter
            // play()-Aufruf liefe dann am `if isPlaying { return }`-Guard vorbei
            // und wuerde eine zweite, konkurrierende Engine erzeugen (Ressourcen-
            // Leak). stop() raeumt alles konsistent auf.
            stop()
        }
    }

    public func stop() {
        stopPreview()
        if let engine = audioEngine {
            engine.stop()
        }
        audioEngine = nil
        sourceNode = nil
        isPlaying = false
        isPaused = false
        stopVUUpdates()

        self.playbackState = nil

        for ch in channels {
            ch.reset()
        }
    }

    // Wiedergabe anhalten, ohne den Zustand zu verwerfen. Gegenstück: resume().
    public func pause() {
        guard isPlaying, !isPaused, let engine = audioEngine else { return }
        engine.pause()
        isPaused = true
        // VU-Timer anhalten — die Meter fallen auf 0, elapsedTime friert ein.
        stopVUUpdates()
    }

    // Pausierte Wiedergabe nahtlos fortsetzen.
    public func resume() {
        guard isPaused, let engine = audioEngine else { return }
        do {
            try engine.start()
            isPaused = false
            startVUUpdates()
        } catch {
            print("Fehler beim Fortsetzen der AVAudioEngine: \(error)")
            // Engine nicht wiederbelebbar -> sauber aufraeumen statt in einem
            // halb-pausierten Zustand haengen zu bleiben.
            stop()
        }
    }
    
    // Zuletzt gesetzte Lautstaerke (0..1). Wird beim naechsten play() auf den
    // frisch erzeugten Mixer angewandt, damit die tatsaechliche Ausgabe von Anfang
    // an zum Slider passt (vorher lief die erste Wiedergabe auf Default 1.0).
    private var lastVolume: Float = 0.6

    public func setVolume(_ v: Float) {
        lastVolume = v
        audioEngine?.mainMixerNode.outputVolume = v * v // Psychoacoustic scaling
    }
    
    // Merkt die per Slider gewaehlte Startposition, wenn gerade nichts spielt.
    // Der naechste play()-Aufruf startet dann dort statt am Songanfang.
    private var pendingStartPosition: Int?
    // Zusaetzlich zur Position eine Zeile (Zeilen-genauer Sprung per Grid-Klick im
    // gestoppten Zustand) und das rekonstruierte Start-Global-Volume.
    private var pendingStartRow: Int?
    private var pendingGlobalVolume: Int?


    // Zeilen-genauer Sprung: Grid-Klick auf eine Zeile. Rekonstruiert Speed/Tempo/
    // Global-Volume, damit die Wiedergabe ab dort im richtigen Tempo laeuft.
    public func seek(toPosition pos: Int, row: Int) {
        guard let mod = activeMod else { return }
        let p = max(0, min(mod.length - 1, pos))
        let r = max(0, min(RenderEngine.patternRowCount(mod, at: p) - 1, row))
        let params = RenderEngine.reconstructGlobalParams(mod, toPosition: p, row: r)
        // Coordinator-Tempo spiegeln (play() liest self.speed/self.bpm beim Kaltstart).
        self.speed = params.speed
        self.bpm = params.bpm
        guard let state = playbackState else {
            // Gestoppt: Ziel vormerken; play() startet dort mit dem rekonstruierten Tempo.
            pendingStartPosition = p
            pendingStartRow = r
            pendingGlobalVolume = params.globalVolume
            currentPosition = p
            currentRow = r
            return
        }
        let sampleRate = self.audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
        state.ticksPerRow = params.speed
        state.bpm = params.bpm
        SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        state.globalVolume = Float(params.globalVolume)
        applySeek(state: state, mod: mod, position: p, row: r)
    }

    public func seek(toPosition: Int) {
        guard let mod = activeMod else { return }
        let pos = max(0, min(mod.length - 1, toPosition))
        guard let state = playbackState else {
            // Gestoppt: Position nur vormerken und in der UI anzeigen —
            // play() greift sie auf und beginnt an dieser Stelle.
            pendingStartPosition = pos
            currentPosition = pos
            currentRow = 0
            return
        }
        applySeek(state: state, mod: mod, position: pos, row: 0)
    }

    // Relativer Zeitsprung (z.B. +30s/-15s). Rechnet die gewuenschten Sekunden
    // ueber die aktuelle Zeilendauer (Speed/BPM) in Pattern-Zeilen um und
    // springt zeilengenau — bei Tempo-Wechseln im Song eine Naeherung.
    public func seek(bySeconds delta: Double) {
        guard let state = playbackState, let mod = activeMod else { return }
        let bpm = Double(state.bpm > 0 ? state.bpm : 125)
        let rowDuration = Double(max(1, state.ticksPerRow)) * 60.0 / (bpm * 24.0)
        guard rowDuration > 0 else { return }

        let currentRows = RenderEngine.cumulativeRows(mod, upTo: state.position, row: max(0, state.rowIndex))
        var targetRows = currentRows + Int((delta / rowDuration).rounded())
        let totalRows = RenderEngine.cumulativeRows(mod, upTo: mod.length)
        targetRows = max(0, min(totalRows - 1, targetRows))
        let target = RenderEngine.positionAndRow(mod, forGlobalRow: targetRows)
        applySeek(state: state, mod: mod, position: target.position, row: target.row)
    }

    private func applySeek(state: RealtimePlaybackState, mod: Mod, position: Int, row: Int) {
        // Ziel so setzen, dass der naechste Tick-Boundary die Zielzeile LAEDT
        // und ihre Noten triggert: eine Zeile davor auf dem letzten Tick stehen.
        // (rowIndex -1 ist fuer row 0 in Ordnung — der Row-Advance rechnet +1.)
        state.position = position
        state.rowIndex = row - 1
        state.tick = state.ticksPerRow - 1

        // Noch nicht konsumierte Sequenz-Sprungbefehle loeschen. Ohne das wuerde
        // ein vor dem Seek gesetzter Position-Jump (Bxx), Pattern-Break (Dxx) oder
        // Pattern-Loop (E6x) beim naechsten Row-Advance feuern und die eben
        // angesprungene Zielposition sofort wieder ueberschreiben. -1 = "inaktiv".
        state.positionJump = -1
        state.patternBreak = -1
        state.patternLoopRow = -1
        // Auch die per-Channel Pattern-Loop-Zustaende (E6x) neutralisieren. Sonst
        // greift beim naechsten E6x-Handler der `patternLoopCount < 0`-Guard nicht
        // (Zaehler noch positiv aus der Zeit vor dem Seek) und der Loop liefe mit
        // stale Restzaehler weiter — analog zu DSPChannel.reset().
        for ch in channels {
            ch.patternLoopCount = -1
            ch.patternLoopStartRow = 0
            // Alle Kanaele stummschalten: vor dem Seek laufende Noten sollen an der
            // Zielstelle NICHT weiterklingen (sonst "haengende" Kanaele). Ab der
            // Zielzeile getriggerte Noten spielen normal. Per-Kanal-Slide-/Sustain-
            // Zustaende werden (noch) nicht rekonstruiert -> gehaltene Noten von vor
            // dem Sprung fehlen; das ist der bewusste Kompromiss fuer Test-Spruenge.
            ch.playing = false
        }
        // Defensiv: ein laufender Pattern-Delay (EEx) wuerde sonst die erste Row
        // nach dem Seek unerwartet verzoegern.
        state.patternDelay = 0
        state.patternDelayCounter = 0

        state.patternDelaySeen = false
        state.tempoSlide = 0
        state.globalVolumeSlide = 0
        state.rowTickDelay = 0
        state.endReached = false
        state.endReachedFrame = .max
        if let states = channels.first?.itVoicePool?.patternChannels {
            for patternState in states {
                patternState.patternLoopCount = -1
                patternState.patternLoopStartRow = 0
                patternState.channelVolumeSlide = 0
                patternState.panningSlide = 0
            }
        }

        let sampleRate = self.audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
        SequencerCore.recalculateTickDuration(state: state, sampleRate: sampleRate)
        state.elapsedFrames = UInt64(
            Double(RenderEngine.cumulativeRows(mod, upTo: position, row: row) * state.ticksPerRow)
                * state.outputsPerTick
        )

        self.currentPosition = position
        self.currentRow = max(0, row)
    }
    
    public func toggleMute(channelIndex: Int) {
        guard channelIndex >= 0 && channelIndex < channelCount else { return }
        if activeMod?.format == .it,
           let states = channels.first?.itVoicePool?.patternChannels,
           channelIndex < states.count {
            states[channelIndex].isMuted.toggle()
        } else {
            channels[channelIndex].isMuted.toggle()
        }
        objectWillChange.send()
        // Die Kanal-Streifen beobachten den visualizerState (nicht den Coordinator).
        // Ohne diesen Anstoß aktualisierte sich die M/S-Optik im gestoppten Zustand
        // erst beim nächsten Play (dann tickt der VU-Timer wieder).
        visualizerState.nudge()
    }

    public func toggleSolo(channelIndex: Int) {
        guard channelIndex >= 0 && channelIndex < channelCount else { return }
        if activeMod?.format == .it,
           let states = channels.first?.itVoicePool?.patternChannels,
           channelIndex < states.count {
            states[channelIndex].isSoloed.toggle()
        } else {
            channels[channelIndex].isSoloed.toggle()
        }
        objectWillChange.send()
        visualizerState.nudge()
    }

    public func isMuted(channelIndex: Int) -> Bool {
        guard channelIndex >= 0 && channelIndex < channelCount else { return false }
        if activeMod?.format == .it,
           let states = channels.first?.itVoicePool?.patternChannels,
           channelIndex < states.count {
            return states[channelIndex].isMuted
        }
        return channels[channelIndex].isMuted
    }

    public func isSoloed(channelIndex: Int) -> Bool {
        guard channelIndex >= 0 && channelIndex < channelCount else { return false }
        if activeMod?.format == .it,
           let states = channels.first?.itVoicePool?.patternChannels,
           channelIndex < states.count {
            return states[channelIndex].isSoloed
        }
        return channels[channelIndex].isSoloed
    }

    @MainActor
    private func updateVULevelsTick() {
        // Hochfrequente Puffer landen im getrennten visualizerState (nicht mehr auf
        // self), damit dieser 30-Hz-Tick nur die Scope-/VU-/Zeit-Subviews neu rendert.
        let vis = self.visualizerState
        let count = min(channelCount, RenderEngine.maxChannels)
        var newLevels = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let rawPeak = self.peakLevelsPointer[i]
            let prev = i < vis.vuLevels.count ? vis.vuLevels[i] : 0
            let attack: Float = 0.35
            let release: Float = 0.08

            let factor = rawPeak > prev ? attack : release
            newLevels[i] = prev + (rawPeak - prev) * factor

            // Reset raw peak in the C-pointer
            self.peakLevelsPointer[i] = 0.0
        }
        vis.vuLevels = newLevels

        // Level-2-Sparen (Kompaktmodus): Die teure Wellen-/Master-Oszi-Berechnung
        // (count×32 + 128 Kopien pro Tick, je eine Allokation) NUR ausführen, wenn
        // die Oszilloskope überhaupt sichtbar sind. Bei kleinem Fenster sind sie aus
        // der View-Hierarchie entfernt — dann sparen wir diesen CPU-Posten komplett.
        // VU-Pegel (oben, billig), Spielzeit und Songende laufen weiter.
        if visualizersVisible {
            // Update true channel waveforms from channelWavesPointer
            var newWaves = (0..<count).map { _ in [Float](repeating: 0.0, count: 32) }
            for i in 0..<count {
                for j in 0..<32 {
                    newWaves[i][j] = self.channelWavesPointer[i * 32 + j]
                }
            }
            vis.channelWaveforms = newWaves

            // Update true master oscilloscope samples from masterWavesPointer
            var newMasterOsc = [Float](repeating: 0.0, count: 128)
            for j in 0..<128 {
                newMasterOsc[j] = self.masterWavesPointer[j]
            }
            vis.masterSamples = newMasterOsc
        }

        // Read progress directly from shared state (100% lock-free, allocation-free)
        if let state = self.playbackState {
            // Songende-Signal aus dem Renderblock auf den MainActor heben.
            if state.endReached {
                state.endReached = false
                state.endReachedFrame = .max
                self.songEndPulse &+= 1
            }

            let pos = state.position
            let row = state.rowIndex
            let b = state.bpm
            let sp = state.ticksPerRow
            
            // Only publish if changed to minimize UI relayout overhead
            if self.currentPosition != pos { self.currentPosition = pos }
            if self.currentRow != row { self.currentRow = row }
            if self.bpm != b { self.bpm = b }
            if self.speed != sp { self.speed = sp }
            
            let sampleRate = self.audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
            vis.elapsedTime = Double(state.elapsedFrames) / sampleRate

        }
    }
    
    private func startVUUpdates() {
        // Evtl. laufenden Timer ersetzen (z. B. bei Frequenzwechsel Full↔Compact).
        vuUpdateTimer?.invalidate()
        // 30 Hz für flüssige Oszilloskope; im Kompaktmodus 5 Hz (vuUpdateInterval).
        // Jeder Tick schiebt @Published-Werte durch SwiftUI — die Frequenz ist der
        // dominante UI-CPU-Faktor (nicht das Zeichnen), darum im Compact gedrosselt.
        let timer = Timer(timeInterval: vuUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateVULevelsTick()
            }
        }
        // .common statt Default-Mode: der Default-RunLoop-Mode pausiert
        // waehrend Maus-Drags (Slider, Fenster-Resize) — VU, Scopes und die
        // Tracker-Ansicht froren dann ein, obwohl der Ton weiterlief.
        RunLoop.main.add(timer, forMode: .common)
        vuUpdateTimer = timer
    }
    
    private func stopVUUpdates() {
        vuUpdateTimer?.invalidate()
        vuUpdateTimer = nil
        self.visualizerState.vuLevels = [Float](repeating: 0, count: channelCount)
    }
    
    // MARK: - Safe Real-Time Audio Block Construction

    // Einziger Übergang vom plattformneutralen Renderblock zu CoreAudio. Nur
    // AVAudioSourceNode braucht die Darwin-Signatur; alles dahinter (Sequencer,
    // Mixing, Limiter) bleibt plattformneutral und damit unter Linux baubar.
    //
    // Echtzeit-sicher: UnsafeMutableAudioBufferListPointer ist ein reiner
    // Pointer-Wrapper, der aufgerufene Block ist ein bereits erzeugter Closure.
    // Keine Allokation, kein Lock, kein dynamischer Objective-C-Aufruf.
    nonisolated static func makeSourceNodeRenderBlock(
        _ block: @escaping ModuleRenderBlock
    ) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, outputData -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let leftPtr = buffers[0].mData,
                  let rightPtr = buffers[1].mData else {
                return noErr
            }
            block(
                frameCount,
                leftPtr.assumingMemoryBound(to: Float.self),
                rightPtr.assumingMemoryBound(to: Float.self)
            )
            return noErr
        }
    }

    
    // Spielt eine einzelne Instrument-Grundnote in einer EIGENEN, vom Song
    // voellig getrennten Audio-Engine ab. Dadurch klingt die Vorschau auch im
    // gestoppten Zustand (die Song-Engine existiert dann gar nicht) und kapert
    // niemals einen Song-Kanal (frueher wurde channels.last uebernommen und dabei
    // dessen Mute/Solo geloescht).
    public func previewInstrument(index: Int) {
        guard let mod = activeMod, index >= 1 && index < mod.instruments.count,
              let inst = mod.instruments[index],
              let selection = mod.previewSelection(instrumentIndex: index) else { return }
        let smp = selection.sample

        // Laufende Vorschau zuerst abbauen — erneuter Klick startet frisch.
        stopPreview()

        // Eigener Kanal, nur fuer die Vorschau. Kein configure()/performTick noetig:
        // renderChannelSample braucht bloss Sample, Periode, sampleSpeed und
        // Lautstaerke — es gibt keinen Sequencer und keine Effekte in der Vorschau.
        let ch = DSPChannel(index: 1)
        ch.instrument = inst
        ch.sample = smp
        ch.volume = Float(smp.volume)
        ch.currentVolume = Float(smp.volume)
        if mod.format == .s3m {
            // C-4 im ST3-Periodenmodell (Key 48) mit Instrument-C2Spd.
            ch.period = DSPChannel.s3mPeriod(key: 48, c2spd: smp.c2spd)
        } else if mod.format == .it {
            // IT stimmt Samples ueber C5Speed. Instrument-Mode kann die
            // Vorschau-Note zusaetzlich per 120er Notemap transponieren.
            ch.period = mod.linearFrequency
                ? DSPChannel.itLinearPeriod(key: selection.targetNote)
                : DSPChannel.itAmigaPeriod(
                    key: selection.targetNote,
                    c5Speed: smp.itProperties?.c5Speed ?? smp.c2spd
                )
        } else {
            // C-3 note period = 214
            ch.period = 214.0 - Float(smp.finetune)
        }
        ch.currentPeriod = ch.period
        ch.sampleIndex = 0.0
        ch.playing = true

        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        var sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0.0 || sampleRate.isNaN || sampleRate.isInfinite { sampleRate = 44100.0 }
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        // sampleSpeed aus der Periode ableiten — dieselbe Formel wie in
        // performTick (Paula-Frequenz / Ausgabe-Rate). clockRate wie im Song-Pfad:
        // S3M nutzt den festen ST3-Takt, MOD den PAL/NTSC-Amiga-Takt.
        let clockRate = (mod.format == .s3m || mod.format == .it)
            ? 14317056.0
            : (self.palClock ? 3546894.6 : 3579545.25)
        if mod.format == .it {
            ch.sampleSpeed = RenderEngine.itPreviewSampleSpeed(
                sample: smp,
                targetNote: selection.targetNote,
                linearFrequency: mod.linearFrequency,
                sampleRate: sampleRate
            )
        } else {
            ch.sampleSpeed = ch.currentPeriod > 0 ? (clockRate / Double(ch.currentPeriod)) / sampleRate : 0.0
        }

        // Frame-Budget: geloopte Samples nach ~1,6 s ausklingen lassen (sonst
        // droehnen sie endlos); nicht-geloopte enden ohnehin von selbst, weil
        // renderChannelSample hinter dem Sample-Ende 0 liefert.
        let voice = PreviewVoice(framesLeft: Int(sampleRate * 1.6))
        let renderBlock = RenderEngine.createPreviewRenderBlock(channel: ch, voice: voice, useInterpolation: self.useInterpolation)

        let sourceNode = AVAudioSourceNode(renderBlock: Self.makeSourceNodeRenderBlock(renderBlock))
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mixer, format: stereoFormat)
        do {
            try engine.start()
            mixer.outputVolume = lastVolume * lastVolume
            self.previewEngine = engine
            self.previewSourceNode = sourceNode
        } catch {
            print("Fehler beim Starten der Preview-Engine: \(error)")
        }
    }


    // Vorschau-Engine abbauen (idempotent). Wird bei erneutem Preview-Klick sowie
    // beim Start/Stopp der Song-Wiedergabe und beim Songwechsel gerufen, damit nie
    // zwei Engines nebeneinander laufen.
    public func stopPreview() {
        if let engine = previewEngine { engine.stop() }
        previewEngine = nil
        previewSourceNode = nil
    }


    nonisolated public func exportActiveModToWav(
        mod: Mod,
        stereoSeparation: Float,
        useInterpolation: Bool,
        palClock: Bool,
        destinationURL: URL,
        durationSeconds: Double = 180.0
    ) throws {
        let sampleRate = 44100.0
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "ModPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Konnte Audio-Format nicht erstellen"])
        }
        
        // Ziel-Datei ggf. entfernen, damit AVAudioFile sauber neu schreiben kann.
        // "Datei nicht vorhanden" ist der Normalfall (frischer Save-Panel-Pfad) und
        // wird ignoriert; andere Fehler (z.B. Sandbox-Permissions) werden geloggt,
        // statt sie wie zuvor per try? stillschweigend zu verschlucken.
        do {
            try FileManager.default.removeItem(at: destinationURL)
        } catch CocoaError.fileNoSuchFile {
            // erwartet — Zielpfad war frei
        } catch {
            print("WAV-Export: konnte bestehende Datei nicht entfernen: \(error.localizedDescription)")
        }
        let audioFile = try AVAudioFile(forWriting: destinationURL, settings: stereoFormat.settings)

        let renderChannels = RenderEngine.makeRenderChannels(for: mod)
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = stereoSeparation
        state.useInterpolation = useInterpolation
        state.palClock = palClock

        let channelCount = mod.format == .it
            ? max(1, min(RenderEngine.maxChannels, mod.channelCount))
            : renderChannels.count
        let dummyPeaks = UnsafeMutablePointer<Float>.allocate(capacity: channelCount)
        defer { dummyPeaks.deallocate() }
        for j in 0..<channelCount { dummyPeaks[j] = 0.0 }
        let vuBuffer = RealtimeVUBuffer(pointer: dummyPeaks)

        let dummyWaves = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * 32)
        defer { dummyWaves.deallocate() }
        for j in 0..<(channelCount * 32) { dummyWaves[j] = 0.0 }
        let dummyMasterWaves = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { dummyMasterWaves.deallocate() }
        for j in 0..<128 { dummyMasterWaves[j] = 0.0 }
        let waveBuffer = RealtimeWaveBuffer(channelWaves: dummyWaves, masterWaves: dummyMasterWaves)
        
        let block = RenderEngine.createRenderBlock(
            state: state,
            vuBuffer: vuBuffer,
            waveBuffer: waveBuffer,
            dspChannels: renderChannels,
            mod: mod,
            sampleRate: sampleRate
        )
        
        let blockFrames = UInt32(1024)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: blockFrames) else {
            throw NSError(domain: "ModPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Konnte Buffer nicht erstellen"])
        }
        // stereoFormat ist non-interleaved Float32, floatChannelData liefert also
        // je einen eigenen Puffer für links und rechts — genau das, was der
        // plattformneutrale Renderblock erwartet.
        guard let floatData = pcmBuffer.floatChannelData else {
            throw NSError(domain: "ModPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kein Float-Puffer verfügbar"])
        }

        let totalFramesToRender = UInt64(sampleRate * durationSeconds)
        var renderedFrames: UInt64 = 0

        while renderedFrames < totalFramesToRender {
            pcmBuffer.frameLength = blockFrames
            block(blockFrames, floatData[0], floatData[1])

            var validFrames = UInt64(blockFrames)
            validFrames = min(validFrames, totalFramesToRender - renderedFrames)
            if state.endReachedFrame != .max {
                validFrames = min(
                    validFrames,
                    state.endReachedFrame > renderedFrames
                        ? state.endReachedFrame - renderedFrames
                        : 0
                )
            }
            pcmBuffer.frameLength = AVAudioFrameCount(validFrames)
            if validFrames > 0 { try audioFile.write(from: pcmBuffer) }
            renderedFrames += validFrames
            
            // Songende: der Render-Block setzt endReached beim Wrap über
            // mod.length (unabhängig von der Pattern-Reihenzahl — die ist bei XM
            // variabel, ein fixes rowIndex>=63 hätte bei kurzen End-Patterns nie
            // ausgelöst). Für den einmaligen Offline-Render (Quick Look / A/B)
            // ist das das saubere Abbruchsignal.
            if state.endReached {
                break
            }
        }
    }

    nonisolated func renderProbe(
        mod: Mod,
        durationSeconds: Double,
        sampleRate: Double = 44100.0
    ) -> [RenderProbeSample] {
        let renderChannels = RenderEngine.makeRenderChannels(for: mod)
        let channelCount = mod.format == .it
            ? max(1, min(RenderEngine.maxChannels, mod.channelCount))
            : renderChannels.count
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = 0.8
        state.useInterpolation = true
        state.palClock = true

        let totalFrames = Int(sampleRate * durationSeconds)
        var samples: [RenderProbeSample] = []
        samples.reserveCapacity(totalFrames / 256)

        for frame in 0..<totalFrames {
            SequencerCore.advanceIfNeeded(
                state: state,
                channels: renderChannels,
                mod: mod,
                sampleRate: sampleRate
            )

            state.outputsUntilNextTick -= 1.0
            state.elapsedFrames += 1

            var channelOutputs = [Float](repeating: 0, count: channelCount)
            let pool = renderChannels.first?.itVoicePool
            let renderedVoiceCount = pool?.usesBackgroundVoices == true
                ? pool!.activeVoiceCount
                : renderChannels.count
            for renderPosition in 0..<renderedVoiceCount {
                let voice = pool?.usesBackgroundVoices == true
                    ? renderChannels[pool!.activeVoiceIndex(at: renderPosition)]
                    : renderChannels[renderPosition]
                let owner = mod.format == .it ? (voice.itPatternState?.channelIndex ?? -1) : voice.channelIndex - 1
                if owner >= 0, owner < channelCount {
                    channelOutputs[owner] += RenderEngine.renderChannelSample(
                        channel: voice,
                        useInterpolation: state.useInterpolation
                    )
                }
            }

            if frame % 256 == 0 {
                let trace = SequencerTraceSnapshot(frame: frame, state: state, mod: mod)
                samples.append(RenderProbeSample(
                    frame: frame,
                    position: state.position,
                    row: state.rowIndex,
                    channelOutputs: channelOutputs,
                    trace: trace
                ))
            }
        }

        return samples
    }


    
    public func exportInstrumentToWav(index: Int, destinationURL: URL) throws {
        guard let mod = activeMod, index >= 1 && index < mod.instruments.count,
              let selection = mod.previewSelection(instrumentIndex: index) else { return }
        let smp = selection.sample
        let pcm = smp.pcm

        // IT-Samples mit ihrer C5-Bezugsrate exportieren; die bestehenden
        // MOD-/S3M-/XM-Exportregeln bleiben unveraendert.
        let sampleRate = mod.format == .it
            ? Double(smp.itProperties?.c5Speed ?? smp.c2spd)
            : 22050.0
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "ModPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Konnte Mono-Format nicht erstellen"])
        }
        
        // Ziel-Datei ggf. entfernen, damit AVAudioFile sauber neu schreiben kann.
        // "Datei nicht vorhanden" ist der Normalfall (frischer Save-Panel-Pfad) und
        // wird ignoriert; andere Fehler (z.B. Sandbox-Permissions) werden geloggt,
        // statt sie wie zuvor per try? stillschweigend zu verschlucken.
        do {
            try FileManager.default.removeItem(at: destinationURL)
        } catch CocoaError.fileNoSuchFile {
            // erwartet — Zielpfad war frei
        } catch {
            print("WAV-Export: konnte bestehende Datei nicht entfernen: \(error.localizedDescription)")
        }
        let audioFile = try AVAudioFile(forWriting: destinationURL, settings: monoFormat.settings)
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: UInt32(pcm.count)) else {
            throw NSError(domain: "ModPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Konnte Buffer nicht erstellen"])
        }

        pcmBuffer.frameLength = UInt32(pcm.count)
        if let channelData = pcmBuffer.floatChannelData?[0] {
            // PCM ist bereits normalisiert (Float-Engine) — direkt schreiben.
            for i in 0..<pcm.count {
                channelData[i] = pcm[i]
            }
        }
        
        try audioFile.write(from: pcmBuffer)
    }
}

#endif
