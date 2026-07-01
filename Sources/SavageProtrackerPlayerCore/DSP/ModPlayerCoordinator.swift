import Foundation
import AVFoundation
import Combine

public final class RealtimePlaybackState: Sendable {
    nonisolated(unsafe) public var position: Int = -1
    nonisolated(unsafe) public var rowIndex: Int = 63
    nonisolated(unsafe) public var tick: Int = 5
    nonisolated(unsafe) public var ticksPerRow: Int = 6
    nonisolated(unsafe) public var bpm: Int = 125
    nonisolated(unsafe) public var outputsPerTick: Double = 0.0
    nonisolated(unsafe) public var outputsUntilNextTick: Double = 0.0
    
    nonisolated(unsafe) public var positionJump: Int = -1
    nonisolated(unsafe) public var patternBreak: Int = -1
    nonisolated(unsafe) public var patternLoopRow: Int = -1
    nonisolated(unsafe) public var patternDelay: Int = 0
    nonisolated(unsafe) public var patternDelayCounter: Int = 0
    
    // New parameters for user controls
    nonisolated(unsafe) public var stereoSeparation: Float = 0.8
    nonisolated(unsafe) public var useInterpolation: Bool = true
    nonisolated(unsafe) public var palClock: Bool = true
    
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

struct RenderProbeSample: Sendable {
    let frame: Int
    let position: Int
    let row: Int
    let channelOutputs: [Float]

    init(frame: Int, position: Int, row: Int, channelOutputs: [Float]) {
        self.frame = frame
        self.position = position
        self.row = row
        self.channelOutputs = channelOutputs
    }
}

@MainActor
public final class ModPlayerCoordinator: ObservableObject {
    @Published public var isPlaying = false
    @Published public var currentPosition = 0
    @Published public var currentRow = 0
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
    
    // Realtime VU Levels (für SwiftUI gebunden)
    @Published public var vuLevels: [Float] = [0.0, 0.0, 0.0, 0.0]
    
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
    
    @Published public var elapsedTime: Double = 0.0
    @Published public var totalDuration: Double = 0.0

    // Zaehlt bei jedem erreichten Songende hoch. Die UI beobachtet das per
    // onChange und wertet dort den loopMode aus (stop / Song wiederholen / naechster).
    @Published public var songEndPulse: Int = 0
    
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var lowPassFilterNode: AVAudioUnitEQ?
    
    @Published public var ledFilterActive: Bool = false {
        didSet {
            lowPassFilterNode?.bypass = !ledFilterActive
        }
    }
    
    @Published public var channelWaveforms: [[Float]] = [
        [Float](repeating: 0, count: 32),
        [Float](repeating: 0, count: 32),
        [Float](repeating: 0, count: 32),
        [Float](repeating: 0, count: 32)
    ]
    
    @Published public var masterSamples: [Float] = [Float](repeating: 0, count: 128)
    
    // Vorallozierte DSP-Daten
    private let channels = [DSPChannel(index: 1), DSPChannel(index: 2), DSPChannel(index: 3), DSPChannel(index: 4)]
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
        self.peakLevelsPointer = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        for i in 0..<4 {
            self.peakLevelsPointer[i] = 0.0
        }
        self.masterWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        for i in 0..<128 {
            self.masterWavesPointer[i] = 0.0
        }
        self.channelWavesPointer = UnsafeMutablePointer<Float>.allocate(capacity: 128) // 4 channels * 32 samples
        for i in 0..<128 {
            self.channelWavesPointer[i] = 0.0
        }
    }
    
    deinit {
        peakLevelsPointer.deallocate()
        masterWavesPointer.deallocate()
        channelWavesPointer.deallocate()
    }
    
    public func setMod(_ mod: Mod) {
        stop()
        self.activeMod = mod
        self.trackName = mod.name.isEmpty ? "Unbekannter Track" : mod.name
        self.currentPosition = 0
        self.currentRow = 0
        self.bpm = 125
        self.speed = 6
    }
    
