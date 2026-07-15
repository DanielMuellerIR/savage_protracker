// ============================================================================
// ALSAPCMSink — die Linux-Audioausgabe hinter dem PCMSink-Protokoll.
//
// Die GANZE Datei steckt in `#if os(Linux)`, denn ALSA gibt es nur dort. Auf dem
// Mac faellt sie damit ersatzlos weg; der Compiler sieht hier schlicht nichts.
//
// Herkunft: wortgleich uebernommen aus vicious_sidplayer (siehe PCMSink.swift).
// Kein Format-Wissen in dieser Datei — sie kennt nur Samples, Kanaele und
// Samplerate.
//
// Was ist ALSA?
// -------------
// ALSA (Advanced Linux Sound Architecture) ist die Audio-Schicht des
// Linux-Kernels plus die Nutzerbibliothek `libasound`. Man oeffnet ein
// "PCM-Geraet", stellt Format/Kanaele/Rate ein und schiebt dann Bloecke von
// Samples hinein. Die Bibliothek haelt einen Ringpuffer vor, aus dem die
// Soundkarte gleichmaessig liest.
//
// Die zwei Begriffe, die man verstanden haben muss:
//
// * **Interleaved**: bei Stereo liegen die Kanaele abwechselnd hintereinander
//   (L, R, L, R, …) statt in zwei getrennten Bloecken. Ein "Frame" ist ein
//   Satz aus allen Kanaelen, bei Stereo also zwei Int16-Werte. Genau dieses
//   Layout liefert der PCMRenderBlock schon — es muss nichts umsortiert werden.
//
// * **Underrun** (auch "XRUN"): Der Ringpuffer laeuft leer, weil wir nicht
//   schnell genug nachgeliefert haben. Die Soundkarte hat dann nichts zu
//   spielen — das hoert man als Knackser. ALSA meldet danach bei JEDEM weiteren
//   Schreibversuch den Fehler -EPIPE und nimmt erst wieder Daten an, wenn wir
//   den Stream mit `snd_pcm_prepare` neu scharf machen. Ein Underrun ist also
//   kein Grund abzubrechen, sondern ein Grund aufzuraeumen und weiterzumachen.
//   Wer das nicht behandelt, bekommt einen Player, der nach dem ersten
//   Lastspitzen-Hickser fuer immer stumm bleibt.
// ============================================================================

#if os(Linux)
import Foundation
// Glibc liefert die errno-Konstanten (EPIPE, ESTRPIPE, EAGAIN, EINTR), gegen die
// wir die negativen ALSA-Rueckgabewerte pruefen.
import Glibc
import CALSA

/// Audioausgabe ueber ALSA (Linux). Zieht sich Samples per `PCMRenderBlock` auf
/// einem eigenen Wiedergabe-Thread ab und schreibt sie als S16_LE ans Geraet.
///
/// `@unchecked Sendable`: Die Klasse wird von mehreren Threads benutzt
/// (Aufrufer + Wiedergabe-Thread). Der Zugriff auf den veraenderlichen Zustand
/// ist per `NSCondition` serialisiert; das kann der Compiler nicht selbst
/// nachweisen, deshalb "unchecked" — gleiches Muster wie `SongLengthCache`.
///
/// **Thread-Regel dieser Klasse:** ALLE ALSA-Aufrufe passieren ausschliesslich
/// auf dem Wiedergabe-Thread. `pause()`, `resume()` und `stop()` setzen nur ein
/// Flag und wecken den Thread. Das erspart uns jede Frage danach, ob libasound
/// gerade nebenlaeufig auf demselben Handle aufgerufen werden darf — und
/// verhindert, dass z. B. `snd_pcm_pause` in ein blockierendes
/// `snd_pcm_writei` hineingrätscht.
public final class ALSAPCMSink: PCMSink, @unchecked Sendable {

    // MARK: - Konfiguration

    public let format: PCMFormat

