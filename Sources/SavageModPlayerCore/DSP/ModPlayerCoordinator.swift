import Foundation
import AVFoundation
import Combine

// Haelt den verbleibenden Frame-Zaehler der laufenden Instrument-Vorschau.
// Wird vom Preview-Render-Block (Audio-Thread) heruntergezaehlt — daher dieselbe
// nonisolated(unsafe)-Konvention wie RealtimePlaybackState.
public final class PreviewVoice: Sendable {
    nonisolated(unsafe) public var framesLeft: Int
    public init(framesLeft: Int) { self.framesLeft = framesLeft }
}

public final class RealtimePlaybackState: Sendable {
    nonisolated(unsafe) public var position: Int = -1
    nonisolated(unsafe) public var rowIndex: Int = 63
    nonisolated(unsafe) public var tick: Int = 5
    nonisolated(unsafe) public var ticksPerRow: Int = 6
    nonisolated(unsafe) public var bpm: Int = 125
    nonisolated(unsafe) public var outputsPerTick: Double = 0.0
    nonisolated(unsafe) public var outputsUntilNextTick: Double = 0.0
    // IT T0x/T1x verändert das Tempo auf den Folgeticks einer Zeile.
    nonisolated(unsafe) public var tempoSlide: Int = 0
    
    nonisolated(unsafe) public var positionJump: Int = -1
    nonisolated(unsafe) public var patternBreak: Int = -1
    nonisolated(unsafe) public var patternLoopRow: Int = -1
    nonisolated(unsafe) public var patternDelay: Int = 0
    nonisolated(unsafe) public var patternDelayCounter: Int = 0
    
    // New parameters for user controls
    nonisolated(unsafe) public var stereoSeparation: Float = 0.8
    nonisolated(unsafe) public var useInterpolation: Bool = true
    nonisolated(unsafe) public var palClock: Bool = true

    // Globale Lautstärke: 0...64 für MOD/S3M/XM, 0...128 für IT.
    nonisolated(unsafe) public var globalVolume: Float = 64

    // S3M rechnet Perioden gegen die feste ST3-Clock (14317056 Hz) statt
    // gegen die Amiga-Paula-Clock. 0 = kein Override (PAL/NTSC-Schalter gilt).
    nonisolated(unsafe) public var clockRateOverride: Double = 0
    
    // Elapsed frames for timing calculation
    nonisolated(unsafe) public var elapsedFrames: UInt64 = 0
    nonisolated(unsafe) public var waveWriteIndex: Int = 0
    // Eigener, ueber Callback-Grenzen rollender Index fuer das Master-Oszilloskop.
    // (Frueher mit dem Callback-lokalen frame & 127 indiziert — bei Buffern < 128
    // Frames blieb das Ende des Scopes stehen und es ruckelte zwischen Callbacks.)
    nonisolated(unsafe) public var masterWaveWriteIndex: Int = 0
    // Wird im Renderblock gesetzt, wenn der Song hinter die letzte Position laeuft
    // (Wrap auf 0). Der MainActor-Poller liest das Flag und meldet das Songende,
    // damit die UI den loopMode (none/track/playlist) auswerten kann.
    nonisolated(unsafe) public var endReached: Bool = false

    public init() {}
}

public final class RealtimeVUBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<Float>
    public init(pointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
    }
}

public final class RealtimeWaveBuffer: @unchecked Sendable {
    public let channelWavesPointer: UnsafeMutablePointer<Float>
    public let masterWavesPointer: UnsafeMutablePointer<Float>

    public init(channelWaves: UnsafeMutablePointer<Float>, masterWaves: UnsafeMutablePointer<Float>) {
        self.channelWavesPointer = channelWaves
        self.masterWavesPointer = masterWaves
    }
}

// Vorallozierte Capture-Pointer fuer genau EINEN Renderblock. Die Pointer
// werden vor dem Audio-Callback vom Offline-Renderer bereitgestellt und nach
// dessen Rueckkehr synchron in RenderCaptureBlock kopiert.
struct RenderCapture: @unchecked Sendable {
    let stereoLeftPointer: UnsafeMutablePointer<Float>
    let stereoRightPointer: UnsafeMutablePointer<Float>
    let stemsPointer: UnsafeMutablePointer<Float>
    let frameCapacity: Int
    let channelCount: Int
}

// Wertkopie eines fertigen Blocks fuer den Offline-Consumer. Diese Arrays
// entstehen erst nach dem Callback und sind deshalb kein Echtzeit-Arbeitsschritt.
struct RenderCaptureBlock: Sendable {
    let frameCount: Int
    let channelCount: Int
    let stereoLeft: [Float]
    let stereoRight: [Float]
    // Kanal-major: stems[channel * frameCount + frame].
    let stems: [Float]
}

