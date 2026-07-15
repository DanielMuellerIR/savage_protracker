import Foundation

// Offline-Renderer: spielt ein Modul mit derselben DSP-Engine wie die
// Live-Wiedergabe komplett durch und liefert fertige WAV-Daten (16-Bit-PCM,
// Stereo). Hauptnutzer ist das Quick-Look-Plugin — Quick Look zeigt für die
// gelieferten WAV-Daten den nativen macOS-Audio-Player mit Play/Scrubbing.
public enum ModuleRenderer {
    // Rendert bis zum Songende (endReached-Signal des Sequencers) oder
    // maximal maxDurationSeconds (Schutz gegen endlos geloopte Module).
    // normalize: Peak-Anhebung fürs Quick-Look (Standard). Für A/B-Vergleiche mit
    // Referenz-Renderern (openmpt123) auf false stellen — dann ist die Ausgabe die
    // rohe Engine-Ausgabe (identisch zum Live-Pfad, nur ohne Mixer-Volume).
    // useInterpolation: Standard true bewahrt den Quick-Look-Klang; das CLI kann
    // fuer rohe Nearest-Neighbor-Vergleiche gezielt false uebergeben.
    public static func renderWavData(
        mod: Mod,
        sampleRate: Double = 44100.0,
        maxDurationSeconds: Double = 300.0,
        normalize: Bool = true,
        useInterpolation: Bool = true
    ) throws -> Data {
        try renderWavDataImpl(
            mod: mod,
            sampleRate: sampleRate,
            maxDurationSeconds: maxDurationSeconds,
            normalize: normalize,
            useInterpolation: useInterpolation,
            captureConsumer: nil
        )
    }

    // Synchroner, blockweiser Offline-Pfad fuer Float-/Stem-Referenzmessungen.
    // Der Consumer wird erst nach der Rueckkehr des Audio-Blocks aufgerufen.
    nonisolated static func renderWavDataWithCapture(
        mod: Mod,
        sampleRate: Double = 44100.0,
        maxDurationSeconds: Double = 300.0,
        normalize: Bool = true,
        useInterpolation: Bool = true,
        consume: @escaping (RenderCaptureBlock) -> Void
    ) throws -> Data {
        try renderWavDataImpl(
            mod: mod,
            sampleRate: sampleRate,
            maxDurationSeconds: maxDurationSeconds,
            normalize: normalize,
            useInterpolation: useInterpolation,
            captureConsumer: consume
        )
    }

    private static func renderWavDataImpl(
        mod: Mod,
        sampleRate: Double,
        maxDurationSeconds: Double,
        normalize: Bool,
        useInterpolation: Bool,
        captureConsumer: ((RenderCaptureBlock) -> Void)?
    ) throws -> Data {
        let renderChannels = RenderEngine.makeRenderChannels(for: mod)
        let channelCount = mod.format == .it
            ? max(1, min(RenderEngine.maxChannels, mod.channelCount))
            : renderChannels.count
        let state = RenderEngine.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = 0.8
        state.useInterpolation = useInterpolation
        state.palClock = true

        // Dummy-Puffer für VU/Waves — der Render-Block schreibt sie immer.
        let dummyPeaks = UnsafeMutablePointer<Float>.allocate(capacity: channelCount)
        defer { dummyPeaks.deallocate() }
        for j in 0..<channelCount { dummyPeaks[j] = 0.0 }
        let dummyWaves = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * 32)
        defer { dummyWaves.deallocate() }
        for j in 0..<(channelCount * 32) { dummyWaves[j] = 0.0 }
        let dummyMasterWaves = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { dummyMasterWaves.deallocate() }
        for j in 0..<128 { dummyMasterWaves[j] = 0.0 }

