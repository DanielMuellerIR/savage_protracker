import Foundation

// ============================================================================
// PCMSinkFactory — waehlt die passende Audio-Ausgabe fuer die Plattform.
//
// Das ist die EINZIGE Stelle im Projekt, an der entschieden wird „macOS oder
// Linux?". Alles andere redet nur noch mit dem `PCMSink`-Protokoll.
//
// Herkunft: uebernommen aus vicious_sidplayer — siehe PCMSink.swift.
// ============================================================================
public enum PCMSinkFactory {

    /// Das Format, mit dem die Quelle auf dieser Plattform am besten faehrt.
    ///
    /// Hintergrund: Die Emulation muss ihre Samplerate kennen, BEVOR das erste
    /// Sample entsteht — die Soundkarte kennt ihre eigene aber erst, wenn man sie
    /// fragt. Rendert die Quelle mit einer anderen Rate als die Hardware laeuft,
    /// muss jemand umrechnen (Resampling): das kostet Rechenzeit und Qualitaet.
    /// Deshalb hier vorher fragen und die Quelle gleich passend aufbauen.
    public static func preferredFormat(channels: Int = 2) -> PCMFormat {
        #if canImport(AVFoundation)
        return AVAudioEnginePCMSink.hardwareFormat(channels: channels)
        #else
        // ALSA nimmt die gewuenschte Rate entgegen und laesst notfalls den
        // Soundserver (PipeWire/Pulse) umrechnen. 44,1 kHz ist die Vorgabe des
        // Replayers (savage-cli --rate, Standard 44100) und damit die ehrlichste.
        return PCMFormat(sampleRate: 44100.0, channels: channels)
        #endif
    }

    /// Baut die Standard-Ausgabe der Plattform: AVAudioEngine auf Apple, ALSA auf
    /// Linux. Wer bewusst in eine Pipe schreiben will, nimmt direkt `StdoutPCMSink`.
    public static func makeDefault(format: PCMFormat) -> PCMSink {
        #if canImport(AVFoundation)
        return AVAudioEnginePCMSink(format: format)
        #elseif os(Linux)
        return ALSAPCMSink(format: format)
        #else
        // Unbekannte Plattform: die Pipe ist der kleinste gemeinsame Nenner und
        // funktioniert ueberall, wo es stdout gibt.
        return StdoutPCMSink(format: format)
        #endif
    }
}