    public func play() {
        guard let mod = activeMod, mod.length > 0 else { return }
        if isPlaying { return }
        
        // Ensure channels are fresh
        for ch in channels {
            ch.reset()
        }
        
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
        state.tick = 5
        state.ticksPerRow = 6
        state.bpm = 125
        state.outputsPerTick = sampleRate * 60.0 / (125.0 * 24.0)
        state.outputsUntilNextTick = 0.0
        state.positionJump = -1
        state.patternBreak = -1
        state.patternLoopRow = -1
        state.patternDelay = 0
        state.patternDelayCounter = 0
        state.stereoSeparation = self.stereoSeparation
        state.useInterpolation = self.useInterpolation
        state.palClock = self.palClock
        state.elapsedFrames = 0
        
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
        if let engine = audioEngine {
            engine.stop()
        }
        audioEngine = nil
        sourceNode = nil
        isPlaying = false
        stopVUUpdates()
        
        self.playbackState = nil
        
        for ch in channels {
            ch.reset()
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
    
    public func seek(toPosition: Int) {
        guard let state = playbackState, let mod = activeMod else { return }
        let pos = max(0, min(mod.length - 1, toPosition))
        state.position = pos
        state.rowIndex = 0
        state.tick = 0

        // Noch nicht konsumierte Sequenz-Sprungbefehle loeschen. Ohne das wuerde
        // ein vor dem Seek gesetzter Position-Jump (Bxx), Pattern-Break (Dxx) oder
        // Pattern-Loop (E6x) beim naechsten Row-Advance feuern und die eben
        // angesprungene Zielposition sofort wieder ueberschreiben. -1 = "inaktiv".
        state.positionJump = -1
        state.patternBreak = -1
        state.patternLoopRow = -1
        // Defensiv: ein laufender Pattern-Delay (EEx) wuerde sonst die erste Row
        // nach dem Seek unerwartet verzoegern.
        state.patternDelay = 0
        state.patternDelayCounter = 0

        let sampleRate = self.audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? 44100.0
        let outputsPerTick = sampleRate * 60.0 / (Double(state.bpm) * 24.0)
        state.elapsedFrames = UInt64(Double(pos * 64 * state.ticksPerRow) * outputsPerTick)
        
        self.currentPosition = pos
        self.currentRow = 0
    }
    
    public func toggleMute(channelIndex: Int) {
        guard channelIndex >= 0 && channelIndex < 4 else { return }
        channels[channelIndex].isMuted.toggle()
        objectWillChange.send()
    }
    
    public func toggleSolo(channelIndex: Int) {
        guard channelIndex >= 0 && channelIndex < 4 else { return }
        channels[channelIndex].isSoloed.toggle()
        objectWillChange.send()
    }
    
    public func isMuted(channelIndex: Int) -> Bool {
        guard channelIndex >= 0 && channelIndex < 4 else { return false }
        return channels[channelIndex].isMuted
    }
    
    public func isSoloed(channelIndex: Int) -> Bool {
        guard channelIndex >= 0 && channelIndex < 4 else { return false }
        return channels[channelIndex].isSoloed
    }
    
    @MainActor
    private func updateVULevelsTick() {
        var newLevels = [Float](repeating: 0, count: 4)
        for i in 0..<4 {
            let rawPeak = self.peakLevelsPointer[i]
            let prev = self.vuLevels[i]
            let attack: Float = 0.35
            let release: Float = 0.08
            
            let factor = rawPeak > prev ? attack : release
            newLevels[i] = prev + (rawPeak - prev) * factor
            
            // Reset raw peak in the C-pointer
            self.peakLevelsPointer[i] = 0.0
        }
        self.vuLevels = newLevels
        
        // Update true channel waveforms from channelWavesPointer
        var newWaves = self.channelWaveforms
        for i in 0..<4 {
            var wave = [Float](repeating: 0.0, count: 32)
            for j in 0..<32 {
                wave[j] = self.channelWavesPointer[i * 32 + j]
            }
            newWaves[i] = wave
        }
        self.channelWaveforms = newWaves
        
        // Update true master oscilloscope samples from masterWavesPointer
        var newMasterOsc = [Float](repeating: 0.0, count: 128)
        for j in 0..<128 {
            newMasterOsc[j] = self.masterWavesPointer[j]
        }
        self.masterSamples = newMasterOsc
        
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
            self.elapsedTime = Double(state.elapsedFrames) / sampleRate
            
            if let mod = self.activeMod {
                let currentBpm = state.bpm > 0 ? Double(state.bpm) : 125.0
                self.totalDuration = Double(mod.length * 64 * 60) / (currentBpm * 4.0)
            }
        }
    }
    
    private func startVUUpdates() {
        vuUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateVULevelsTick()
            }
        }
    }
    
    private func stopVUUpdates() {
        vuUpdateTimer?.invalidate()
        vuUpdateTimer = nil
        self.vuLevels = [0, 0, 0, 0]
    }
    
    // MARK: - Safe Real-Time Audio Block Construction
    
    nonisolated private static func createRenderBlock(
        state: RealtimePlaybackState,
        vuBuffer: RealtimeVUBuffer,
        waveBuffer: RealtimeWaveBuffer,
        dspChannels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) -> @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
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
                if state.outputsUntilNextTick <= 0 {
                    // Ticks erhöhen
                    state.tick += 1
                    if state.tick >= state.ticksPerRow {
                        if state.patternDelayCounter > 0 {
                            state.patternDelayCounter -= 1
                            state.tick = 0 // Wiederhole aktuelle Zeile
                        } else if state.patternDelay > 0 {
                            state.patternDelayCounter = state.patternDelay
                            state.patternDelay = 0
                            state.tick = 0 // Wiederhole aktuelle Zeile
                        } else {
                            state.tick = 0
                            
                            // Row-Wechsel
                            var targetPosition = state.position
                            var targetRow = state.rowIndex + 1
                            
                            if state.patternLoopRow >= 0 {
                                targetRow = state.patternLoopRow
                                state.patternLoopRow = -1
                            } else {
                                if state.positionJump >= 0 {
                                    targetPosition = state.positionJump
                                    targetRow = 0
                                    state.positionJump = -1
                                }
                                if state.patternBreak >= 0 {
                                    if targetPosition == state.position {
                                        targetPosition = state.position + 1
                                    }
                                    targetRow = state.patternBreak
                                    state.patternBreak = -1
                                } else if targetRow >= 64 {
                                    targetRow = 0
                                    targetPosition = state.position + 1
                                }
                            }

                            state.position = targetPosition
                            state.rowIndex = targetRow

                                    // Song-Ende: zurueck an den Anfang wrappen UND danach
                                    // dieselbe Lade-Logik durchlaufen, damit die erste Zeile
                                    // nach dem Loop frisch getriggert wird (sonst war sie stumm).
                                    // endReached signalisiert dem MainActor den Wrap (loopMode-Auswertung);
                                    // das Audio laeuft glitch-frei weiter, bis der Hauptthread reagiert.
                                    if state.position >= mod.length {
                                        state.endReached = true
                                        state.position = 0
                                    }
                                    do {
                                        // Defensive bounds check for pattern and table indices
                                        let posIndex = max(0, min(mod.patternTable.count - 1, state.position))
                                        let patternIndex = mod.patternTable[posIndex]

                                        if patternIndex >= 0 && patternIndex < mod.patterns.count {
                                            let pattern = mod.patterns[patternIndex]
                                            if state.rowIndex >= 0 && state.rowIndex < pattern.rows.count {
                                                let row = pattern.rows[state.rowIndex]
                                                if row.notes.count >= 4 {
                                                    for i in 0..<4 {
                                                        let note = row.notes[i]
                                                        let ch = dspChannels[i]
                                                        
                                                        // Jumps and breaks check
                                                        if note.hasEffect && note.effectId == 0x0B {
                                                            state.positionJump = note.effectData
                                                        } else if note.hasEffect && note.effectId == 0x0D {
                                                            // Dxx: BCD-Zielzeile. Werte > 63 (korruptes/
                                                            // ueberlanges Break) auf 0 umlenken statt die
                                                            // rowIndex unbegrenzt klettern zu lassen — sonst
                                                            // haengt der Song auf einer Phantom-Zeile fest.
                                                            let r = note.effectHigh * 10 + note.effectLow
                                                            state.patternBreak = r > 63 ? 0 : r
                                                        } else if note.hasEffect && note.effectId == 0xE6 {
                                                            if note.effectLow == 0 {
                                                                ch.patternLoopStartRow = state.rowIndex
                                                            } else {
                                                                if ch.patternLoopCount < 0 {
                                                                    ch.patternLoopCount = note.effectLow
                                                                }
                                                                if ch.patternLoopCount > 0 {
                                                                    ch.patternLoopCount -= 1
                                                                    state.patternLoopRow = ch.patternLoopStartRow
                                                                } else {
                                                                    ch.patternLoopCount = -1
                                                                }
                                                            }
                                                        } else if note.hasEffect && note.effectId == 0xEE {
                                                            if state.patternDelayCounter == 0 {
                                                                state.patternDelay = note.effectLow
                                                            }
                                                        } else if note.hasEffect && note.effectId == 0x0F {
                                                            if note.effectData >= 1 && note.effectData <= 31 {
                                                                state.ticksPerRow = note.effectData
                                                            } else if note.effectData > 0 {
                                                                state.bpm = note.effectData
                                                                // Update output clock speed
                                                                state.outputsPerTick = sampleRate * 60.0 / (Double(note.effectData) * 24.0)
                                                            }
                                                        }
                                                        
                                                        ch.playNote(note, instruments: mod.instruments)
                                                    }
                                                }
                                            }
                                        }
                                    }
                        }
                    }
                    
                    // Tick-Effekte
                    let clockRate = state.palClock ? 3546894.6 : 3579545.25
                    for i in 0..<4 {
                        dspChannels[i].performTick(tick: state.tick, sampleRate: sampleRate, clockRate: clockRate)
                    }
                    
                    state.outputsUntilNextTick += state.outputsPerTick
                }
                
                state.outputsUntilNextTick -= 1.0
                state.elapsedFrames += 1
                
                // Mischen der Kanäle
                var outL: Float = 0.0
                var outR: Float = 0.0
                
                let hasSolo = dspChannels.contains(where: { $0.isSoloed })
                
                // Roll the wave sample write index
                state.waveWriteIndex = (state.waveWriteIndex + 1) % 32
                let wIdx = state.waveWriteIndex
                
                for i in 0..<4 {
                    let ch = dspChannels[i]
                    let outputSample = Self.renderChannelSample(
                        channel: ch,
                        useInterpolation: state.useInterpolation
                    )
                    
                    // Mute / Solo logic
                    var isChannelMuted = ch.isMuted
                    if hasSolo && !ch.isSoloed {
                        isChannelMuted = true
                    }
                    
                    if isChannelMuted {
                        waveBuffer.channelWavesPointer[i * 32 + wIdx] = 0.0
                        continue
                    }
                    
                    // Write to channel waves buffer (Thread-safe, preallocated)
                    waveBuffer.channelWavesPointer[i * 32 + wIdx] = outputSample
                    
                    // Panning LRRL mit Separation
                    let p = ch.panning
                    let separation = state.stereoSeparation
                    let pEffective = max(0.0, min(1.0, 0.5 + (p - 0.5) * separation))
                    let lGain = 1.0 - pEffective
                    let rGain = pEffective
                    
                    outL += outputSample * lGain
                    outR += outputSample * rGain
                    
                    // Peak-Level
                    let absVal = abs(outputSample)
                    if absVal > vuBuffer.pointer[i] {
                        vuBuffer.pointer[i] = absVal
                    }
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
    
    public func previewInstrument(index: Int) {
        guard let mod = activeMod, index >= 1 && index < mod.instruments.count, let inst = mod.instruments[index], inst.bytes.count > 0 else { return }
        
        // Trigger preview on Channel 4
        let ch = channels[3]
        ch.reset()
        ch.instrument = inst
        ch.volume = Float(inst.volume)
        ch.currentVolume = Float(inst.volume)
        
        // C-3 note period = 214
        let finetune = Float(inst.finetune)
        ch.period = 214.0 - finetune
        ch.currentPeriod = ch.period
        ch.sampleIndex = 0.0
        ch.playing = true
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
        
        try? FileManager.default.removeItem(at: destinationURL)
        let audioFile = try AVAudioFile(forWriting: destinationURL, settings: stereoFormat.settings)
        
        let renderChannels = [DSPChannel(index: 1), DSPChannel(index: 2), DSPChannel(index: 3), DSPChannel(index: 4)]
        let state = RealtimePlaybackState()
        state.position = -1
        state.rowIndex = 63
        state.tick = 5
        state.ticksPerRow = 6
        state.bpm = 125
        state.outputsPerTick = sampleRate * 60.0 / (125.0 * 24.0)
        state.outputsUntilNextTick = 0.0
        state.stereoSeparation = stereoSeparation
        state.useInterpolation = useInterpolation
        state.palClock = palClock
        
        let dummyPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { dummyPeaks.deallocate() }
        for j in 0..<4 { dummyPeaks[j] = 0.0 }
        let vuBuffer = RealtimeVUBuffer(pointer: dummyPeaks)
        
        let dummyWaves = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { dummyWaves.deallocate() }
        for j in 0..<128 { dummyWaves[j] = 0.0 }
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
            
            if state.position >= mod.length - 1 && state.rowIndex >= 63 && state.tick >= state.ticksPerRow - 1 {
                break
            }
        }
    }

    nonisolated func renderProbe(
        mod: Mod,
        durationSeconds: Double,
        sampleRate: Double = 44100.0
    ) -> [RenderProbeSample] {
        let renderChannels = [DSPChannel(index: 1), DSPChannel(index: 2), DSPChannel(index: 3), DSPChannel(index: 4)]
        let state = RealtimePlaybackState()
        state.position = -1
        state.rowIndex = 63
        state.tick = 5
        state.ticksPerRow = 6
        state.bpm = 125
        state.outputsPerTick = sampleRate * 60.0 / (125.0 * 24.0)
        state.outputsUntilNextTick = 0.0
        state.stereoSeparation = 0.8
        state.useInterpolation = true
        state.palClock = true

        let totalFrames = Int(sampleRate * durationSeconds)
        var samples: [RenderProbeSample] = []
        samples.reserveCapacity(totalFrames / 256)

        for frame in 0..<totalFrames {
            if state.outputsUntilNextTick <= 0 {
                state.tick += 1
                if state.tick >= state.ticksPerRow {
                    if state.patternDelayCounter > 0 {
                        state.patternDelayCounter -= 1
                        state.tick = 0
                    } else if state.patternDelay > 0 {
                        state.patternDelayCounter = state.patternDelay
                        state.patternDelay = 0
                        state.tick = 0
                    } else {
                        state.tick = 0
                        Self.advanceRowForProbe(state: state, channels: renderChannels, mod: mod, sampleRate: sampleRate)
                    }
                }

                let clockRate = state.palClock ? 3546894.6 : 3579545.25
                for i in 0..<4 {
                    renderChannels[i].performTick(tick: state.tick, sampleRate: sampleRate, clockRate: clockRate)
                }
                state.outputsUntilNextTick += state.outputsPerTick
            }

            state.outputsUntilNextTick -= 1.0
            state.elapsedFrames += 1

            var channelOutputs = [Float](repeating: 0, count: 4)
            for i in 0..<4 {
                channelOutputs[i] = Self.renderChannelSample(channel: renderChannels[i], useInterpolation: state.useInterpolation)
            }

            if frame % 256 == 0 {
                samples.append(RenderProbeSample(frame: frame, position: state.position, row: state.rowIndex, channelOutputs: channelOutputs))
            }
        }

        return samples
    }

    nonisolated private static func advanceRowForProbe(
        state: RealtimePlaybackState,
        channels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) {
        var targetPosition = state.position
        var targetRow = state.rowIndex + 1

        if state.patternLoopRow >= 0 {
            targetRow = state.patternLoopRow
            state.patternLoopRow = -1
        } else {
            if state.positionJump >= 0 {
                targetPosition = state.positionJump
                targetRow = 0
                state.positionJump = -1
            }
            if state.patternBreak >= 0 {
                if targetPosition == state.position {
                    targetPosition = state.position + 1
                }
                targetRow = state.patternBreak
                state.patternBreak = -1
            } else if targetRow >= 64 {
                targetRow = 0
                targetPosition = state.position + 1
            }
        }

        state.position = targetPosition
        state.rowIndex = targetRow

        // Song-Ende: wrappen und danach Zeile 0 trotzdem laden (Parallele zum
        // Live-Renderblock), damit die erste Loop-Zeile frisch getriggert wird.
        if state.position >= mod.length {
            state.position = 0
        }

        let posIndex = max(0, min(mod.patternTable.count - 1, state.position))
        let patternIndex = mod.patternTable[posIndex]
        guard patternIndex >= 0 && patternIndex < mod.patterns.count else { return }
        let pattern = mod.patterns[patternIndex]
        guard state.rowIndex >= 0 && state.rowIndex < pattern.rows.count else { return }
        let row = pattern.rows[state.rowIndex]
        guard row.notes.count >= 4 else { return }

        for i in 0..<4 {
            let note = row.notes[i]
            let ch = channels[i]

            if note.hasEffect && note.effectId == 0x0B {
                state.positionJump = note.effectData
            } else if note.hasEffect && note.effectId == 0x0D {
                let r = note.effectHigh * 10 + note.effectLow
                state.patternBreak = r > 63 ? 0 : r
            } else if note.hasEffect && note.effectId == 0xE6 {
                if note.effectLow == 0 {
                    ch.patternLoopStartRow = state.rowIndex
                } else {
                    if ch.patternLoopCount < 0 {
                        ch.patternLoopCount = note.effectLow
                    }
                    if ch.patternLoopCount > 0 {
                        ch.patternLoopCount -= 1
                        state.patternLoopRow = ch.patternLoopStartRow
                    } else {
                        ch.patternLoopCount = -1
                    }
                }
            } else if note.hasEffect && note.effectId == 0xEE {
                if state.patternDelayCounter == 0 {
                    state.patternDelay = note.effectLow
                }
            } else if note.hasEffect && note.effectId == 0x0F {
                if note.effectData >= 1 && note.effectData <= 31 {
                    state.ticksPerRow = note.effectData
                } else if note.effectData > 0 {
                    state.bpm = note.effectData
                    state.outputsPerTick = sampleRate * 60.0 / (Double(note.effectData) * 24.0)
                }
            }

            ch.playNote(note, instruments: mod.instruments)
        }
    }

    nonisolated private static func renderChannelSample(channel ch: DSPChannel, useInterpolation: Bool) -> Float {
        guard let inst = ch.instrument, inst.bytes.count > 0, ch.currentPeriod > 0 else { return 0.0 }
        guard ch.sampleIndex.isFinite, !ch.sampleIndex.isNaN else { return 0.0 }

        if inst.isLooped {
            wrapLoopedSampleIndexIfNeeded(channel: ch, instrument: inst)
        }

        let idx = Int(ch.sampleIndex)
        guard idx >= 0, idx < min(inst.length, inst.bytes.count) else { return 0.0 }

        let sampleVal: Float
        if inst.isLooped && useInterpolation {
            sampleVal = ch.getInterpolatedSampleLooped(
                from: inst.bytes,
                index: ch.sampleIndex,
                repeatOffset: inst.repeatOffset,
                repeatLength: inst.repeatLength
            )
        } else if useInterpolation {
            sampleVal = ch.getInterpolatedSample(from: inst.bytes, index: ch.sampleIndex)
        } else {
            sampleVal = ch.getNearestSample(from: inst.bytes, index: ch.sampleIndex)
        }

        ch.sampleIndex += ch.sampleSpeed
        if inst.isLooped {
            wrapLoopedSampleIndexIfNeeded(channel: ch, instrument: inst)
        }

        return sampleVal * ch.currentVolume / 64.0
    }

    nonisolated private static func wrapLoopedSampleIndexIfNeeded(channel ch: DSPChannel, instrument inst: Instrument) {
        let byteCount = inst.bytes.count
        let loopStart = max(0, min(inst.repeatOffset, byteCount - 1))
        let declaredLoopEnd = inst.repeatOffset + inst.repeatLength
        let loopEnd = max(loopStart + 1, min(declaredLoopEnd, byteCount))
        guard loopEnd > loopStart else { return }

        let start = Double(loopStart)
        let length = Double(loopEnd - loopStart)
        if ch.sampleIndex >= Double(loopEnd) {
            // Paula laeuft in den Repeat-Bereich weiter. Der alte Swift-Code
            // setzte hart auf repeatOffset und konnte bei genauem Loop-Ende
            // kurzzeitig ausserhalb der gueltigen Sampledaten landen.
            ch.sampleIndex = start + (ch.sampleIndex - start).truncatingRemainder(dividingBy: length)
        }
    }
    
    public func exportInstrumentToWav(index: Int, destinationURL: URL) throws {
        guard let mod = activeMod, index >= 1 && index < mod.instruments.count, let inst = mod.instruments[index], inst.bytes.count > 0 else { return }
        
        let sampleRate = 22050.0 // Standard Amiga sample rate
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "ModPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Konnte Mono-Format nicht erstellen"])
        }
        
        try? FileManager.default.removeItem(at: destinationURL)
        let audioFile = try AVAudioFile(forWriting: destinationURL, settings: monoFormat.settings)
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: UInt32(inst.bytes.count)) else {
            throw NSError(domain: "ModPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Konnte Buffer nicht erstellen"])
        }
        
        pcmBuffer.frameLength = UInt32(inst.bytes.count)
        if let channelData = pcmBuffer.floatChannelData?[0] {
            for i in 0..<inst.bytes.count {
                channelData[i] = Float(inst.bytes[i]) / 256.0
            }
        }
        
        try audioFile.write(from: pcmBuffer)
    }
}
