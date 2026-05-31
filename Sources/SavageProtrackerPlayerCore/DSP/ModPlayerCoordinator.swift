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
    
    public init() {}
}

public final class RealtimeVUBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<Float>
    public init(pointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
    }
}

@MainActor
public final class ModPlayerCoordinator: ObservableObject {
    @Published public var isPlaying = false
    @Published public var currentPosition = 0
    @Published public var currentRow = 0
    @Published public var bpm = 125
    @Published public var speed = 6
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
            for ch in channels {
                ch.useInterpolation = useInterpolation
            }
        }
    }
    @Published public var palClock: Bool = true {
        didSet {
            playbackState?.palClock = palClock
        }
    }
    
    @Published public var elapsedTime: Double = 0.0
    @Published public var totalDuration: Double = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var lowPassFilterNode: AVAudioUnitEQ?
    
    @Published public var ledFilterActive: Bool = false {
        didSet {
            lowPassFilterNode?.bypass = !ledFilterActive
        }
    }
    
    @Published public var channelWaveforms: [[Float]] = [
        [Float](repeating: 0, count: 20),
        [Float](repeating: 0, count: 20),
        [Float](repeating: 0, count: 20),
        [Float](repeating: 0, count: 20)
    ]
    
    // Vorallozierte DSP-Daten
    private let channels = [DSPChannel(index: 1), DSPChannel(index: 2), DSPChannel(index: 3), DSPChannel(index: 4)]
    public var activeMod: Mod?
    
    // ARC-managed state captured by the AVAudioSourceNode closure
    private var playbackState: RealtimePlaybackState?
    
    // Peak levels raw pointer for atomic visual synchronization
    nonisolated(unsafe) private let peakLevelsPointer: UnsafeMutablePointer<Float>
    
    // Timer for VU meter visual updates
    private var vuUpdateTimer: Timer?
    
    public init() {
        self.peakLevelsPointer = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        for i in 0..<4 {
            self.peakLevelsPointer[i] = 0.0
        }
    }
    
    deinit {
        peakLevelsPointer.deallocate()
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
        guard let mod = activeMod else { return }
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
        
        let renderBlock = Self.createRenderBlock(
            state: state,
            vuBuffer: vuBuffer,
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
            isPlaying = true
            startVUUpdates()
        } catch {
            print("Fehler beim Starten der AVAudioEngine: \(error)")
        }
    }
    
    public func stop() {
        audioEngine?.stop()
        audioEngine = nil
        sourceNode = nil
        isPlaying = false
        stopVUUpdates()
        
        self.playbackState = nil
        
        for ch in channels {
            ch.reset()
        }
    }
    
    public func setVolume(_ v: Float) {
        audioEngine?.mainMixerNode.outputVolume = v * v // Psychoacoustic scaling
    }
    
    public func seek(toPosition: Int) {
        guard let state = playbackState, let mod = activeMod else { return }
        let pos = max(0, min(mod.length - 1, toPosition))
        state.position = pos
        state.rowIndex = 0
        state.tick = 0
        
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
        
        var newWaveforms = self.channelWaveforms
        for i in 0..<4 {
            newWaveforms[i].removeFirst()
            newWaveforms[i].append(newLevels[i])
        }
        self.channelWaveforms = newWaveforms
        
        // Read progress directly from shared state (100% lock-free, allocation-free)
        if let state = self.playbackState {
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
        dspChannels: [DSPChannel],
        mod: Mod,
        sampleRate: Double
    ) -> @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        return { (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            
            // Defensive check to prevent out-of-bounds buffer crashes (e.g. mono / interleaved layouts)
            guard buffers.count >= 2,
                  let leftPtr = buffers[0].mData,
                  let rightPtr = buffers[1].mData else {
                return noErr
            }
            
            let left = leftPtr.assumingMemoryBound(to: Float.self)
            let right = rightPtr.assumingMemoryBound(to: Float.self)
            
            for frame in 0..<Int(frameCount) {
                // Taktgeber & Tick-Schleife
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
                                } else if targetRow == 64 {
                                    targetRow = 0
                                    targetPosition = state.position + 1
                                }
                            }
                            
                            state.position = targetPosition
                            state.rowIndex = targetRow
                            
                            if state.position >= mod.length {
                                state.position = 0
                            }
                            
                            // Defensive bounds check for pattern and table indices
                            let posIndex = max(0, min(mod.length - 1, state.position))
                            let patternIndex = mod.patternTable[posIndex]
                            
                            if patternIndex < mod.patterns.count {
                                let pattern = mod.patterns[patternIndex]
                                if state.rowIndex < pattern.rows.count {
                                    let row = pattern.rows[state.rowIndex]
                                    
                                    for i in 0..<4 {
                                        let note = row.notes[i]
                                        let ch = dspChannels[i]
                                        
                                        // Jumps and breaks check
                                        if note.hasEffect && note.effectId == 0x0B {
                                            state.positionJump = note.effectData
                                        } else if note.hasEffect && note.effectId == 0x0D {
                                            let r = note.effectHigh * 10 + note.effectLow
                                            state.patternBreak = r
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
                
                for i in 0..<4 {
                    let ch = dspChannels[i]
                    guard let inst = ch.instrument, inst.bytes.count > 0 else { continue }
                    
                    var sampleVal: Float = 0.0
                    let idx = Int(ch.sampleIndex)
                    
                    if inst.isLooped {
                        if idx >= 0 && idx < inst.bytes.count {
                            if state.useInterpolation {
                                sampleVal = ch.getInterpolatedSampleLooped(
                                    from: inst.bytes,
                                    index: ch.sampleIndex,
                                    repeatOffset: inst.repeatOffset,
                                    repeatLength: inst.repeatLength
                                )
                            } else {
                                sampleVal = ch.getNearestSample(from: inst.bytes, index: ch.sampleIndex)
                            }
                            
                            ch.sampleIndex += ch.sampleSpeed
                            let loopEnd = Double(inst.repeatOffset + inst.repeatLength)
                            if ch.sampleIndex >= loopEnd {
                                ch.sampleIndex = Double(inst.repeatOffset)
                            }
                        }
                    } else {
                        if idx >= 0 && idx < inst.length {
                            if state.useInterpolation {
                                sampleVal = ch.getInterpolatedSample(from: inst.bytes, index: ch.sampleIndex)
                            } else {
                                sampleVal = ch.getNearestSample(from: inst.bytes, index: ch.sampleIndex)
                            }
                            ch.sampleIndex += ch.sampleSpeed
                        }
                    }
                    
                    // Mute / Solo logic
                    var isChannelMuted = ch.isMuted
                    if hasSolo && !ch.isSoloed {
                        isChannelMuted = true
                    }
                    
                    if isChannelMuted {
                        continue
                    }
                    
                    let volumeFactor = ch.currentVolume / 64.0
                    let outputSample = sampleVal * volumeFactor
                    
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
                left[frame] = tanh(outL)
                right[frame] = tanh(outR)
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
        ch.period = 214.0 * Float(pow(2.0, -Double(finetune / 96.0)))
        ch.currentPeriod = ch.period
        ch.sampleIndex = 0.0
        ch.playing = true
    }
    
    public func exportActiveModToWav(destinationURL: URL, durationSeconds: Double = 180.0) throws {
        guard let mod = activeMod else { return }
        
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
        state.stereoSeparation = self.stereoSeparation
        state.useInterpolation = self.useInterpolation
        state.palClock = self.palClock
        
        let dummyPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { dummyPeaks.deallocate() }
        for j in 0..<4 { dummyPeaks[j] = 0.0 }
        let vuBuffer = RealtimeVUBuffer(pointer: dummyPeaks)
        
        let block = Self.createRenderBlock(
            state: state,
            vuBuffer: vuBuffer,
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
