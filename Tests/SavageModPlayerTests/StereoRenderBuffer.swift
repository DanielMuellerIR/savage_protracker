import Foundation

/// Zwei Float-Kanalpuffer zum Aufruf eines `ModuleRenderBlock` im Test.
///
/// Ersetzt den früher genutzten `AVAudioPCMBuffer`: der Renderblock trägt seit
/// dem Linux-Port keine CoreAudio-Signatur mehr, sondern schreibt direkt in zwei
/// Float-Puffer. Dadurch brauchen diese Tests kein AVFoundation und laufen auch
/// unter Linux.
final class StereoRenderBuffer {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        left.initialize(repeating: 0.0, count: capacity)
        right.initialize(repeating: 0.0, count: capacity)
    }

    deinit {
        left.deinitialize(count: capacity)
        left.deallocate()
        right.deinitialize(count: capacity)
        right.deallocate()
    }
}