// Wertkopie des Sequencer-Zustands an einer festen Frame-Grenze. Sie enthaelt
// bewusst keine Referenz auf den laufenden Zustand und kein endReached: Die
// Probe setzt dieses Live-/Offline-Abbruchsignal heute nicht.
struct SequencerTraceSnapshot: Sendable, Equatable {
    let frame: Int
    let position: Int
    let pattern: Int
    let row: Int
    let tick: Int
    let speed: Int
    let tempo: Int
    let globalVolume: Float
    let positionJump: Int
    let patternBreak: Int
    let patternLoopRow: Int
    let patternDelay: Int
    let patternDelayCounter: Int

    init(frame: Int, state: RealtimePlaybackState, mod: Mod) {
        self.frame = frame
        self.position = state.position
        if mod.patternTable.isEmpty {
            self.pattern = -1
        } else {
            let positionIndex = max(0, min(mod.patternTable.count - 1, state.position))
            self.pattern = mod.patternTable[positionIndex]
        }
        self.row = state.rowIndex
        self.tick = state.tick
        self.speed = state.ticksPerRow
        self.tempo = state.bpm
        self.globalVolume = state.globalVolume
        self.positionJump = state.positionJump
        self.patternBreak = state.patternBreak
        self.patternLoopRow = state.patternLoopRow
        self.patternDelay = state.patternDelay
        self.patternDelayCounter = state.patternDelayCounter
    }
}

struct RenderProbeSample: Sendable {
    let frame: Int
    let position: Int
    let row: Int
    let channelOutputs: [Float]
    let trace: SequencerTraceSnapshot

