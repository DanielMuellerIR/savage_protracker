import Foundation
import AVFoundation

// Offline-Renderer: spielt ein Modul mit derselben DSP-Engine wie die
// Live-Wiedergabe komplett durch und liefert fertige WAV-Daten (16-Bit-PCM,
// Stereo). Hauptnutzer ist das Quick-Look-Plugin — Quick Look zeigt für die
// gelieferten WAV-Daten den nativen macOS-Audio-Player mit Play/Scrubbing.
public enum ModuleRenderer {
    // Rendert bis zum Songende (endReached-Signal des Sequencers) oder
    // maximal maxDurationSeconds (Schutz gegen endlos geloopte Module).
    public static func renderWavData(
        mod: Mod,
        sampleRate: Double = 44100.0,
        maxDurationSeconds: Double = 300.0
    ) throws -> Data {
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "ModuleRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Konnte Audio-Format nicht erstellen"])
        }

        let renderChannels = ModPlayerCoordinator.makeRenderChannels(for: mod)
        let channelCount = renderChannels.count
        let state = ModPlayerCoordinator.makeRenderState(for: mod, sampleRate: sampleRate)
        state.stereoSeparation = 0.8
        state.useInterpolation = true
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

        let block = ModPlayerCoordinator.createRenderBlock(
            state: state,
            vuBuffer: RealtimeVUBuffer(pointer: dummyPeaks),
            waveBuffer: RealtimeWaveBuffer(channelWaves: dummyWaves, masterWaves: dummyMasterWaves),
            dspChannels: renderChannels,
            mod: mod,
            sampleRate: sampleRate
        )

        let blockFrames = UInt32(1024)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: blockFrames) else {
            throw NSError(domain: "ModuleRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Konnte Buffer nicht erstellen"])
        }

        let totalFrames = UInt64(sampleRate * maxDurationSeconds)
        var renderedFrames: UInt64 = 0
        var pcmData = Data()
        pcmData.reserveCapacity(1_048_576)

        var isSilence = ObjCBool(false)
        var timeStamp = AudioTimeStamp()

        while renderedFrames < totalFrames {
            pcmBuffer.frameLength = blockFrames
            let abl = pcmBuffer.mutableAudioBufferList
            let status = block(&isSilence, &timeStamp, blockFrames, abl)
            if status != noErr {
                throw NSError(domain: "ModuleRenderer", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Audio-Render-Fehler"])
            }

            // Float-Stereo in interleaved 16-Bit-PCM (Little Endian) wandeln.
            if let floatData = pcmBuffer.floatChannelData {
                let frames = Int(blockFrames)
                var chunk = [UInt8](repeating: 0, count: frames * 4)
                for f in 0..<frames {
                    let l = Int16(max(-1.0, min(1.0, floatData[0][f])) * 32767.0)
                    let r = Int16(max(-1.0, min(1.0, floatData[1][f])) * 32767.0)
                    chunk[f * 4 + 0] = UInt8(truncatingIfNeeded: l)
                    chunk[f * 4 + 1] = UInt8(truncatingIfNeeded: l >> 8)
                    chunk[f * 4 + 2] = UInt8(truncatingIfNeeded: r)
                    chunk[f * 4 + 3] = UInt8(truncatingIfNeeded: r >> 8)
                }
                pcmData.append(contentsOf: chunk)
            }
            renderedFrames += UInt64(blockFrames)

            // Songende: Der Sequencer hat hinter die letzte Position gewrappt.
            if state.endReached {
                break
            }
        }

        normalizePeak(&pcmData)
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
