import Foundation

// ============================================================================
// StdoutPCMSink — Audio-Ausgabe als rohes PCM auf stdout.
//
// WARUM es das gibt
// -----------------
// Der kleinste gemeinsame Nenner jeder Plattform ist eine Pipe. Wer keine
// Audio-Bibliothek anbinden will (oder kann), schiebt die Samples einfach an ein
// Programm, das schon weiss, wie man eine Soundkarte bedient:
//
//   Linux: vicious-sid tune.sid --stdout | aplay -f S16_LE -r 44100 -c 2
//   macOS: vicious-sid tune.sid --stdout | ffplay -f s16le -ar 44100 -ac 2 -i -
//
// Deshalb baut hier nichts auf plattformspezifische Frameworks auf — nur
// Foundation. Dieselbe Datei uebersetzt auf macOS und Linux.
//
// Das Format: s16le
// -----------------
// „s16le" heisst: 16-Bit-Ganzzahlen mit Vorzeichen (signed), little-endian, und
// bei Stereo interleaved (L, R, L, R, …). Das ist das Standard-Rohformat, das
// aplay/ffplay ohne Header erwarten — eine Pipe hat ja keinen WAV-Kopf.
//
// Kein Echtzeit-Thread
// --------------------
// Anders als bei einem echten Audio-Backend gibt es hier keinen Realtime-Thread:
// Der Sink zieht in einem eigenen, ganz normalen Thread Samples und schreibt sie
// in die Pipe. Das Tempo bestimmt der Empfaenger — aplay liest nur so schnell,
// wie die Soundkarte spielt, und blockiert dazwischen. Dieses Blockieren ist die
// Taktbremse, die aus dem Renderer Echtzeit macht.
// ============================================================================

public final class StdoutPCMSink: PCMSink, @unchecked Sendable {

    /// Zustand der Wiedergabe. Bewusst identisch zum Vertrag in `PCMSink`:
    /// `pause()` haelt nur an, `stop()` beendet endgueltig.
    private enum State {
        case idle       // start() wurde noch nicht gerufen
        case running    // Pump-Thread schreibt Samples
        case paused     // Pump-Thread wartet, Ausgabe bleibt offen
        case stopped    // endgueltig beendet (durch stop() oder Quellen-Ende)
    }

    public let format: PCMFormat

    /// Wie viele Frames pro Schreibvorgang gebuendelt werden. Groesser = weniger
    /// write()-Aufrufe, aber traegere Reaktion auf stop(); 4096 Frames sind bei
    /// 44,1 kHz rund 93 ms und damit ein guter Kompromiss.
    private let blockFrames: Int

    /// Ziel der Ausgabe. Als Property gehalten, damit Tests spaeter eine Datei
    /// oder eine Pipe unterschieben koennen, ohne die Klasse anzufassen.
    private let output: FileHandle

    // Eine einzige NSCondition schuetzt ALLE veraenderlichen Felder unten und
    // dient gleichzeitig als Warteplatz fuer pause() und waitUntilFinished().
    // „Condition" = Lock + Wartezimmer: wer wartet, gibt das Lock ab und wird
    // durch broadcast() wieder geweckt. Weil jeder Zugriff auf state/finished
    // ueber dieses Lock laeuft, gibt es kein Datenrennen — nur deshalb ist das
    // `@unchecked Sendable` oben ehrlich und kein Trick.
    private let condition = NSCondition()
    private var state: State = .idle
    private var finished = false
    private var worker: Thread?
    /// Warum die Wiedergabe endete — wird genau einmal gesetzt (der erste Grund
    /// gewinnt) und von waitUntilFinished() zurueckgegeben.
    private var finishReason: PCMSinkFinishReason = .notStarted

    /// - Parameters:
    ///   - format: Samplerate und Kanalzahl, in denen der Renderblock liefert.
    ///     Achtung: Eine Pipe traegt diese Information NICHT mit — der Empfaenger
    ///     (aplay/ffplay) muss dieselben Werte auf der Kommandozeile bekommen.
    ///   - blockFrames: Frames pro Schreibvorgang.
    ///   - output: Zieldatei-Handle; Standard ist stdout.
    public init(format: PCMFormat = PCMFormat(),
                blockFrames: Int = 4096,
                output: FileHandle = FileHandle.standardOutput) {
        self.format = format
        self.blockFrames = max(1, blockFrames)
        self.output = output
    }