    init(frame: Int, position: Int, row: Int, channelOutputs: [Float], trace: SequencerTraceSnapshot) {
        self.frame = frame
        self.position = position
        self.row = row
        self.channelOutputs = channelOutputs
        self.trace = trace
    }
}

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
            state.outputsPerTick = sampleRate * 60.0 / (Double(bpm) * 24.0)
        }
    }
    @Published public var speed = 6 {
        didSet {
            // Analog zu `bpm`: Speed = Ticks pro Zeile an den Echtzeit-Zustand geben.
            guard let state = playbackState, state.ticksPerRow != speed, speed > 0 else { return }
            state.ticksPerRow = speed
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
    
    // Obergrenze der unterstützten Kanäle — bestimmt die Größe der
    // vorallozierten VU-/Waveform-Puffer (S3M erlaubt bis zu 32 Kanäle).
    // IT-Patterns besitzen bis zu 64 logische Kanäle. Die zugehörigen
    // VU-/Scope-Puffer werden wie zuvor einmalig vor dem Audiostart reserviert.
    nonisolated public static let maxChannels = 64
    nonisolated public static let itVoiceCapacity = ITPlaybackVoicePool.voiceCapacity

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
        self.peakLevelsPointer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChannels)
        for i in 0..<Self.maxChannels {
            self.peakLevelsPointer[i] = 0.0
        }
        self.masterWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        for i in 0..<128 {
            self.masterWavesPointer[i] = 0.0
        }
        self.channelWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChannels * 32) // je Kanal 32 Samples
        for i in 0..<(Self.maxChannels * 32) {
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
        let count = max(1, min(Self.maxChannels, mod.channelCount))
        // Nur der IT-Instrument-Modus braucht NNA-Hintergrundstimmen. Im
        // Sample-Modus bleibt die direkte 64-Kanal-Zuordnung deutlich billiger.
        let voiceCount = mod.format == .it && mod.itProperties?.usesInstruments == true
            ? Self.itVoiceCapacity
            : count
        self.channels = (1...voiceCount).map { DSPChannel(index: $0) }
        Self.configure(channels: self.channels, for: mod)
        self.channelCount = count
        self.visualizerState.resize(channelCount: count)

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

    // Format-abhängige Kanal-Konfiguration: Panning aus dem Modul, bei S3M
    // zusätzlich das ScreamTracker-Periodenmodell (feinere Perioden, weitere
    // Klemmgrenzen, Effekt-Memory). Muss nach jedem DSPChannel.reset() erneut
    // angewandt werden (reset() stellt die MOD-Defaults wieder her).
    nonisolated static func configure(channels: [DSPChannel], for mod: Mod) {
        if mod.format == .it {
            ITPlaybackVoicePool(mod: mod).configure(voices: channels)
            return
        }
        for (i, ch) in channels.enumerated() {
            if i < mod.channelPannings.count {
                ch.panning = mod.channelPannings[i]
            }
            if mod.format == .s3m {
                ch.s3mMode = true
                ch.periodScale = 4
                ch.periodMin = 64
                ch.periodMax = 32767
            } else if mod.format == .xm {
                // Lineares XM-Frequenzmodell. Perioden reichen bis ~7680 (tiefste
                // Note), darum weite Klemmgrenzen. Amiga-Frequenz-XMs (selten,
                // mod.linearFrequency == false) werden vorerst über dasselbe
                // lineare Modell approximiert — echte Amiga-Periodentabelle ist
                // ein späterer Feinschliff (TODO).
                ch.xmLinearMode = true
                ch.periodMin = 1
                ch.periodMax = 7680
            }
        }
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
        Self.configure(channels: channels, for: mod)

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
        state.position = -1
        state.rowIndex = 63
        // Start-Tempo aus den aktuellen Coordinator-Werten (self.bpm/self.speed)
        // statt stur aus dem Modul-Header: setMod() setzt beide beim Songwechsel
        // ohnehin auf die Header-Werte, aber eine im gestoppten Zustand per
        // Stepper gewaehlte Aenderung bleibt so erhalten und wird beim Play nicht
        // sofort wieder ueberschrieben. Song-eigene Tempo-Effekte (Fxx) greifen
        // waehrend der Wiedergabe weiterhin.
        state.tick = self.speed - 1
        state.ticksPerRow = self.speed
        state.bpm = self.bpm
        state.outputsPerTick = sampleRate * 60.0 / (Double(self.bpm) * 24.0)
        state.outputsUntilNextTick = 0.0
        state.positionJump = -1
        state.patternBreak = -1
        state.patternLoopRow = -1
        state.patternDelay = 0
        state.patternDelayCounter = 0
        state.stereoSeparation = self.stereoSeparation
        state.useInterpolation = self.useInterpolation
        state.palClock = self.palClock
        state.globalVolume = Float(mod.initialGlobalVolume)
        state.clockRateOverride = (mod.format == .s3m || mod.format == .it) ? 14317056.0 : 0
        state.elapsedFrames = 0

        // Wurde im gestoppten Zustand per Slider eine Startposition gewaehlt,
        // dort beginnen: eine Position davor auf der letzten Zeile stehen —
        // der erste Tick-Boundary laedt dann (startPos, Zeile 0) frisch.
        if let startPos = pendingStartPosition, startPos >= 0, startPos < mod.length {
            if let startRow = pendingStartRow, startRow > 0 {
                // Zeilen-genauer Start (Grid-Klick): direkt auf (startPos, startRow)
                // setzen — eine Zeile davor auf dem letzten Tick, damit der erste
                // Tick-Boundary die Zielzeile frisch laedt und triggert.
                state.position = startPos
                state.rowIndex = startRow - 1
                state.tick = state.ticksPerRow - 1
                state.elapsedFrames = UInt64(Double(Self.cumulativeRows(mod, upTo: startPos, row: startRow) * state.ticksPerRow) * state.outputsPerTick)
            } else if startPos > 0 {
                state.position = startPos - 1
                state.elapsedFrames = UInt64(Double(Self.cumulativeRows(mod, upTo: startPos) * mod.initialSpeed) * state.outputsPerTick)
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
        
        let renderBlock = Self.createRenderBlock(
            state: state,
            vuBuffer: vuBuffer,
            waveBuffer: waveBuffer,
            dspChannels: dspChannels,
            mod: mod,
            sampleRate: sampleRate
        )
        
        let sourceNode = AVAudioSourceNode(renderBlock: renderBlock)
        
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

    // Ermittelt Speed/Tempo/Global-Volume an einem Sprungziel (position,row): wendet
    // alle Set-Speed/Tempo/Global-Volume-Befehle vom Songanfang bis dorthin der
    // Reihe nach an. Damit klingt ein Sprung mitten in den Song im RICHTIGEN Tempo
    // (z.B. Starfish: Speed 8 wird in Pattern-Pos 0, Zeile 0 gesetzt). Folgt bewusst
    // KEINEN Pattern-Spruengen (Bxx/Dxx) und rekonstruiert KEINE Per-Kanal-Slides —
    // fuer den linearen Normalfall und Test-Spruenge gedacht.
    nonisolated static func reconstructGlobalParams(_ mod: Mod, toPosition: Int, row: Int)
        -> (speed: Int, bpm: Int, globalVolume: Int) {
        var speed = mod.initialSpeed
        var bpm = mod.initialTempo
        var gvol = mod.initialGlobalVolume
        func scan(_ r: Row) {
            for n in r.notes where n.hasEffect {
                if n.effectId > ModuleEffect.impulseTrackerCommandBase,
                   n.effectId <= ModuleEffect.impulseTrackerCommandBase + 26 {
                    switch n.effectId - ModuleEffect.impulseTrackerCommandBase {
                    case 1:
                        if n.effectData > 0 { speed = n.effectData }
                    case 20:
                        if n.effectData >= 0x20 { bpm = n.effectData }
                    case 22:
                        if n.effectData <= 128 { gvol = n.effectData }
                    default:
                        break
                    }
                } else if n.effectId == 0x0F {
                    if n.effectData >= 1 && n.effectData <= 31 { speed = n.effectData }
                    else if n.effectData >= 32 { bpm = n.effectData }
                } else if n.effectId == ModuleEffect.setSpeed {
                    if n.effectData > 0 { speed = n.effectData }
                } else if n.effectId == ModuleEffect.setTempo {
                    if n.effectData >= 32 { bpm = n.effectData }
                } else if n.effectId == ModuleEffect.globalVolume {
                    gvol = min(64, max(0, n.effectData))
                }
            }
        }
        let lastPos = max(0, min(mod.length - 1, toPosition))
        for p in 0...lastPos {
            let posIndex = max(0, min(mod.patternTable.count - 1, p))
            let patternIndex = mod.patternTable[posIndex]
            guard patternIndex >= 0 && patternIndex < mod.patterns.count else { continue }
            let rows = mod.patterns[patternIndex].rows
            let maxRow = (p == lastPos) ? min(row, rows.count - 1) : rows.count - 1
            guard maxRow >= 0 else { continue }
            for r in 0...maxRow { scan(rows[r]) }
        }
        return (speed, bpm, gvol)
    }

    // Zeilen-genauer Sprung: Grid-Klick auf eine Zeile. Rekonstruiert Speed/Tempo/
    // Global-Volume, damit die Wiedergabe ab dort im richtigen Tempo laeuft.
    public func seek(toPosition pos: Int, row: Int) {
        guard let mod = activeMod else { return }
        let p = max(0, min(mod.length - 1, pos))
        let r = max(0, min(Self.patternRowCount(mod, at: p) - 1, row))
        let params = Self.reconstructGlobalParams(mod, toPosition: p, row: r)
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
        state.outputsPerTick = sampleRate * 60.0 / (Double(params.bpm) * 24.0)
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

        let currentRows = Self.cumulativeRows(mod, upTo: state.position, row: max(0, state.rowIndex))
        var targetRows = currentRows + Int((delta / rowDuration).rounded())
        let totalRows = Self.cumulativeRows(mod, upTo: mod.length)
        targetRows = max(0, min(totalRows - 1, targetRows))
        let target = Self.positionAndRow(mod, forGlobalRow: targetRows)
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

        let sampleRate = self.audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
        let outputsPerTick = sampleRate * 60.0 / (Double(state.bpm) * 24.0)
        state.elapsedFrames = UInt64(Double(Self.cumulativeRows(mod, upTo: position, row: row) * state.ticksPerRow) * outputsPerTick)

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
        let count = min(channelCount, Self.maxChannels)
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

        // Read progress directly from shared state (100% lock-free, allocation-free)
        if let state = self.playbackState {
            // Songende-Signal aus dem Renderblock auf den MainActor heben.
            if state.endReached {
                state.endReached = false
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

            if let mod = self.activeMod {
                // Schaetzung ueber die aktuelle Zeilendauer: Ticks/Zeile *
                // Tickdauer (60/(BPM*24)). Die alte Formel nahm implizit
                // Speed 6 an — bei anderen Speeds lief die Elapsed-Zeit dann
                // ueber die angezeigte Gesamtdauer hinaus.
                let currentBpm = state.bpm > 0 ? Double(state.bpm) : 125.0
                let ticksPerRow = Double(max(1, state.ticksPerRow))
                vis.totalDuration = Double(Self.cumulativeRows(mod, upTo: mod.length)) * ticksPerRow * 60.0 / (currentBpm * 24.0)
            }
        }
    }
    
    private func startVUUpdates() {
        // 30 Hz statt 50 Hz: VU/Oszilloskope bleiben flüssig, aber jeder Tick
        // stößt SwiftUI-Layout an — 30 Hz senkt die UI-CPU spürbar (2026-07-09).
        let timer = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
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
    
    // internal statt private: ModuleRenderer (WAV-Offline-Render für Export
    // und Quick-Look) nutzt denselben Render-Block wie die Live-Wiedergabe.
    nonisolated static func createRenderBlock(
        state: RealtimePlaybackState,
        vuBuffer: RealtimeVUBuffer,
        waveBuffer: RealtimeWaveBuffer,
        dspChannels: [DSPChannel],
        mod: Mod,
        sampleRate: Double,
        capture: RenderCapture? = nil
    ) -> @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        // Kanalzahl und Mix-Gain einmalig ableiten: Mehr als 4 Kanäle laufen
        // sonst deutlich heißer in den tanh-Limiter als das klassische
        // 4-Kanal-Bild. Equal-Power-Skalierung sqrt(4/N) statt linearem 4/N:
        // unkorrelierte Kanäle addieren sich in Leistung, nicht in Amplitude —
        // lineares 4/N machte 16-Kanal-S3Ms ~12 dB zu leise (praktisch stumm).
        // Rest-Spitzen fängt der tanh-Limiter weich ab.
        let voiceCount = dspChannels.count
        let logicalChannelCount = mod.format == .it
            ? max(1, min(Self.maxChannels, mod.channelCount))
            : voiceCount
        let itVoicePool = mod.format == .it ? dspChannels.first?.itVoicePool : nil
        let mixGain: Float
        if mod.format == .it {
            // ITs reservieren stets 64 logische Kanäle; deren Zahl darf den Mix
            // nicht pauschal absenken. Stattdessen ist das Headerfeld Mixing
            // Volume (0...128, 64 = neutral) der vorgesehene Masterfaktor.
            mixGain = Float(mod.itProperties?.mixVolume ?? 64) / 64.0
        } else {
            mixGain = voiceCount > 4 ? (4.0 / Float(voiceCount)).squareRoot() : 1.0
        }
        let globalVolumeScale = Float(mod.globalVolumeScale.rawValue)

        return { (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)

            guard buffers.count >= 2,
                  let leftPtr = buffers[0].mData,
                  let rightPtr = buffers[1].mData else {
                return noErr
            }

            let left = leftPtr.assumingMemoryBound(to: Float.self)
            let right = rightPtr.assumingMemoryBound(to: Float.self)

            let safeFrameCount = Int(frameCount)

            for frame in 0..<safeFrameCount {
                SequencerCore.advanceIfNeeded(
                    state: state,
                    channels: dspChannels,
                    mod: mod,
                    sampleRate: sampleRate
                )

                state.outputsUntilNextTick -= 1.0
                state.elapsedFrames += 1

                // Mischen der Kanäle
                var outL: Float = 0.0
                var outR: Float = 0.0

                var hasSolo = false
                if let itVoicePool {
                    for channel in 0..<itVoicePool.logicalChannelCount {
                        if itVoicePool.patternChannels[channel].isSoloed {
                            hasSolo = true
                            break
                        }
                    }
                } else {
                    for channel in 0..<logicalChannelCount where dspChannels[channel].isSoloed {
                        hasSolo = true
                        break
                    }
                }
                // Globale Lautstärke (S3M Vxx) wirkt auf alle Kanäle gleich.
                let globalGain = state.globalVolume / globalVolumeScale
                let captureStems = capture?.stemsPointer
                let captureFrameCapacity = capture?.frameCapacity ?? 0

                // Roll the wave sample write index
                state.waveWriteIndex = (state.waveWriteIndex + 1) % 32
                let wIdx = state.waveWriteIndex

                // Der sichtbare Kanalpuffer und die Capture-Stems gehören den
                // logischen Kanälen, nicht den bis zu 256 physischen Stimmen.
                for channel in 0..<logicalChannelCount {
                    waveBuffer.channelWavesPointer[channel * 32 + wIdx] = 0.0
                    if let captureStems {
                        captureStems[channel * captureFrameCapacity + frame] = 0.0
                    }
                }

                let renderedVoiceCount = itVoicePool?.usesBackgroundVoices == true
                    ? itVoicePool!.activeVoiceCount
                    : voiceCount
                for renderPosition in 0..<renderedVoiceCount {
                    let voiceIndex = itVoicePool?.usesBackgroundVoices == true
                        ? itVoicePool!.activeVoiceIndex(at: renderPosition)
                        : renderPosition
                    let ch = dspChannels[voiceIndex]
                    let ownerIndex = itVoicePool == nil
                        ? voiceIndex
                        : (ch.itPatternState?.channelIndex ?? -1)
                    guard ownerIndex >= 0, ownerIndex < logicalChannelCount else { continue }
                    let outputSample = Self.renderChannelSample(
                        channel: ch,
                        useInterpolation: state.useInterpolation
                    ) * globalGain

                    // Roh-Stem vor Panning, Mix-Gain und Limiter. Bei Capture=nil
                    // bleibt dies nur ein einfacher optionaler Pointer-Check.
                    if let captureStems {
                        captureStems[ownerIndex * captureFrameCapacity + frame] += outputSample
                    }

                    // Mute / Solo logic
                    let ownerState = ch.itPatternState
                    var isChannelMuted = ownerState?.isMuted ?? ch.isMuted
                    if hasSolo && !(ownerState?.isSoloed ?? ch.isSoloed) {
                        isChannelMuted = true
                    }

                    if isChannelMuted {
                        continue
                    }

                    // Alle Vorder-/Hintergrundstimmen eines Besitzers addieren.
                    waveBuffer.channelWavesPointer[ownerIndex * 32 + wIdx] += outputSample

                    // Panning LRRL mit Separation (XM: inkl. Panning-Hüllkurve)
                    let p = ch.effectivePanning
                    let separation = state.stereoSeparation
                    let pEffective = max(0.0, min(1.0, 0.5 + (p - 0.5) * separation))
                    let lGain = 1.0 - pEffective
                    let rGain = pEffective

                    outL += outputSample * lGain * mixGain
                    outR += outputSample * rGain * mixGain

                }

                for channel in 0..<logicalChannelCount {
                    let absVal = abs(waveBuffer.channelWavesPointer[channel * 32 + wIdx])
                    if absVal > vuBuffer.pointer[channel] {
                        vuBuffer.pointer[channel] = absVal
                    }
                }

                // Float-Stereo unmittelbar vor dem tanh-Limiter sichern.
                if let capture {
                    capture.stereoLeftPointer[frame] = outL
                    capture.stereoRightPointer[frame] = outR
                }
                
                // Soft Limiter (Hyperbolic Tangent) gegen Clipping
                let limitedL = tanh(outL)
                let limitedR = tanh(outR)
                left[frame] = limitedL
                right[frame] = limitedR
                // Master-Scope als echter, ueber Callbacks rollender Ringpuffer
                // (wie waveWriteIndex oben), damit alle 128 Slots stetig gefuellt
                // werden — kein stehender/ruckelnder Tail bei kleinen Buffern.
                state.masterWaveWriteIndex = (state.masterWaveWriteIndex + 1) & 127
                waveBuffer.masterWavesPointer[state.masterWaveWriteIndex] = (limitedL + limitedR) * 0.5
            }
            
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
              // C-4-Sample über die Keymap (MOD/S3M: das einzige Sample).
              let smp = inst.sample(forNote: 48), smp.pcm.count > 0 else { return }

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
        let clockRate = mod.format == .s3m ? 14317056.0 : (self.palClock ? 3546894.6 : 3579545.25)
        ch.sampleSpeed = ch.currentPeriod > 0 ? (clockRate / Double(ch.currentPeriod)) / sampleRate : 0.0

        // Frame-Budget: geloopte Samples nach ~1,6 s ausklingen lassen (sonst
        // droehnen sie endlos); nicht-geloopte enden ohnehin von selbst, weil
        // renderChannelSample hinter dem Sample-Ende 0 liefert.
        let voice = PreviewVoice(framesLeft: Int(sampleRate * 1.6))
        let renderBlock = Self.createPreviewRenderBlock(channel: ch, voice: voice, useInterpolation: self.useInterpolation)

        let sourceNode = AVAudioSourceNode(renderBlock: renderBlock)
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

    // Minimaler Render-Block der Vorschau: genau EIN Kanal, mittig gepannt, ohne
    // Sequencer/Effekte. Nach Ablauf des Frame-Budgets gibt er Stille aus.
    nonisolated static func createPreviewRenderBlock(
        channel ch: DSPChannel,
        voice: PreviewVoice,
        useInterpolation: Bool
    ) -> @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        return { (_, _, frameCount, outputData) -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2, let leftPtr = buffers[0].mData, let rightPtr = buffers[1].mData else { return noErr }
            let left = leftPtr.assumingMemoryBound(to: Float.self)
            let right = rightPtr.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                var s: Float = 0.0
                if voice.framesLeft > 0 {
                    s = Self.renderChannelSample(channel: ch, useInterpolation: useInterpolation)
                    voice.framesLeft -= 1
                }
                // Mittig; tanh als weicher Schutz gegen Clipping (der Song-Limiter
                // fehlt hier, ein Einzel-Sample bleibt aber ohnehin bei ~+/-0,5).
                let limited = tanh(s)
                left[frame] = limited
                right[frame] = limited
            }
            return noErr
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

    // Frisch konfigurierte Offline-Render-Kanäle für ein Modul (Panning +
    // Format-Modell), z.B. für WAV-Export, Render-Probe und Quick-Look.
    nonisolated static func makeRenderChannels(for mod: Mod) -> [DSPChannel] {
        let logicalCount = max(1, min(Self.maxChannels, mod.channelCount))
        let count = mod.format == .it && mod.itProperties?.usesInstruments == true
            ? Self.itVoiceCapacity
            : logicalCount
        let renderChannels = (1...count).map { DSPChannel(index: $0) }
        configure(channels: renderChannels, for: mod)
        return renderChannels
    }

    // Startzustand des Sequencers für ein Modul (Header-Tempo, Global Volume,
    // S3M-Clock). position/-rowIndex/-tick stehen so, dass der erste Frame
    // sofort Zeile 0 lädt.
    nonisolated static func makeRenderState(for mod: Mod, sampleRate: Double) -> RealtimePlaybackState {
        let state = RealtimePlaybackState()
        state.position = -1
        state.rowIndex = 63
        state.tick = mod.initialSpeed - 1
        state.ticksPerRow = mod.initialSpeed
        state.bpm = mod.initialTempo
        state.outputsPerTick = sampleRate * 60.0 / (Double(mod.initialTempo) * 24.0)
        state.outputsUntilNextTick = 0.0
        state.globalVolume = Float(mod.initialGlobalVolume)
        state.clockRateOverride = (mod.format == .s3m || mod.format == .it) ? 14317056.0 : 0
        return state
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

        let renderChannels = Self.makeRenderChannels(for: mod)
        let state = Self.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = stereoSeparation
        state.useInterpolation = useInterpolation
        state.palClock = palClock

        let channelCount = mod.format == .it
            ? max(1, min(Self.maxChannels, mod.channelCount))
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
        
        let block = Self.createRenderBlock(
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
        
        let totalFramesToRender = UInt64(sampleRate * durationSeconds)
        var renderedFrames: UInt64 = 0
        
        var isSilence = ObjCBool(false)
        var timeStamp = AudioTimeStamp()
        
        while renderedFrames < totalFramesToRender {
            pcmBuffer.frameLength = blockFrames
            let abl = pcmBuffer.mutableAudioBufferList
            
            let status = block(&isSilence, &timeStamp, blockFrames, abl)
            if status != noErr {
                throw NSError(domain: "ModPlayer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Audio-Render-Fehler"])
            }
            
            try audioFile.write(from: pcmBuffer)
            renderedFrames += UInt64(blockFrames)
            
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
        let renderChannels = Self.makeRenderChannels(for: mod)
        let channelCount = mod.format == .it
            ? max(1, min(Self.maxChannels, mod.channelCount))
            : renderChannels.count
        let state = Self.makeRenderState(for: mod, sampleRate: sampleRate)
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
                    channelOutputs[owner] += Self.renderChannelSample(
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

    // Reihenzahl des Patterns an der gegebenen Song-Position. XM-Patterns haben
    // variable Länge (1..256 Reihen); MOD/S3M sind immer 64. Wird beim Row-Wrap
    // gebraucht, damit ein kurzes Pattern nach seiner letzten echten Reihe
    // umbricht — nicht erst bei fixen 64 (sonst 34 leere Reihen bei 30-Reihen-
    // Patterns → Timing-Drift + weiterlaufende Volume-Slides). Allokationsfrei
    // (nur Array-Index-Zugriffe), damit im Echtzeit-Render-Block nutzbar.
    nonisolated static func patternRowCount(_ mod: Mod, at position: Int) -> Int {
        SequencerCore.patternRowCount(mod, at: position)
    }

    // Globaler Zeilen-Index: Summe der ECHTEN Pattern-Reihen aller Positionen vor
    // `position`, plus `row`. Ersetzt die frühere (position*64 + row)-Annahme, die
    // bei XM mit variablen Pattern-Längen die Elapsed-/Gesamtzeit und die
    // Positionsanzeige verfälschte (z.B. Starfish: 212s statt 178s angezeigt).
    // Nicht im Audio-Thread aufrufen (O(Positionen)); nur bei Seek/Zeitanzeige.
    nonisolated static func cumulativeRows(_ mod: Mod, upTo position: Int, row: Int = 0) -> Int {
        let clamped = max(0, min(mod.length, position))
        var total = 0
        for p in 0..<clamped { total += patternRowCount(mod, at: p) }
        return total + max(0, row)
    }

    // Umkehrung von `cumulativeRows`: globaler Zeilen-Index -> (Position, Zeile)
    // entlang der echten Pattern-Längen. Für den relativen Zeitsprung (+/- s).
    nonisolated static func positionAndRow(_ mod: Mod, forGlobalRow globalRow: Int) -> (position: Int, row: Int) {
        var remaining = max(0, globalRow)
        for p in 0..<max(0, mod.length) {
            let rows = patternRowCount(mod, at: p)
            if remaining < rows { return (p, remaining) }
            remaining -= rows
        }
        let last = max(0, mod.length - 1)
        return (last, max(0, patternRowCount(mod, at: last) - 1))
    }

    @inline(__always)
    nonisolated private static func renderChannelSample(channel ch: DSPChannel, useInterpolation: Bool) -> Float {
        // Note-Cut, Key-Off und Stop setzen dieses Flag. Besonders geloopte
        // Samples wuerden ohne den Guard trotz gestoppter Stimme weiterklingen.
        guard ch.playing else { return 0.0 }
        guard let smp = ch.sample, smp.pcm.count > 0, ch.currentPeriod > 0 else { return 0.0 }
        guard ch.sampleIndex.isFinite, !ch.sampleIndex.isNaN else { return 0.0 }

        if smp.isLooped {
            wrapLoopedSampleIndexIfNeeded(channel: ch, sample: smp)
        }

        let idx = Int(ch.sampleIndex)
        guard idx >= 0, idx < smp.pcm.count else {
            // Ein beendetes One-Shot bleibt beendet. Das ist insbesondere für
            // IT Qxy wichtig: sehr kurze Samples werden nicht später aus dem
            // Nichts erneut gestartet.
            if !smp.isLooped { ch.playing = false }
            return 0.0
        }

        let sampleVal: Float
        if smp.isLooped && useInterpolation {
            sampleVal = ch.getInterpolatedSampleLooped(
                from: smp.pcm,
                index: ch.sampleIndex,
                repeatOffset: smp.loopStart,
                repeatLength: smp.loopLength
            )
        } else if useInterpolation {
            sampleVal = ch.getInterpolatedSample(from: smp.pcm, index: ch.sampleIndex)
        } else {
            sampleVal = ch.getNearestSample(from: smp.pcm, index: ch.sampleIndex)
        }

        // sampleDirection ist bei MOD/S3M immer +1 (unverändert); nur XM-Ping-Pong
        // dreht sie auf -1. xmVolumeScale ist bei MOD/S3M 1.0 (Envelope/Fadeout aus).
        ch.sampleIndex += ch.sampleSpeed * ch.sampleDirection
        if smp.isLooped {
            wrapLoopedSampleIndexIfNeeded(channel: ch, sample: smp)
        }

        return sampleVal * ch.currentVolume / 64.0 * ch.xmVolumeScale * ch.itVolumeScale
    }

    nonisolated private static func wrapLoopedSampleIndexIfNeeded(channel ch: DSPChannel, sample smp: Sample) {
        let frameCount = smp.pcm.count
        let loopStart = max(0, min(smp.loopStart, frameCount - 1))
        let declaredLoopEnd = smp.loopStart + smp.loopLength
        let loopEnd = max(loopStart + 1, min(declaredLoopEnd, frameCount))
        guard loopEnd > loopStart else { return }

        let start = Double(loopStart)
        let end = Double(loopEnd)
        let length = end - start

        if smp.loopType == .pingpong {
            // Ping-Pong: an den Loop-Grenzen die Richtung umkehren und den
            // Überschuss zurückreflektieren. Spiegel um die Grenze (2·Grenze−pos)
            // OHNE Endpunkt-Duplizierung — wie openmpt/FT2. (Früher `end-1-over`:
            // spiegelte einen Sample zu tief und wiederholte den Endpunkt, was bei
            // langen gehaltenen Ping-Pong-Noten einen Timbre-Drift akkumulierte.)
            if ch.sampleDirection > 0, ch.sampleIndex >= end {
                let over = (ch.sampleIndex - end).truncatingRemainder(dividingBy: length)
                ch.sampleIndex = end - over
                ch.sampleDirection = -1
            } else if ch.sampleDirection < 0, ch.sampleIndex < start {
                let under = (start - ch.sampleIndex).truncatingRemainder(dividingBy: length)
                ch.sampleIndex = start + under
                ch.sampleDirection = 1
            }
        } else if ch.sampleIndex >= end {
            // Vorwärts-Loop: in den Repeat-Bereich zurückfalten. Der alte Swift-
            // Code setzte hart auf repeatOffset und konnte bei genauem Loop-Ende
            // kurzzeitig ausserhalb der gültigen Sampledaten landen.
            ch.sampleIndex = start + (ch.sampleIndex - start).truncatingRemainder(dividingBy: length)
        }
    }
    
    public func exportInstrumentToWav(index: Int, destinationURL: URL) throws {
        guard let mod = activeMod, index >= 1 && index < mod.instruments.count,
              let inst = mod.instruments[index],
              let smp = inst.primarySample, smp.pcm.count > 0 else { return }
        let pcm = smp.pcm

        let sampleRate = 22050.0 // Standard Amiga sample rate
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