    /// Zielpuffergroesse in Mikrosekunden, die wir uns von ALSA wuenschen.
    /// 100 ms sind fuer einen Musikplayer reichlich: gross genug, dass ein
    /// kurzer Scheduling-Hickser keinen Underrun ausloest, klein genug, dass
    /// Pause/Stop nicht traege wirken.
    private static let latencyMicroseconds: UInt32 = 100_000

    /// Wie viele Frames wir pro Runde vom Renderblock holen und am Stueck
    /// schreiben. 1024 Frames sind bei 44,1 kHz rund 23 ms — das ist der
    /// Kompromiss zwischen "wenig Aufrufe" und "Pause/Stop reagieren schnell",
    /// denn der Thread schaut nur zwischen zwei Bloecken nach neuen Wuenschen.
    private static let framesPerBlock = 1024

    /// Kanalzahl, auf mindestens 1 geklemmt — nur fuer die Puffergroessen.
    /// Ein wirklich unsinniger Wert fliegt in `start(render:)` als
    /// `.unsupportedFormat` heraus, bevor irgendetwas geoeffnet wird.
    private let channelCount: Int

    // MARK: - Vorab allozierte Puffer
    //
    // Beide Puffer entstehen EINMAL im Konstruktor. Im Renderpfad darf nichts
    // alloziert werden: Speicheranforderungen koennen unvorhersehbar lange
    // dauern, und jede Verzoegerung dort ist ein potenzieller Underrun.

    /// Zielpuffer fuer den Renderblock: interleaved Floats im Bereich -1…1.
    private let floatBuffer: UnsafeMutableBufferPointer<Float>
    /// Derselbe Block nach Int16 gewandelt — das, was ALSA tatsaechlich bekommt.
    private let pcmBuffer: UnsafeMutablePointer<Int16>

    // MARK: - Zustand (durch `cond` geschuetzt)

    private enum State {
        case idle       // noch nie gestartet
        case running    // spielt
        case paused     // angehalten, Geraet bleibt offen
        case stopping   // Thread soll sich beenden
        case finished   // Thread ist weg, Geraet zu
    }

    /// Schuetzt `state` und `finishReason` UND weckt den Wiedergabe-Thread aus
    /// der Pause.
    private let cond = NSCondition()
    private var state: State = .idle

    /// Warum die Wiedergabe endet(e). Der Wiedergabe-Thread kann nicht werfen —
    /// wer wissen will, ob es sauber zu Ende ging, bekommt den Grund von
    /// `waitUntilFinished()` zurueck.
    ///
    /// Wird genau EINMAL festgeschrieben: Der erste Grund gewinnt. `.notStarted`
    /// ist die Vorbelegung und bleibt nur stehen, wenn nie gestartet wurde.
    private var finishReason: PCMSinkFinishReason = .notStarted
    /// Steht der Grund schon fest? Ein eigenes Flag statt eines Optionals, weil
    /// `.notStarted` selbst ein gueltiger Endgrund ist und deshalb nicht als
    /// „noch nichts entschieden" taugt.
    private var finishReasonSettled = false

    // MARK: - Nur vom Wiedergabe-Thread benutzt
    //
    // `pcmHandle` und `renderBlock` werden in `start(render:)` gesetzt, BEVOR
    // der Thread laeuft, und danach nur noch von ihm angefasst. Deshalb brauchen
    // sie kein Lock.

    /// `snd_pcm_t *` — ein unvollstaendiger C-Typ, den Swift als OpaquePointer importiert.
    private var pcmHandle: OpaquePointer?
    private var renderBlock: PCMRenderBlock?
    /// Kann das geoeffnete Geraet echtes Hardware-Pause? (siehe `pause()`)
    private var canPause = false
    /// Welchen Pausenweg wir zuletzt genommen haben — `resume()` muss dazu passen.
    private var pausedViaHardware = false

    /// Nur fuer die Selbstaufruf-Erkennung in `stop()`. Der Thread-Block haelt
    /// `self` bewusst nur schwach, sonst gaebe es einen Retain-Zyklus
    /// (self → Thread → Block → self) und die Klasse wuerde nie freigegeben.
    private var playbackThread: Thread?

    // MARK: - Leben und Sterben