    public var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .running
    }

    // MARK: - Lebenszyklus

    public func start(render: @escaping PCMRenderBlock) throws {
        condition.lock()
        guard state == .idle else {
            condition.unlock()
            // Ein Sink ist Einweg (siehe Protokoll-Doku): laeuft er schon oder ist
            // er durch, wird nicht erneut gestartet, sondern ein neuer gebaut.
            throw PCMSinkError.invalidState("StdoutPCMSink wurde bereits gestartet.")
        }
        state = .running
        finished = false
        condition.unlock()

        // Stirbt der Empfaenger der Pipe (aplay beendet sich, Nutzer drueckt
        // Strg-C im nachgeschalteten Programm), schickt der Kernel beim naechsten
        // write() ein SIGPIPE — und dessen Standardverhalten ist: Prozess sofort
        // toeten. Ignorieren wir das Signal, liefert write() stattdessen den
        // Fehler EPIPE zurueck, den wir unten als ganz normales Ende behandeln
        // koennen. Das ist prozessweit und genau das, was jedes CLI-Werkzeug tut,
        // das nach stdout schreibt; es passiert erst hier und nicht schon beim
        // Erzeugen des Sinks, damit die GUI-App davon nie beruehrt wird.
        signal(SIGPIPE, SIG_IGN)

        // Bewusst starke Referenz auf self: Der Thread haelt den Sink am Leben,
        // bis er fertig ist. Mit [weak self] koennte der Sink verschwinden und
        // waitUntilFinished() wuerde nie geweckt.
        let thread = Thread { self.pump(render: render) }
        thread.name = "StdoutPCMSink"
        thread.qualityOfService = .userInitiated

        condition.lock()
        worker = thread
        condition.unlock()

        thread.start()
    }

    public func pause() throws {
        condition.lock()
        defer { condition.unlock() }
        guard state == .running else { return }
        state = .paused
        condition.broadcast()
    }

    public func resume() throws {
        condition.lock()
        defer { condition.unlock() }
        guard state == .paused else { return }
        state = .running
        // Weckt den Pump-Thread, der in seiner Warteschleife haengt.
        condition.broadcast()
    }

    public func stop() {
        condition.lock()
        if state == .idle {
            // Nie gestartet: Es gibt keinen Thread, der `finished` setzen koennte.
            // Also gleich hier markieren, sonst wartet waitUntilFinished() ewig.
            finished = true
            finishReason = .notStarted
        }
        state = .stopped
        // Weckt sowohl einen pausierten Pump-Thread (der dann abbricht) als auch
        // alle Warter in waitUntilFinished().
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    public func waitUntilFinished() -> PCMSinkFinishReason {
        condition.lock()
        defer { condition.unlock() }
        // Nie gestartet: nichts zu warten. Sonst blockieren, bis der Pump-Thread
        // `finished` gesetzt hat — das tut er beim Quellen-Ende, beim Schreibfehler
        // und nach stop().
        while !finished && state != .idle {
            condition.wait()
        }
        return finishReason
    }

    // MARK: - Pump-Thread

    /// Die Schleife, die Samples zieht, wandelt und schreibt. Laeuft auf einem
    /// eigenen Thread, nicht in Echtzeit — hier darf also alloziert und blockiert
    /// werden. Die Puffer werden trotzdem einmal vorab angelegt, weil es nichts
    /// kostet und pro Block eine Allokation spart.
    private func pump(render: PCMRenderBlock) {
        let channels = max(1, format.channels)

        // Zwischenpuffer fuer die Float-Samples, die der Renderblock liefert.
        // Groesse: Frames * Kanaele, weil interleaved (siehe PCMSink-Kommentar).
        let floatBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: blockFrames * channels)
        floatBuffer.initialize(repeating: 0.0)
        defer { floatBuffer.deallocate() }

        // Zielpuffer fuer die fertigen 16-Bit-Werte.
        var pcm = [Int16](repeating: 0, count: blockFrames * channels)

        // Warum die Schleife am Ende verlassen wurde. Vorbelegt mit dem Normalfall;
        // jeder Ausstieg unten setzt den passenden Grund.
        var reason: PCMSinkFinishReason = .sourceFinished

        while true {
            // 1) Zustand pruefen: pausiert = schlafen legen, gestoppt = raus.
            condition.lock()
            while state == .paused {
                condition.wait()
            }
            let isStopped = (state == .stopped)
            condition.unlock()
            if isStopped {
                reason = .stopped
                break
            }

            // 2) Nachschub holen. Der Renderblock darf weniger liefern als
            //    angefordert — das heisst „Quelle erschoepft".
            let filled = min(max(0, render(floatBuffer, blockFrames)), blockFrames)

            // 3) Float (-1…1) nach Int16 wandeln, hart geclippt — dasselbe Muster
            //    wie im WAV-Export (WavRenderer.swift). „Hart geclippt" heisst:
            //    Werte ausserhalb -1…1 werden auf die Grenze gekappt statt
            //    umzulaufen (ein Ueberlauf klaenge wie ein lautes Knacken).
            let sampleCount = filled * channels
            if sampleCount > 0 {
                for i in 0..<sampleCount {
                    let clipped = max(-1.0, min(1.0, floatBuffer[i]))
                    // `.littleEndian` explizit: Auf x86 und Apple Silicon ist das
                    // ein No-Op, auf einer Big-Endian-Maschine dreht es die Bytes.
                    // Das Array liegt danach in jedem Fall als s16le-Bytestrom im
                    // Speicher — genau das, was aplay/ffplay lesen wollen.
                    pcm[i] = Int16(clipped * 32767.0).littleEndian
                }
                if let writeFailure = writePCM(pcm, sampleCount: sampleCount) {
                    // Schreibfehler (typisch: EPIPE, weil aplay weg ist). Das ist
                    // kein Grund zum Absturz — die Wiedergabe ist schlicht vorbei.
                    reason = writeFailure
                    break
                }
            }

            // 4) Weniger Frames als angefordert: Rest ist oben schon rausgeschrieben,
            //    jetzt sauber beenden.
            if filled < blockFrames {
                reason = .sourceFinished
                break
            }
        }

        finish(reason: reason)
    }

    /// Schreibt `sampleCount` Int16-Werte als Rohbytes.
    /// Rueckgabe `nil` heisst „alles gut"; sonst der Grund, aus dem die Wiedergabe
    /// endet.
    private func writePCM(_ pcm: [Int16], sampleCount: Int) -> PCMSinkFinishReason? {
        return pcm.withUnsafeBytes { raw -> PCMSinkFinishReason? in
            guard let base = raw.baseAddress else { return nil }
            let data = Data(bytes: base, count: sampleCount * MemoryLayout<Int16>.size)
            do {
                try output.write(contentsOf: data)
                return nil
            } catch {
                // Zwei sehr verschiedene Faelle sauber trennen:
                // EPIPE = der Empfaenger hat die Pipe zugemacht (`… | head -c 100`,
                // aplay beendet). Das ist bei einem Programm, das nach stdout
                // schreibt, voellig normal und darf kein Fehler-Exit-Code werden.
                // Alles andere (z. B. Platte voll beim Umleiten in eine Datei) ist
                // ein echter Fehler und muss als solcher sichtbar bleiben.
                if Self.isBrokenPipe(error) {
                    return .outputClosed
                }
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Erkennt „Gegenstelle hat die Pipe geschlossen" (EPIPE). Foundation verpackt
    /// den urspruenglichen errno-Wert je nach Plattform unterschiedlich tief,
    /// deshalb wird zusaetzlich der verschachtelte Fehler geprueft.
    private static func isBrokenPipe(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPIPE) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EPIPE) {
            return true
        }
        return false
    }

    /// Markiert das Ende und weckt alle, die in `waitUntilFinished()` warten.
    /// Der ERSTE Grund gewinnt: laeuft die Quelle gerade aus, waehrend jemand
    /// stop() ruft, bleibt es beim regulaeren Ende.
    private func finish(reason: PCMSinkFinishReason) {
        condition.lock()
        if !finished {
            finished = true
            finishReason = reason
        }
        state = .stopped
        worker = nil
        condition.broadcast()
        condition.unlock()
    }
}
