import Foundation

// ============================================================================
// PCMSink — die plattformneutrale Audio-Ausgabe-Abstraktion.
//
// WARUM es das gibt
// -----------------
// Herkunft: uebernommen aus vicious_sidplayer (Sources/ViciousSIDPlayerCore/
// Audio/), wo diese Schicht zuerst entstanden und laufzeitgeprueft wurde. Bewusst
// Copy statt gemeinsames Paket — erst wenn sie sich in BEIDEN Repos bewaehrt hat,
// lohnt eine Extraktion. Aenderungen hier und dort im Blick behalten.
//
// Der Replayer (RenderEngine/ModuleRenderer) erzeugt reine Zahlen und weiss nichts
// von Audio-Hardware. Wer diese Zahlen hoerbar macht, ist plattformabhaengig:
// macOS nutzt AVAudioEngine, Linux ALSA (oder ein Rohr nach `aplay`). Damit der
// Player-Code nicht an jeder Stelle `#if os(Linux)` streuen muss, gibt es hier
// EINE kleine Schnittstelle, hinter der die Plattform verschwindet.
//
// Diese Datei ist bewusst frei von Format-Wissen: sie kennt nur Samples, Kanaele
// und Samplerate — weder MOD/S3M/XM/IT noch Sequencer tauchen hier auf. Genau
// deshalb liess sie sich unveraendert aus dem SID-Player uebernehmen.
//
// Das Pull-Modell (und warum)
// ---------------------------
// Audio-Ausgabe funktioniert ueberall nach dem gleichen Prinzip: die Soundkarte
// meldet sich, wenn sie wieder Nachschub braucht, und holt ihn sich per
// Callback ab. Man schiebt Samples also nicht hin, sondern wird gefragt
// („Pull"). Dieses Muster bilden AVAudioSourceNode und ALSA gleichermassen ab —
// deshalb ist es hier der gemeinsame Nenner.
// ============================================================================

/// Beschreibt das Audio-Format, in dem ein Sink Samples entgegennimmt.
public struct PCMFormat: Sendable, Equatable {
    /// Abtastrate in Hz (z. B. 44100).
    public let sampleRate: Double
    /// Anzahl Kanaele (1 = mono, 2 = stereo).
    public let channels: Int

    public init(sampleRate: Double = 44100.0, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Fehler, die beim Oeffnen oder Bespielen einer Audio-Ausgabe auftreten koennen.
public enum PCMSinkError: Error, LocalizedError {
    /// Das Audio-Geraet liess sich nicht oeffnen (belegt, nicht vorhanden, keine Rechte).
    case deviceUnavailable(String)
    /// Das gewuenschte Format akzeptiert die Hardware nicht.
    case unsupportedFormat(PCMFormat)
    /// Schreib-/Lesefehler waehrend der Wiedergabe.
    case ioFailure(String)
    /// Aufruf passt nicht zum Lebenszyklus — z. B. `start()` auf einem Sink, der
    /// schon laeuft. Das ist ein Programmierfehler, kein Umweltproblem.
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let detail):
            return "Audio-Ausgabe nicht verfügbar: \(detail)"
        case .unsupportedFormat(let format):
            return "Audio-Format nicht unterstützt: \(Int(format.sampleRate)) Hz, \(format.channels) Kanäle"
        case .ioFailure(let detail):
            return "Audio-Ausgabefehler: \(detail)"
        case .invalidState(let detail):
            return "Ungültiger Zustandswechsel der Audio-Ausgabe: \(detail)"
        }
    }
}

/// Warum die Wiedergabe geendet hat.
///
/// Ohne diese Unterscheidung sehen „Song zu Ende", „Nutzer hat gestoppt" und
/// „Soundkarte hat sich verabschiedet" von aussen gleich aus — ein CLI koennte
/// dann keinen sinnvollen Exit-Code setzen. Genau dafuer gibt es den Typ.
public enum PCMSinkFinishReason: Sendable, Equatable {
    /// Der Renderblock lieferte weniger Frames als angefordert: regulaeres Ende.
    case sourceFinished
    /// `stop()` wurde gerufen.
    case stopped
    /// Der Empfaenger der Ausgabe ist weggefallen — bei einer Pipe der Normalfall
    /// (`… | head`, aplay beendet). Bewusst KEIN Fehler: wer nach stdout schreibt,
    /// darf daran nicht scheitern.
    case outputClosed
    /// Echter Ausgabefehler waehrend der Wiedergabe.
    case failed(String)
    /// `start()` wurde nie gerufen — es gab nichts zu warten.
    case notStarted
}

