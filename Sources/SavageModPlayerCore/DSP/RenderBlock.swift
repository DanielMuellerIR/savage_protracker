import Foundation

// Plattformneutrale Signatur des Echtzeit-Renderblocks.
//
// Der Renderblock ist der gemeinsame Kern von Live-Wiedergabe (AVAudioSourceNode),
// Offline-Render (ModuleRenderer/Quick Look) und CLI. Früher trug er direkt die
// CoreAudio-Signatur von AVAudioSourceNode — damit hing der komplette Renderpfad
// an Darwin-Typen (ObjCBool, AudioTimeStamp, AudioBufferList, OSStatus) und war
// unter Linux nicht baubar.
//
// Der Block füllt zwei Float-Kanalpuffer mit je frameCount Frames. Die beiden
// CoreAudio-Parameter isSilence und timestamp wurden von keinem Block je gelesen
// und entfallen deshalb ersatzlos; die Rückgabe OSStatus war immer noErr. Die
// CoreAudio-Anbindung lebt jetzt ausschließlich im Adapter
// `ModPlayerCoordinator.makeSourceNodeRenderBlock` (nur macOS/iOS).
//
// Echtzeit-Vertrag unverändert: Der Block allokiert nicht, sperrt nicht und ruft
// nichts dynamisch über Objective-C auf.
public typealias ModuleRenderBlock = @Sendable (
    _ frameCount: UInt32,
    _ left: UnsafeMutablePointer<Float>,
    _ right: UnsafeMutablePointer<Float>
) -> Void