    /// Legt die Puffer an. Das Geraet wird erst in `start(render:)` geoeffnet —
    /// so kann der Konstruktor nicht fehlschlagen und ein Sink darf existieren,
    /// ohne die Soundkarte zu belegen.
    public init(format: PCMFormat = PCMFormat()) {
        self.format = format
        let channels = max(1, format.channels)
        self.channelCount = channels

        let sampleCount = ALSAPCMSink.framesPerBlock * channels
        self.floatBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
        self.floatBuffer.initialize(repeating: 0)
        self.pcmBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: sampleCount)
        self.pcmBuffer.initialize(repeating: 0, count: sampleCount)
    }

    deinit {
        // Sicherheitsnetz: Wenn `start()` das Geraet zwar geoeffnet hat, der
        // Thread aber nie loslief, haengt hier noch ein offenes Handle. Waehrend
        // der Thread laeuft, kann deinit nicht greifen — er haelt `self` fuer die
        // Dauer des Aufrufs stark.
        if let handle = pcmHandle {
            _ = snd_pcm_close(handle)
            pcmHandle = nil
        }
        floatBuffer.deallocate()
        pcmBuffer.deallocate()
    }

    // MARK: - PCMSink

    public var isRunning: Bool {
        cond.lock()
        defer { cond.unlock() }
        return state == .running
    }

    public func start(render: @escaping PCMRenderBlock) throws {
        cond.lock()
        guard state == .idle else {
            cond.unlock()
            // Ein Sink ist Einweg (siehe Protokoll-Doku): laeuft er schon, ist er
            // pausiert oder durch, wird nicht erneut gestartet, sondern ein neuer
            // gebaut. Das ist ein Programmierfehler des Aufrufers und kein
            // Geraeteproblem — deshalb `.invalidState` und nicht `.ioFailure`.
            throw PCMSinkError.invalidState("ALSAPCMSink wurde bereits gestartet.")
        }
        cond.unlock()

        // Format vorab pruefen: ALSA wuerde 0 Kanaele oder 0 Hz zwar auch
        // ablehnen, aber mit einem kryptischen errno. Lieber sauber melden.
        //
        // Die Obergrenzen sind kein Geschmacksurteil, sondern Absturzschutz:
        // weiter unten gehen Kanalzahl und Rate per `UInt32(...)` in die
        // C-Aufrufe, und dieser Konstruktor stuerzt bei einem Wert ausserhalb
        // des UInt32-Bereichs hart ab. Lieber hier ein sauberer Fehler.
        // 768 kHz ist die hoechste Rate, die ALSA ueberhaupt kennt.
        guard format.channels >= 1, format.channels <= 256,
              format.sampleRate.isFinite,
              format.sampleRate > 0, format.sampleRate <= 768_000 else {
            throw PCMSinkError.unsupportedFormat(format)
        }

        // --- Geraet oeffnen ---------------------------------------------------
        //
        // "default" ist KEIN Hardwarename, sondern ein logischer Name, den ALSA
        // ueber /usr/share/alsa/alsa.conf und ~/.asoundrc aufloest. Auf einem
        // normalen Desktop zeigt er auf die PipeWire- bzw. PulseAudio-Bruecke:
        // unser Ton wird mit dem anderer Programme gemischt, folgt der
        // Lautstaerkeregelung des Systems und dem umgestoepselten Ausgabegeraet.
        //
        // "hw:0" waere das rohe Geraet unter Umgehung des Soundservers. Das ist
        // fast immer falsch: es belegt die Karte exklusiv (schlaegt mit EBUSY
        // fehl, sobald der Soundserver sie haelt), kann andere Programme
        // stummschalten, und man muss Samplerate/Format nehmen, wie die Hardware
        // sie will — ohne Resampling, ohne Mischer.
        //
        // Letzter Parameter 0 = blockierender Modus: `snd_pcm_writei` kehrt erst
        // zurueck, wenn im Ringpuffer wieder Platz war. Genau das wollen wir —
        // dieses Blockieren ist die Uhr, die unseren Thread im Takt haelt.
        var handle: OpaquePointer?
        let openResult = snd_pcm_open(&handle, "default", SND_PCM_STREAM_PLAYBACK, 0)
        guard openResult == 0, let pcm = handle else {
            throw PCMSinkError.deviceUnavailable(ALSAPCMSink.alsaMessage(openResult))
        }

        // --- Format einstellen ------------------------------------------------
        //
        // WARUM `snd_pcm_set_params` und nicht die hw_params-API?
        // Die hw_params-API ist der lange Weg: Container allozieren, `any()`,
        // dann je ein Aufruf fuer Access, Format, Kanaele, Rate, Periodengroesse,
        // Puffergroesse, danach `hw_params()`, danach dasselbe Spiel mit
        // sw_params fuer Start-Schwelle und avail_min. Das lohnt sich, wenn man
        // Periodengroessen exakt steuern oder aushandeln will, was die Hardware
        // hergibt. Wir wollen nichts davon: ein festes, ueberall vorhandenes
        // Format (S16_LE, interleaved) und eine Wunschlatenz. Genau dafuer gibt
        // es `snd_pcm_set_params` — die offizielle "simple setup"-Funktion aus
        // alsa-lib, die hw_params und sw_params in einem Aufruf mit vernuenftigen
        // Vorgaben erledigt. Weniger Aufrufe = weniger Fehlerpfade = weniger,
        // was hier ungetestet schieflaufen kann.
        //
        // soft_resample = 1: Falls die Hardware unsere Samplerate nicht kann,
        // darf ALSA umrechnen, statt den Aufruf abzulehnen.
        let setResult = snd_pcm_set_params(pcm,
                                           SND_PCM_FORMAT_S16_LE,
                                           SND_PCM_ACCESS_RW_INTERLEAVED,
                                           UInt32(format.channels),
                                           UInt32(format.sampleRate.rounded()),
                                           1,
                                           ALSAPCMSink.latencyMicroseconds)
        guard setResult == 0 else {
            // Kein Leak: das eben geoeffnete Geraet wieder schliessen, bevor wir werfen.
            _ = snd_pcm_close(pcm)
            throw PCMSinkError.unsupportedFormat(format)
        }

        pcmHandle = pcm
        renderBlock = render
        canPause = ALSAPCMSink.queryCanPause(pcm)

        cond.lock()
        state = .running
        cond.unlock()

        // `[weak self]`: siehe `playbackThread`. Waehrend `playbackLoop()`
        // laeuft, haelt die Optional-Verkettung `self` ohnehin stark — die
        // Klasse kann uns also nicht unter den Fuessen weggeraeumt werden.
        let thread = Thread { [weak self] in
            self?.playbackLoop()
        }
        thread.name = "ALSAPCMSink"
        playbackThread = thread
        thread.start()
    }

    /// Haelt an; das Geraet bleibt offen und `resume()` macht weiter.
    ///
    /// Wirkt erst, wenn der Wiedergabe-Thread den naechsten Block abgeschlossen
    /// hat (spaetestens nach ~23 ms) — hier wird nur der Wunsch hinterlegt.
    /// Aufruf im falschen Zustand (nie gestartet, schon gestoppt) ist ein No-op.
    public func pause() throws {
        cond.lock()
        if state == .running {
            state = .paused
            cond.broadcast()
        }
        cond.unlock()
    }

    public func resume() throws {
        cond.lock()
        if state == .paused {
            state = .running
            cond.broadcast()
        }
        cond.unlock()
    }

    /// Beendet die Wiedergabe und gibt das Geraet frei. Doppelter Aufruf ist
    /// harmlos; nach dem ersten ist der Sink `.finished` und die zweite Runde
    /// kehrt sofort zurueck.
    ///
    /// Blockiert, bis der Thread wirklich weg ist — sonst koennte das Handle
    /// unter ihm weggeschlossen werden. Das dauert hoechstens einen Blockschreib-
    /// vorgang lang (der Thread haengt ggf. noch in `snd_pcm_writei`).
    public func stop() {
        cond.lock()

        // Nie gestartet: Es gibt keinen Thread, der den Grund setzen koennte —
        // also gleich hier festhalten, sonst wartete waitUntilFinished() ewig.
        // Der Sink gilt danach als durch und laesst sich nicht mehr starten.
        if state == .idle {
            settleReasonLocked(.notStarted)
            state = .finished
            cond.broadcast()
            cond.unlock()
            return
        }

        // Schon vorbei: Der Grund steht laengst fest, nichts mehr zu tun.
        if state == .finished {
            cond.unlock()
            return
        }

        // Der erste Grund gewinnt: Ist die Quelle in genau diesem Moment
        // ausgelaufen und hat `.sourceFinished` schon hinterlegt, bleibt es dabei.
        settleReasonLocked(.stopped)
        state = .stopping
        cond.broadcast()

        // Sonderfall: stop() kam aus dem Renderblock, laeuft also auf dem
        // Wiedergabe-Thread selbst. Dann duerfen wir nicht auf uns selbst warten
        // — das Flag genuegt, der Thread sieht es gleich nach der Rueckkehr.
        if let thread = playbackThread, Thread.current === thread {
            cond.unlock()
            return
        }

        while state != .finished {
            cond.wait()
        }
        cond.unlock()
    }

    @discardableResult
    public func waitUntilFinished() -> PCMSinkFinishReason {
        cond.lock()
        defer { cond.unlock() }
        // Nie gestartet: es gibt nichts, worauf man warten koennte.
        if state == .idle {
            return .notStarted
        }
        // Aus dem Renderblock heraus wuerden wir uns selbst blockieren. Der Grund
        // steht dann womoeglich noch gar nicht fest — mehr als „bisher nichts
        // entschieden" laesst sich hier ehrlich nicht sagen.
        if let thread = playbackThread, Thread.current === thread {
            return finishReason
        }
        while state != .finished {
            cond.wait()
        }
        return finishReason
    }

    // MARK: - Wiedergabe-Thread

    private func playbackLoop() {
        guard let handle = pcmHandle, let render = renderBlock else {
            // Sollte nicht vorkommen: `start()` setzt beides, bevor der Thread
            // losfaehrt. Trotzdem einen Grund hinterlassen, damit ein Warter nicht
            // faelschlich `.notStarted` gemeldet bekommt.
            setFailure("Wiedergabe-Thread ohne geoeffnetes Geraet gestartet.")
            finish(drain: false)
            return
        }

        let capacity = ALSAPCMSink.framesPerBlock
        // Merkt sich, ob die Quelle von selbst zu Ende war. Nur dann spielen wir
        // den Ringpuffer aus (drain); bei stop() wird er verworfen (drop).
        var sourceExhausted = false

        while true {
            // 1. Pausenwunsch abarbeiten / auf stop() pruefen.
            guard awaitRunnable(handle: handle) else { break }

            // 2. Nachschub holen. Der Block schreibt interleaved Floats in
            //    `floatBuffer` und meldet, wie viele Frames er wirklich gefuellt
            //    hat. Weniger als angefragt heisst: Quelle erschoepft.
            let reported = render(floatBuffer, capacity)
            let frames = max(0, min(reported, capacity))

            if frames > 0 {
                convertToInt16(frames: frames)
                guard writeAll(handle: handle, frames: frames) else { break }
            }

            if frames < capacity {
                sourceExhausted = true
                // Den Grund SOFORT festhalten, nicht erst in `finish()`: Ruft
                // jemand in derselben Millisekunde stop(), soll das regulaere Ende
                // gewinnen (der erste Grund gewinnt).
                settleReason(.sourceFinished)
                break
            }
        }

        finish(drain: sourceExhausted)
    }

    /// Wartet, bis wieder gespielt werden darf. Liefert `false`, wenn der Thread
    /// enden soll. Erledigt nebenbei das Anhalten und Fortsetzen am Geraet —
    /// beides passiert bewusst hier, auf dem Wiedergabe-Thread.
    private func awaitRunnable(handle: OpaquePointer) -> Bool {
        cond.lock()
        defer { cond.unlock() }

        if state == .paused {
            enterPause(handle)
            while state == .paused {
                cond.wait()
            }
            // Nur zurueckholen, wenn es weitergeht. Bei .stopping macht
            // `finish()` gleich ohnehin drop + close.
            if state == .running {
                leavePause(handle)
            }
        }
        return state == .running
    }

    /// Haelt das Geraet an.
    ///
    /// **Weg 1 — echtes Pause:** `snd_pcm_pause(handle, 1)` friert die Wiedergabe
    /// an der aktuellen Position ein. Der Ringpuffer bleibt gefuellt, das
    /// Fortsetzen ist luecken- und knackserfrei. Das koennen aber laengst nicht
    /// alle Geraete — und die Software-Plugins hinter "default" (dmix, pulse,
    /// pipewire) gehoeren typischerweise NICHT dazu. `snd_pcm_hw_params_can_pause`
    /// sagt uns vorher, was Sache ist.
    ///
    /// **Weg 2 — Fallback:** `snd_pcm_drop` bricht sofort ab und verwirft den
    /// Ringpuffer; danach parkt der Thread auf der Condition und verbraucht
    /// nichts. Bewusst NICHT genommen wurden die beiden naheliegenden
    /// Alternativen:
    ///   * Stille schreiben — haelt den Thread und die Soundkarte unnoetig auf
    ///     Trab und laesst zudem den bereits gepufferten Ton noch weiterlaufen,
    ///     die Pause wuerde also spuerbar zu spaet einsetzen.
    ///   * `snd_pcm_drain` — wartet, bis der Puffer leergespielt ist, blockiert
    ///     also die Pause um eine ganze Pufferlaenge. Drain ist fuer "Ende",
    ///     nicht fuer "Moment mal".
    ///
    /// Der Preis des Fallbacks: die bis zu ~100 ms, die schon gerendert, aber
    /// noch nicht hoerbar waren, sind weg. Beim Fortsetzen springt der Ton also
    /// minimal — der Emulationszustand bleibt davon voellig unberuehrt, denn den
    /// kennt der Sink gar nicht.
    private func enterPause(_ handle: OpaquePointer) {
        var viaHardware = false
        if canPause {
            // Kann trotz can_pause fehlschlagen, z. B. mit -EBADFD, wenn der
            // Stream noch gar nicht lief. Dann eben der Fallback.
            viaHardware = (snd_pcm_pause(handle, 1) == 0)
        }
        if !viaHardware {
            _ = snd_pcm_drop(handle)
        }
        pausedViaHardware = viaHardware
    }

    /// Gegenstueck zu `enterPause` — muss zum gewaehlten Weg passen.
    private func leavePause(_ handle: OpaquePointer) {
        if pausedViaHardware {
            if snd_pcm_pause(handle, 0) < 0 {
                // Auftauen missglueckt: neu scharf machen ist der sichere Ausweg.
                _ = snd_pcm_prepare(handle)
            }
        } else {
            // Nach `snd_pcm_drop` ist der Stream nicht mehr spielbereit;
            // `prepare` bringt ihn zurueck in den Zustand, in dem `writei`
            // wieder angenommen wird.
            _ = snd_pcm_prepare(handle)
        }
        pausedViaHardware = false
    }

    /// Wandelt `frames` Frames aus `floatBuffer` nach Int16 in `pcmBuffer`.
    ///
    /// Hartes Clipping wie im WAV-Export: alles ausserhalb -1…1 wird auf den
    /// Rand geklemmt, damit die Multiplikation mit 32767 garantiert in einen
    /// Int16 passt (ohne Klemmen wuerde der Int16-Konstruktor bei Ueberlauf
    /// hart abstuerzen). Die Reihenfolge max(min(…)) faengt nebenbei NaN ab:
    /// ein Vergleich mit NaN ist immer falsch, `min` liefert dann den ersten
    /// Operanden — also 1.0 statt eines Absturzes.
    ///
    /// Ein- und Ausgang sind interleaved und gleich sortiert, es wird nur der
    /// Zahlentyp getauscht — kein Umsortieren noetig.
    private func convertToInt16(frames: Int) {
        let sampleCount = frames * channelCount
        for i in 0..<sampleCount {
            let clamped = max(-1.0, min(1.0, floatBuffer[i]))
            pcmBuffer[i] = Int16(clamped * 32767.0)
        }
    }

    /// Schreibt `frames` Frames vollstaendig ans Geraet. Liefert `false`, wenn
    /// abgebrochen werden soll (stop() oder ein Fehler, aus dem es keinen
    /// Rueckweg gibt).
    ///
    /// Hier liegen die klassischen Knackser-Fehler — deshalb die Schleife:
    /// `snd_pcm_writei` liefert die Zahl der geschriebenen FRAMES (nicht Bytes,
    /// nicht Samples) und darf weniger als angefragt schreiben. Der Rest muss
    /// nachgereicht werden, sonst fehlt ein Stueck Ton.
    private func writeAll(handle: OpaquePointer, frames: Int) -> Bool {
        var offset = 0
        var remaining = frames
        var resumeAttempts = 0

        while remaining > 0 {
            if isStopRequested() { return false }

            // Rueckgabetyp ist snd_pcm_sframes_t (signed long): >= 0 ist die
            // Zahl der geschriebenen Frames, < 0 ein negierter errno-Code.
            let written = snd_pcm_writei(handle,
                                         pcmBuffer + offset * channelCount,
                                         snd_pcm_uframes_t(remaining))

            if written >= 0 {
                offset += Int(written)
                remaining -= Int(written)
                resumeAttempts = 0
                continue
            }

            let err = Int32(truncatingIfNeeded: written)

            if err == -EPIPE {
                // Underrun: Der Ringpuffer lief leer. Ton ist verloren, aber der
                // Stream ist zu retten — `prepare` macht ihn wieder scharf, der
                // naechste writei laeuft normal weiter. NICHT abbrechen: ein
                // einzelner Hickser (Lastspitze, Suspend, langsamer Renderblock)
                // darf keinen stummen Player hinterlassen.
                let rc = snd_pcm_prepare(handle)
                if rc < 0 {
                    setFailure("Neustart nach Underrun fehlgeschlagen: "
                               + ALSAPCMSink.alsaMessage(rc))
                    return false
                }
                continue
            }

            if err == -ESTRPIPE {
                // Das System war suspendiert (Deckel zu, Standby). Das Geraet
                // muss erst wieder aufwachen. `snd_pcm_resume` antwortet mit
                // -EAGAIN, solange das noch dauert — laut ALSA-Doku wartet man
                // dann und versucht es erneut.
                let rc = snd_pcm_resume(handle)
                if rc == -EAGAIN {
                    resumeAttempts += 1
                    if resumeAttempts > 100 {  // ~10 s Geduld
                        setFailure("Geraet ist nach Suspend nicht aufgewacht.")
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                if rc < 0 {
                    // Kein Resume moeglich (haeufig — nicht jeder Treiber kann
                    // das). Dann bleibt nur: neu scharf machen und weiterspielen.
                    let prepared = snd_pcm_prepare(handle)
                    if prepared < 0 {
                        setFailure("Neustart nach Suspend fehlgeschlagen: "
                                   + ALSAPCMSink.alsaMessage(prepared))
                        return false
                    }
                }
                resumeAttempts = 0
                continue
            }

            if err == -EAGAIN || err == -EINTR {
                // -EAGAIN: gerade kein Platz im Puffer (im blockierenden Modus
                // eigentlich unmoeglich, aber billig abzufangen).
                // -EINTR: ein Signal kam dazwischen. Beides ist kein Fehler,
                // sondern ein "nochmal". Kurz durchatmen, damit wir bei einem
                // unerwarteten Dauer-EAGAIN keinen Kern verheizen.
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }

            setFailure("Schreiben ans Audiogeraet fehlgeschlagen: "
                       + ALSAPCMSink.alsaMessage(err))
            return false
        }
        return true
    }

    /// Raeumt auf und meldet allen Wartenden, dass Schluss ist.
    ///
    /// `drain` = true (Quelle war zu Ende): Ringpuffer noch ausspielen, damit
    /// die letzten ~100 ms Musik nicht abgeschnitten werden — `snd_pcm_drain`
    /// blockiert dafuer genau so lange.
    /// `drain` = false (stop() oder Fehler): `snd_pcm_drop` bricht sofort ab und
    /// wirft den Rest weg — bei "Stop" will niemand noch eine Zehntelsekunde
    /// Nachschlag hoeren.
    private func finish(drain: Bool) {
        if let handle = pcmHandle {
            if drain {
                _ = snd_pcm_drain(handle)
            } else {
                // Rueckgabe egal: auf einem bereits gedroppten Stream meldet das
                // -EBADFD, was hier voellig harmlos ist.
                _ = snd_pcm_drop(handle)
            }
            _ = snd_pcm_close(handle)
            // Auf nil setzen, damit weder deinit noch ein zweiter Weg das Handle
            // ein zweites Mal schliesst.
            pcmHandle = nil
        }
        // Renderblock loslassen: er haelt womoeglich die Emulation am Leben.
        renderBlock = nil

        cond.lock()
        // Sicherheitsnetz: Ohne Grund darf hier niemand rausgehen, sonst meldete
        // waitUntilFinished() faelschlich `.notStarted`. Normalerweise steht der
        // Grund laengst fest (Quellenende, stop() oder ein Fehler) und dieser
        // Aufruf tut nichts — der erste Grund gewinnt.
        settleReasonLocked(drain ? .sourceFinished : .stopped)
        state = .finished
        cond.broadcast()
        cond.unlock()
    }

    // MARK: - Kleinkram

    private func isStopRequested() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        return state == .stopping
    }

    /// Haelt einen Ausgabefehler als Endgrund fest. Der Wiedergabe-Thread kann
    /// nicht werfen — der Text erreicht den Aufrufer deshalb ueber
    /// `waitUntilFinished()` als `.failed(...)`.
    private func setFailure(_ message: String) {
        settleReason(.failed(message))
    }

    /// Schreibt den Endgrund fest. Der ERSTE Grund gewinnt: Laeuft die Quelle
    /// gerade aus, waehrend jemand stop() ruft, bleibt es beim regulaeren Ende.
    /// Erwartet, dass `cond` bereits gehalten wird.
    private func settleReasonLocked(_ reason: PCMSinkFinishReason) {
        guard !finishReasonSettled else { return }
        finishReasonSettled = true
        finishReason = reason
    }

    /// Wie `settleReasonLocked`, nimmt `cond` aber selbst.
    private func settleReason(_ reason: PCMSinkFinishReason) {
        cond.lock()
        settleReasonLocked(reason)
        cond.unlock()
    }

    /// Fragt das geoeffnete Geraet, ob es echtes Pause beherrscht.
    ///
    /// Der Umweg ueber hw_params ist noetig, weil `can_pause` eine Eigenschaft
    /// der ausgehandelten Konfiguration ist, nicht des Handles.
    /// `snd_pcm_hw_params_current` fuellt den Container mit dem, was
    /// `snd_pcm_set_params` gerade eingestellt hat. Die Allokation laeuft ueber
    /// malloc/free statt ueber das uebliche `snd_pcm_hw_params_alloca` — das ist
    /// ein C-Makro und in Swift schlicht nicht vorhanden.
    private static func queryCanPause(_ handle: OpaquePointer) -> Bool {
        var params: OpaquePointer?
        guard snd_pcm_hw_params_malloc(&params) == 0, let hw = params else {
            return false
        }
        defer { snd_pcm_hw_params_free(hw) }
        guard snd_pcm_hw_params_current(handle, hw) == 0 else {
            return false
        }
        return snd_pcm_hw_params_can_pause(hw) == 1
    }

    /// Uebersetzt einen ALSA-Fehlercode in Klartext. `snd_strerror` kennt neben
    /// den normalen errno-Werten auch die ALSA-eigenen Codes.
    private static func alsaMessage(_ code: Int32) -> String {
        guard let text = snd_strerror(code) else {
            return "unbekannter ALSA-Fehler (\(code))"
        }
        return String(cString: text)
    }
}
#endif