/// Der Callback, mit dem ein Sink sich Nachschub holt.
///
/// - Parameter buffer: Zielpuffer, **interleaved** Float-Samples im Bereich -1…1.
///   Interleaved heisst: bei Stereo liegen die Kanaele abwechselnd hintereinander
///   (L, R, L, R, …) statt in zwei getrennten Bloecken. Das ist das Format, das
///   ALSA und eine PCM-Pipe direkt wollen; nur AVAudioEngine will es getrennt und
///   sortiert es deshalb in seinem Sink selbst um.
/// - Parameter frames: Anzahl angeforderter Frames. Ein Frame umfasst ALLE Kanaele,
///   d. h. bei Stereo sind `frames * 2` Float-Werte zu schreiben.
/// - Returns: Anzahl tatsaechlich gefuellter Frames. Ein Wert kleiner als `frames`
///   bedeutet „Quelle erschoepft" — der Sink spielt den Rest aus und beendet sich.
///   0 heisst: sofort fertig.
///
/// **Achtung, Echtzeit-Thread:** Dieser Block laeuft bei echten Audio-Backends auf
/// einem Realtime-Thread. Dort darf nichts passieren, was unvorhersehbar lange
/// dauert: kein Speicher allozieren, keine Locks mit Wartezeit, keine Datei-I/O,
/// kein print(). Sonst gibt es hoerbare Aussetzer (Knackser/Dropouts).
public typealias PCMRenderBlock = @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Int

/// Eine Audio-Ausgabe, die sich Samples per Callback abholt.
///
/// Lebenszyklus: `start(render:)` → optional `pause()`/`resume()` → `stop()`.
/// Der Zustandsautomat entspricht bewusst dem der bestehenden macOS-Wiedergabe:
/// `pause()` haelt nur an und erhaelt den Stand, `stop()` baut ab. Das Zuruecksetzen
/// der Emulation ist NICHT Sache des Sinks — er kennt sie nicht.
///
/// **`Sendable` ist Teil des Vertrags**, nicht bloss Beiwerk: Ein Sink wird von Natur
/// aus ueber Thread-Grenzen hinweg benutzt. `start()` kommt vom Haupt-Thread, der
/// Renderblock laeuft auf dem Audio-Thread, und `stop()` kommt womoeglich aus einer
/// Tastaturschleife oder einem Signal-Handler. Jede Implementierung muss ihren
/// Zustand also selbst absichern (alle drei hier tun das mit einem Lock und
/// dokumentieren, warum ihr `@unchecked Sendable` gedeckt ist).
///
/// **Lautstaerke ist bewusst nicht Teil dieses Vertrags.** Sie gehoert der Quelle:
/// wer die Samples erzeugt, skaliert sie auch. Hier macht das der Renderblock aus
/// `RenderEngine.createRenderBlock` (Global Volume, Mix-Gain, tanh-Limiter); in der
/// macOS-App kommt der Mixer des `ModPlayerCoordinator` mit seiner psychoakustischen
/// Kurve dazu. Ein Sink, der zusaetzlich am Pegel dreht, wuerde die Lautstaerke
/// doppelt anwenden.
public protocol PCMSink: AnyObject, Sendable {
    /// Das Format, in dem dieser Sink Samples erwartet.
    var format: PCMFormat { get }

    /// Laeuft gerade Wiedergabe (nicht pausiert, nicht gestoppt)?
    var isRunning: Bool { get }

    /// Oeffnet die Ausgabe und beginnt, `render` um Samples zu bitten.
    ///
    /// - Throws: `PCMSinkError.invalidState`, wenn der Sink nicht frisch ist
    ///   (laeuft, pausiert oder bereits gestoppt). Ein Sink ist Einweg: nach
    ///   `stop()` wird nicht wieder gestartet, sondern ein neuer gebaut. Das haelt
    ///   den Zustandsautomaten klein und entspricht dem, was die Audio-APIs
    ///   darunter ohnehin bevorzugen.
    func start(render: @escaping PCMRenderBlock) throws

    /// Haelt die Wiedergabe an; der Sink bleibt geoeffnet und `resume()` macht weiter.
    /// Auf einem nicht laufenden Sink wirkungslos (kein Fehler).
    func pause() throws

    /// Setzt nach `pause()` fort. Auf einem nicht pausierten Sink wirkungslos.
    func resume() throws

    /// Beendet die Wiedergabe und gibt das Geraet frei. Mehrfacher Aufruf ist
    /// harmlos.
    func stop()

    /// Blockiert, bis die Wiedergabe endet, und sagt, warum sie endete.
    /// Fuer CLI-Wiedergabe gedacht, die nicht von selbst eine RunLoop hat.
    /// Mehrfacher Aufruf liefert denselben Grund erneut.
    @discardableResult
    func waitUntilFinished() -> PCMSinkFinishReason
}
