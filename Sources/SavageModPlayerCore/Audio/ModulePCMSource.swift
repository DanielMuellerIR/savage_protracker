import Foundation

// ============================================================================
// ModulePCMSource — die Bruecke vom Replayer zur Audio-Ausgabe.
//
// Die Sink-Schicht (PCMSink & Co.) will einen `PCMRenderBlock`: interleaved
// Float-Samples und die Anzahl wirklich gefuellter Frames. Der Renderkern liefert
// einen `ModuleRenderBlock`: zwei getrennte Kanalpuffer, ohne Rueckmeldung ueber
// das Songende. Diese Klasse uebersetzt zwischen beidem — und sonst nichts.
//
// Damit bleibt es EINE Engine: Live-Wiedergabe (App), Offline-Render
// (ModuleRenderer, Quick Look) und CLI-Wiedergabe rufen alle denselben Block aus
// `RenderEngine.createRenderBlock`. Diese Datei haengt nur die Ausgabe daran.
// ============================================================================

/// Speist einen `PCMSink` aus einem geparsten Modul.
///
/// Einweg wie der Sink selbst: pro Wiedergabe eine Instanz. `renderBlock()`
/// liefert den Block, den `PCMSink.start(render:)` erwartet.
public final class ModulePCMSource: @unchecked Sendable {

    /// Chunk-Groesse, in der aus dem Renderblock geholt wird.
    ///
    /// Die Puffer sind voralloziiert, weil der Renderblock auf dem Audio-Thread
    /// laeuft und dort nichts alloziert werden darf. Fordert der Sink mehr Frames
    /// an als hier Platz ist (ALSA-Perioden variieren je nach Geraet), holt der
    /// Block sie in mehreren Runden — statt den Puffer zur Laufzeit zu vergroessern.
    private static let chunkCapacity = 4096

    private let mod: Mod
    private let state: RealtimePlaybackState
    private let block: ModuleRenderBlock
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    // VU-/Wave-Puffer will der Renderblock immer bedienen. Das CLI zeigt nichts
    // davon an, also bekommt er Wegwerf-Puffer — die Alternative waere ein
    // zweiter Renderpfad ohne Visualisierung, und genau die Doppelung soll es
    // nicht geben.
    private let dummyPeaks: UnsafeMutablePointer<Float>
    private let dummyWaves: UnsafeMutablePointer<Float>
    private let dummyMasterWaves: UnsafeMutablePointer<Float>
    private let channelCount: Int

    /// Bereits ausgelieferte Frames — noetig, um `endReachedFrame` (absolut
    /// gezaehlt ab Songstart) in „wie viele Frames sind in DIESEM Aufruf noch
    /// gueltig" umzurechnen.
    private var renderedFrames: UInt64 = 0

    /// Sampleraten-Vorgabe des Moduls.
    public let format: PCMFormat

    public init(mod: Mod, format: PCMFormat) {
        self.mod = mod
        self.format = format
        let channels = RenderEngine.makeRenderChannels(for: mod)
        let logicalCount = mod.format == .it
            ? max(1, min(RenderEngine.maxChannels, mod.channelCount))
            : channels.count
        self.channelCount = logicalCount

        let state = RenderEngine.makeRenderState(for: mod, sampleRate: format.sampleRate)
        state.stereoSeparation = 0.8
        state.useInterpolation = true
        state.palClock = true
        self.state = state

        dummyPeaks = UnsafeMutablePointer<Float>.allocate(capacity: logicalCount)
        dummyPeaks.initialize(repeating: 0.0, count: logicalCount)
        dummyWaves = UnsafeMutablePointer<Float>.allocate(capacity: logicalCount * 32)
        dummyWaves.initialize(repeating: 0.0, count: logicalCount * 32)
        dummyMasterWaves = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        dummyMasterWaves.initialize(repeating: 0.0, count: 128)

        left = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkCapacity)
        left.initialize(repeating: 0.0, count: Self.chunkCapacity)
        right = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkCapacity)
        right.initialize(repeating: 0.0, count: Self.chunkCapacity)

        block = RenderEngine.createRenderBlock(
            state: state,
            vuBuffer: RealtimeVUBuffer(pointer: dummyPeaks),
            waveBuffer: RealtimeWaveBuffer(channelWaves: dummyWaves, masterWaves: dummyMasterWaves),
            dspChannels: channels,
            mod: mod,
            sampleRate: format.sampleRate
        )
    }

    deinit {
        dummyPeaks.deinitialize(count: channelCount)
        dummyPeaks.deallocate()
        dummyWaves.deinitialize(count: channelCount * 32)
        dummyWaves.deallocate()
        dummyMasterWaves.deinitialize(count: 128)
        dummyMasterWaves.deallocate()
        left.deinitialize(count: Self.chunkCapacity)
        left.deallocate()
        right.deinitialize(count: Self.chunkCapacity)
        right.deallocate()
    }

    /// Der Block fuer `PCMSink.start(render:)`.
    ///
    /// Echtzeit-Vertrag: keine Allokation, kein Lock, kein I/O. Alle Puffer stehen
    /// schon, gerechnet wird nur Interleaving und die Frame-Buchhaltung.
    public func renderBlock() -> PCMRenderBlock {
        let channels = format.channels
        return { [self] buffer, frames in
            var written = 0
            while written < frames {
                // Songende: endReachedFrame zaehlt absolut ab Start. Was davon in
                // diesem Aufruf noch uebrig ist, ist die gueltige Restlaenge; alles
                // danach faellt weg und der Sink beendet sich (Rueckgabe < frames).
                if state.endReachedFrame != .max {
                    let remaining = state.endReachedFrame > renderedFrames
                        ? state.endReachedFrame - renderedFrames
                        : 0
                    if remaining == 0 { return written }
                }

                let want = min(frames - written, Self.chunkCapacity)
                block(UInt32(want), left, right)

                var valid = want
                if state.endReachedFrame != .max {
                    let remaining = Int(min(
                        UInt64(want),
                        state.endReachedFrame > renderedFrames
                            ? state.endReachedFrame - renderedFrames
                            : 0
                    ))
                    valid = min(valid, remaining)
                }

                for frame in 0..<valid {
                    let slot = (written + frame) * channels
                    buffer[slot] = left[frame]
                    if channels > 1 {
                        buffer[slot + 1] = right[frame]
                    }
                }
                written += valid
                renderedFrames += UInt64(valid)

                // Weniger gueltige Frames als geholt: der Song ist mitten im Chunk
                // zu Ende. Kurz zurueckgeben ist genau das Signal dafuer.
                if valid < want { return written }
            }
            return written
        }
    }
}