        let blockFrames = UInt32(1024)
        let captureEnabled = captureConsumer != nil
        var captureLeftPointer: UnsafeMutablePointer<Float>?
        var captureRightPointer: UnsafeMutablePointer<Float>?
        var captureStemsPointer: UnsafeMutablePointer<Float>?
        var renderCapture: RenderCapture?
        if captureEnabled {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: Int(blockFrames))
            let right = UnsafeMutablePointer<Float>.allocate(capacity: Int(blockFrames))
            let stems = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * Int(blockFrames))
            left.initialize(repeating: 0.0, count: Int(blockFrames))
            right.initialize(repeating: 0.0, count: Int(blockFrames))
            stems.initialize(repeating: 0.0, count: channelCount * Int(blockFrames))
            captureLeftPointer = left
            captureRightPointer = right
            captureStemsPointer = stems
            renderCapture = RenderCapture(
                stereoLeftPointer: left,
                stereoRightPointer: right,
                stemsPointer: stems,
                frameCapacity: Int(blockFrames),
                channelCount: channelCount
            )
        }
        defer {
            captureLeftPointer?.deinitialize(count: Int(blockFrames))
            captureLeftPointer?.deallocate()
            captureRightPointer?.deinitialize(count: Int(blockFrames))
            captureRightPointer?.deallocate()
            captureStemsPointer?.deinitialize(count: channelCount * Int(blockFrames))
            captureStemsPointer?.deallocate()
        }

        let block = RenderEngine.createRenderBlock(
            state: state,
            vuBuffer: RealtimeVUBuffer(pointer: dummyPeaks),
            waveBuffer: RealtimeWaveBuffer(channelWaves: dummyWaves, masterWaves: dummyMasterWaves),
            dspChannels: renderChannels,
            mod: mod,
            sampleRate: sampleRate,
            capture: renderCapture
        )

        // Eigene, voralloziierte Float-Stereopuffer statt AVAudioPCMBuffer: der
        // Offline-Renderpfad ist damit plattformneutral und trägt das Linux-CLI.
        // Layout wie beim Live-Pfad (non-interleaved Float32), also identische
        // Engine-Ausgabe.
        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(blockFrames))
        leftBuffer.initialize(repeating: 0.0, count: Int(blockFrames))
        defer {
            leftBuffer.deinitialize(count: Int(blockFrames))
            leftBuffer.deallocate()
        }
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(blockFrames))
        rightBuffer.initialize(repeating: 0.0, count: Int(blockFrames))
        defer {
            rightBuffer.deinitialize(count: Int(blockFrames))
            rightBuffer.deallocate()
        }

        let totalFrames = UInt64(sampleRate * maxDurationSeconds)
        var renderedFrames: UInt64 = 0
        var pcmData = Data()
        pcmData.reserveCapacity(1_048_576)

        while renderedFrames < totalFrames {
            block(blockFrames, leftBuffer, rightBuffer)

            var validFrames = UInt64(blockFrames)
            validFrames = min(validFrames, totalFrames - renderedFrames)
            if state.endReachedFrame != .max {
                validFrames = min(
                    validFrames,
                    state.endReachedFrame > renderedFrames
                        ? state.endReachedFrame - renderedFrames
                        : 0
                )
            }
            let frames = Int(validFrames)

            if let renderCapture, let captureConsumer {
                var stereoLeft = [Float](repeating: 0.0, count: frames)
                var stereoRight = [Float](repeating: 0.0, count: frames)
                var stems = [Float](repeating: 0.0, count: channelCount * frames)
                for frame in 0..<frames {
                    stereoLeft[frame] = renderCapture.stereoLeftPointer[frame]
                    stereoRight[frame] = renderCapture.stereoRightPointer[frame]
                }
                for channel in 0..<channelCount {
                    let sourceOffset = channel * renderCapture.frameCapacity
                    let destinationOffset = channel * frames
                    for frame in 0..<frames {
                        stems[destinationOffset + frame] = renderCapture.stemsPointer[sourceOffset + frame]
                    }
                }
                captureConsumer(RenderCaptureBlock(
                    frameCount: frames,
                    channelCount: channelCount,
                    stereoLeft: stereoLeft,
                    stereoRight: stereoRight,
                    stems: stems
                ))
            }

            // Float-Stereo in interleaved 16-Bit-PCM (Little Endian) wandeln.
            var chunk = [UInt8](repeating: 0, count: frames * 4)
            for f in 0..<frames {
                let l = Int16(max(-1.0, min(1.0, leftBuffer[f])) * 32767.0)
                let r = Int16(max(-1.0, min(1.0, rightBuffer[f])) * 32767.0)
                chunk[f * 4 + 0] = UInt8(truncatingIfNeeded: l)
                chunk[f * 4 + 1] = UInt8(truncatingIfNeeded: l >> 8)
                chunk[f * 4 + 2] = UInt8(truncatingIfNeeded: r)
                chunk[f * 4 + 3] = UInt8(truncatingIfNeeded: r >> 8)
            }
            pcmData.append(contentsOf: chunk)
            renderedFrames += validFrames

            // Songende: Der Sequencer hat hinter die letzte Position gewrappt.
            if state.endReached {
                break
            }
        }

        if normalize { normalizePeak(&pcmData) }
        return makeWavFile(pcmData: pcmData, sampleRate: Int(sampleRate))
    }

    // Peak-Normalisierung (nur Anhebung): Module mit vielen Kanälen oder
    // niedriger Global Volume landen sonst weit unter Vollaussteuerung und
    // klingen in der Quick-Look-Vorschau wie stumm. Ziel ~-1 dBFS, Anhebung
    // gedeckelt (16x), niemals absenken.
    private static func normalizePeak(_ pcmData: inout Data) {
        let target = 29000 // ~0.89 * Int16.max
        var peak = 0
        pcmData.withUnsafeBytes { buf in
            for s in buf.bindMemory(to: Int16.self) {
                let a = abs(Int(s))
                if a > peak { peak = a }
            }
        }
        guard peak > 0, peak < target else { return }
        let gain = min(16.0, Double(target) / Double(peak))
        pcmData.withUnsafeMutableBytes { buf in
            let samples = buf.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                samples[i] = Int16(clamping: Int(Double(samples[i]) * gain))
            }
        }
    }

    // Kompletter WAV-Container (RIFF-Header + 16-Bit-Stereo-PCM-Daten).
    private static func makeWavFile(pcmData: Data, sampleRate: Int) -> Data {
        var wav = Data()

        func appendString(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func appendUInt32(_ v: Int) {
            let u = UInt32(clamping: v)
            wav.append(contentsOf: [
                UInt8(truncatingIfNeeded: u),
                UInt8(truncatingIfNeeded: u >> 8),
                UInt8(truncatingIfNeeded: u >> 16),
                UInt8(truncatingIfNeeded: u >> 24)
            ])
        }
        func appendUInt16(_ v: Int) {
            let u = UInt16(clamping: v)
            wav.append(contentsOf: [UInt8(truncatingIfNeeded: u), UInt8(truncatingIfNeeded: u >> 8)])
        }

        appendString("RIFF")
        appendUInt32(36 + pcmData.count)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)           // fmt-Chunk-Länge
        appendUInt16(1)            // PCM
        appendUInt16(2)            // Stereo
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * 4) // Byte-Rate (2 Kanäle * 2 Bytes)
        appendUInt16(4)            // Block Align
        appendUInt16(16)           // Bits pro Sample
        appendString("data")
        appendUInt32(pcmData.count)
        wav.append(pcmData)

        return wav
    }
}
