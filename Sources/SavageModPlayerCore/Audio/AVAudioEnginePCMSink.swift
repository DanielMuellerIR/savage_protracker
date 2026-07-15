import Foundation

// AVFoundation ist ein Apple-Framework und existiert unter Linux nicht. Die
// gesamte Datei faellt dort deshalb aus der Uebersetzung heraus — genauso, wie es
// ModPlayerCoordinator.swift bereits macht. Auf Linux uebernimmt ALSAPCMSink die
// Ausgabe (oder StdoutPCMSink, wenn in eine Pipe geschrieben wird).
#if canImport(AVFoundation)
import AVFoundation

// ============================================================================
// AVAudioEnginePCMSink — Echtzeit-Ausgabe auf Apple-Plattformen.
//
// Herkunft: uebernommen aus vicious_sidplayer (siehe PCMSink.swift). Das Muster
// ist dasselbe wie im ModPlayerCoordinator: AVAudioEngine + AVAudioSourceNode am
// Haupt-Mixer. Der Unterschied ist nur, WOHER die Samples kommen: der Coordinator
// baut sich seinen Renderblock selbst und versorgt nebenbei VU-Meter und
// Oszilloskope, dieser Sink kennt davon nichts und fragt bloss den
// plattformneutralen `PCMRenderBlock`. Genutzt wird er vom CLI — die App bleibt
// beim Coordinator.
//
// Interleaved vs. getrennte Kanaele
// ---------------------------------
// Das ist der einzige echte Knackpunkt. `PCMRenderBlock` liefert **interleaved**:
//
//   [L0, R0, L1, R1, L2, R2, …]
//
// AVAudioSourceNode will die Kanaele aber im Standardformat **getrennt**
// (deinterleaved), also zwei eigene Bloecke:
//
//   buffers[0] = [L0, L1, L2, …]   buffers[1] = [R0, R1, R2, …]
//
// Also holt sich der Renderblock die Samples in einen Zwischenpuffer und sortiert
// sie beim Kopieren auseinander. Dieser Zwischenpuffer wird VORAB in start()
// angelegt — im Renderblock selbst darf nicht alloziert werden (siehe unten).
//
// Echtzeit-Thread: was hier verboten ist
// --------------------------------------
// Der Renderblock laeuft auf einem Realtime-Thread von CoreAudio. Der hat ein
// hartes Zeitbudget: Kommen die Samples nicht rechtzeitig, spielt die Soundkarte
// den alten Pufferinhalt weiter — das hoert man als Knackser („Dropout"). Alles,
// was unvorhersehbar lange dauern kann, ist deshalb tabu: Speicher allozieren,
// auf Locks warten, Datei-I/O, print(), Swift-Runtime-Aufrufe mit Retain/Release
// auf geteilten Objekten. Deshalb arbeitet der Block ausschliesslich auf vorab
// allozierten Zeigern und faengt keine Referenz auf `self` ein.
//
// Und genau daraus folgt, wie der Endgrund hier zustande kommt: Der
// Realtime-Thread DARF `PCMSinkFinishReason` nicht selbst hinterlegen (Lock,
// String, Enum mit Nutzlast — alles verboten). Er setzt nur den rohen Bool
// `didFinish` und gibt das Semaphor frei. Wer aufwacht, uebersetzt das dann in
// `.sourceFinished`. Siehe waitUntilFinished().
// ============================================================================

/// Transportiert die vorab allozierten Zeiger in den `@Sendable`-Renderblock.
///
/// Warum es diese Huelle braucht: Swift 6 haelt rohe Zeiger fuer nicht-Sendable,
/// und das zu Recht — der Compiler kann nicht wissen, wer sonst noch auf denselben
/// Speicher zeigt. Hier wissen WIR es:
///
/// * `scratch` fasst nach `start()` ausschliesslich der Realtime-Thread an, und
///   `stop()` gibt ihn erst frei, NACHDEM `engine.stop()` zurueckgekehrt ist —
///   dann laeuft garantiert kein Renderblock mehr.
/// * `didFinish` schreibt nur der Realtime-Thread, und zwar genau einmal, direkt
///   bevor er das Semaphor freigibt. Wer den Merker von aussen liest, tut das
///   entweder nach genau diesem Semaphor (das Semaphor ordnet Schreiben vor
///   Lesen) oder nach `engine.stop()`. Der Speicher selbst lebt bis `deinit` und
///   kann dem Leser deshalb nicht unter den Fuessen wegbrechen.
///
/// Es gibt also zu keinem Zeitpunkt zwei gleichzeitige Zugriffe. Das
/// `@unchecked` ist damit ein Versprechen, das der Code drumherum einhaelt, und
/// kein Wegschauen vor einem echten Datenrennen.
private struct RenderPointers: @unchecked Sendable {
    /// Zwischenpuffer fuer die interleavten Float-Samples des Renderblocks.
    let scratch: UnsafeMutablePointer<Float>
    /// Merker „Quelle ist erschoepft" — geschrieben nur vom Realtime-Thread.
    let didFinish: UnsafeMutablePointer<Bool>
}

// `@unchecked Sendable` wie bei den Schwester-Sinks und aus demselben Grund ehrlich:
// Der veraenderliche Zustand (`state`) liegt vollstaendig hinter `lock`, `didFinish`
// wird nur vom Realtime-Thread geschrieben und erst nach dem Semaphor gelesen (siehe
// RenderPointers oben), und alles Uebrige ist `let`. Der Compiler kann das nicht
// nachweisen, der Code drumherum haelt es ein.
public final class AVAudioEnginePCMSink: PCMSink, @unchecked Sendable {

    /// Zustand der Wiedergabe. Bewusst identisch zum Vertrag in `PCMSink` und zu
    /// StdoutPCMSink: `pause()` haelt nur an, `stop()` beendet endgueltig, und
    /// aus `.stopped` fuehrt kein Weg zurueck (ein Sink ist Einweg).
    private enum State {
        case idle       // start() wurde noch nicht gerufen
        case running    // Engine spielt
        case paused     // angehalten, Knoten und Puffer bleiben stehen
        case stopped    // endgueltig beendet (durch stop() oder Startfehler)
    }

    public let format: PCMFormat

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Vorab allozierter Zwischenpuffer fuer die interleavten Float-Samples aus
    /// dem Renderblock. Lebt von start() bis stop().
    private var scratch: UnsafeMutableBufferPointer<Float>?

    /// Merker fuer „Quelle ist erschoepft". Geschrieben wird er ausschliesslich
    /// vom Realtime-Thread (genau einmal), gelesen von stop() und
    /// waitUntilFinished() — beides erst, wenn der Schreiber sicher durch ist
    /// (siehe RenderPointers). Deshalb genuegt ein einfacher Zeiger ohne Lock.
    ///
    /// Er lebt vom Konstruktor bis `deinit` und NICHT nur von start() bis stop():
    /// waitUntilFinished() liest ihn und darf dabei nicht auf freigegebenen
    /// Speicher zeigen.
    private let didFinish: UnsafeMutablePointer<Bool>

    /// Signal fuer waitUntilFinished(). Ein Semaphor statt einer NSCondition,
    /// weil `signal()` vom Realtime-Thread aus deutlich harmloser ist als ein
    /// blockierendes Lock — und weil es hier genau EINMAL passiert: in dem
    /// Moment, in dem die Quelle versiegt. Selbst wenn dieser eine Aufruf einen
    /// Weck-Syscall ausloest, ist das Stueck an dieser Stelle ohnehin vorbei.
    private let finishSignal = DispatchSemaphore(value: 0)

    /// Schuetzt `state`, `finished` und `finishReason`. Bewusst ein schlichtes
    /// Lock: Der Realtime-Thread fasst es NIE an (sein Block faengt kein `self`
    /// ein), nur Aufrufer- und Warter-Threads.
    private let lock = NSLock()
    private var state: State = .idle
    private var finished = false
    /// Warum die Wiedergabe endete — wird genau einmal gesetzt (der erste Grund
    /// gewinnt) und von waitUntilFinished() zurueckgegeben.
    private var finishReason: PCMSinkFinishReason = .notStarted

    /// Obergrenze des Zwischenpuffers. AVAudioEngine fragt normalerweise deutlich
    /// weniger Frames pro Aufruf ab (Groessenordnung 512). Fragt sie doch einmal
    /// mehr, rendert der Block unten einfach in mehreren Runden — Hauptsache, er
    /// alloziert nicht nach.
    private static let maxScratchFrames = 8192

    /// - Parameter format: Samplerate und Kanalzahl, in denen der Renderblock
    ///   liefert. Weicht die Samplerate von der Hardware ab, rechnet die
    ///   AVAudioEngine im Mixer um. Wer das vermeiden will, fragt vorher
    ///   `hardwareFormat()` und baut seine Quelle gleich mit dieser Rate auf.
    public init(format: PCMFormat = PCMFormat()) {
        self.format = format
        // Ende-Merker gleich hier anlegen — siehe Kommentar an `didFinish`.
        self.didFinish = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        self.didFinish.initialize(to: false)
    }

    deinit {
        stop()
        // Erst jetzt freigeben: stop() hat die Engine angehalten, danach liest
        // niemand mehr mit.
        didFinish.deinitialize(count: 1)
        didFinish.deallocate()
    }

    /// Liefert das Format, in dem die Audio-Hardware gerade laeuft — typisch
    /// 44100 oder 48000 Hz. Gedacht fuer den Aufrufer, der seine Quelle passend
    /// aufbauen will, BEVOR er den Sink erzeugt.
    ///
    /// Der Fallback auf 44100 entspricht dem des ModPlayerCoordinator: Meldet die
    /// Engine 0, NaN oder unendlich (kein Ausgabegeraet, Geraetewechsel), waere
    /// jede Rechnung damit unbrauchbar.
    public static func hardwareFormat(channels: Int = 2) -> PCMFormat {
        let probe = AVAudioEngine()
        let rate = sanitizedSampleRate(probe.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        return PCMFormat(sampleRate: rate, channels: channels)
    }

    private static func sanitizedSampleRate(_ rate: Double) -> Double {
        if rate <= 0.0 || rate.isNaN || rate.isInfinite { return 44100.0 }
        return rate
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .running
    }

    // MARK: - Lebenszyklus

    public func start(render: @escaping PCMRenderBlock) throws {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            // Ein Sink ist Einweg (siehe Protokoll-Doku): laeuft er schon, ist er
            // pausiert oder durch, wird nicht erneut gestartet, sondern ein neuer
            // gebaut. Ein stilles Zurueckkehren wuerde hier einen
            // Programmierfehler verstecken — der Vertrag verlangt eine klare Ansage.
            throw PCMSinkError.invalidState("AVAudioEnginePCMSink wurde bereits gestartet.")
        }
        // Sofort als „nicht mehr frisch" markieren: Ein zweiter start() darf auch
        // dann nicht durchrutschen, wenn dieser hier gleich mit einem Fehler endet.
        state = .running
        lock.unlock()

        let channels = max(1, min(format.channels, 2))

        // Samplerate der Hardware abfragen — genau wie der Coordinator es tut.
        // Sie entscheidet nur noch, was passiert, wenn der Aufrufer selbst keine
        // brauchbare Rate mitgegeben hat; ansonsten dient sie als Erklaerung
        // dafuer, ob die Engine umrechnen muss.
        let hardwareRate = Self.sanitizedSampleRate(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        let renderRate = (format.sampleRate > 0.0 && format.sampleRate.isFinite) ? format.sampleRate : hardwareRate

        // Standardformat = 32-Bit-Float, deinterleaved. Genau dieses Format
        // erwartet der Renderblock des SourceNode weiter unten.
        guard let nodeFormat = AVAudioFormat(standardFormatWithSampleRate: renderRate,
                                             channels: AVAudioChannelCount(channels)) else {
            throw failStart(.unsupportedFormat(format))
        }

        // Zwischenpuffer VOR dem Start anlegen — im Realtime-Thread waere das eine
        // verbotene Allokation.
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: Self.maxScratchFrames * channels)
        scratch.initialize(repeating: 0.0)
        self.scratch = scratch

        guard let scratchBase = scratch.baseAddress else {
            cleanupBuffers()
            throw failStart(.deviceUnavailable("Zwischenpuffer konnte nicht angelegt werden."))
        }
        let pointers = RenderPointers(scratch: scratchBase, didFinish: didFinish)
        let maxFrames = Self.maxScratchFrames
        // Das Semaphor als lokale Konstante greifen, damit der Block unten `self`
        // nicht einfangen muss.
        let signalSemaphore = finishSignal

        // Der Renderblock. Er faengt bewusst NUR Werte ein, die der Realtime-
        // Thread gefahrlos anfassen darf: rohe Zeiger, Zahlen, den Sendable-
        // Renderblock und das Semaphor. Kein `self` — sonst haenge der komplette
        // Sink (samt AVAudioEngine) am Realtime-Thread.
        let renderBlock: @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus = { isSilence, _, frameCount, outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= channels,
                  let leftRaw = buffers[0].mData else {
                isSilence.pointee = true
                return noErr
            }
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            // Bei Mono gibt es nur einen Zielblock; bei Stereo den zweiten dazu.
            let right: UnsafeMutablePointer<Float>? = (channels > 1)
                ? buffers[1].mData?.assumingMemoryBound(to: Float.self)
                : nil

            let total = Int(frameCount)

            // Quelle ist schon durch: Stille ausgeben. Ohne das wuerde die
            // Soundkarte den letzten Pufferinhalt endlos wiederholen (brummen).
            if pointers.didFinish.pointee {
                for frame in 0..<total {
                    left[frame] = 0.0
                    right?[frame] = 0.0
                }
                isSilence.pointee = true
                return noErr
            }

            var written = 0
            var exhausted = false
            while written < total {
                // In Haeppchen rendern, die in den Zwischenpuffer passen.
                let chunk = min(maxFrames, total - written)
                let view = UnsafeMutableBufferPointer<Float>(start: pointers.scratch, count: chunk * channels)
                let filled = min(max(0, render(view, chunk)), chunk)

                // Umsortieren: aus [L0, R0, L1, R1, …] werden zwei getrennte Bloecke.
                for frame in 0..<filled {
                    left[written + frame] = pointers.scratch[frame * channels]
                    if let right = right {
                        right[written + frame] = pointers.scratch[frame * channels + 1]
                    }
                }
                written += filled

                if filled < chunk {
                    // Weniger Frames als angefordert = Quelle erschoepft.
                    exhausted = true
                    break
                }
            }

            if exhausted {
                // Rest des Blocks mit Stille auffuellen, damit kein Muell klingt.
                for frame in written..<total {
                    left[frame] = 0.0
                    right?[frame] = 0.0
                }
                // Merken und genau EINMAL Bescheid geben (siehe finishSignal).
                // Mehr geht hier nicht: `.sourceFinished` selbst zu hinterlegen
                // hiesse Lock nehmen — auf dem Realtime-Thread verboten. Den Bool
                // uebersetzt deshalb waitUntilFinished() bzw. stop() in den Grund.
                pointers.didFinish.pointee = true
                signalSemaphore.signal()
                if written == 0 { isSilence.pointee = true }
            }

            return noErr
        }

        let node = AVAudioSourceNode(format: nodeFormat, renderBlock: renderBlock)
        self.sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nodeFormat)

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            // Symmetrisch abbauen: Der Knoten haengt schon im Graph und wuerde
            // sonst leaken; ein zweiter start()-Versuch haenge dann einen weiteren
            // Knoten an.
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            self.sourceNode = nil
            cleanupBuffers()
            throw failStart(.deviceUnavailable(error.localizedDescription))
        }
    }

    public func pause() throws {
        lock.lock()
        defer { lock.unlock() }
        // Auf einem nicht laufenden Sink wirkungslos — kein Fehler (Vertrag).
        guard state == .running else { return }
        // pause() haelt die Engine an, BEHAELT aber Knoten und Puffer — resume()
        // macht danach exakt hier weiter. Das ist derselbe Vertrag wie bei der
        // macOS-Wiedergabe im ModPlayerCoordinator.
        engine.pause()
        state = .paused
    }

    public func resume() throws {
        lock.lock()
        // Auf einem nicht pausierten Sink wirkungslos — kein Fehler (Vertrag).
        guard state == .paused else {
            lock.unlock()
            return
        }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            state = .running
            lock.unlock()
        } catch {
            lock.unlock()
            // Die Engine laeuft nicht wieder an — damit ist die Wiedergabe
            // gescheitert und nicht bloss dieser eine Aufruf. Ohne die Meldung
            // wartete waitUntilFinished() ewig: Der Renderblock kommt nie mehr dran.
            finish(reason: .failed(error.localizedDescription))
            throw PCMSinkError.deviceUnavailable(error.localizedDescription)
        }
    }

    public func stop() {
        lock.lock()
        // Nie gestartet: Es gab nichts zu spielen — der Grund steht damit fest.
        let wasIdle = (state == .idle)
        lock.unlock()

        // Reihenfolge ist wichtig: erst die Engine anhalten (danach laeuft
        // garantiert kein Renderblock mehr), dann lesen und freigeben. Andersherum
        // griffe der Realtime-Thread auf freigegebenen Speicher zu.
        engine.stop()
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        sourceNode = nil

        // Jetzt, wo die Engine steht, darf der Ende-Merker gefahrlos gelesen
        // werden. Ist die Quelle gerade noch ausgelaufen, gewinnt ihr Grund vor
        // `.stopped` — genau das meint „der erste Grund gewinnt".
        let reason: PCMSinkFinishReason
        if wasIdle {
            reason = .notStarted
        } else if didFinish.pointee {
            reason = .sourceFinished
        } else {
            reason = .stopped
        }

        // Warter aufwecken, auch wenn die Quelle nie versiegt ist.
        finish(reason: reason)
        cleanupBuffers()
    }

    @discardableResult
    public func waitUntilFinished() -> PCMSinkFinishReason {
        lock.lock()
        // Nie gestartet: nichts zu warten.
        if state == .idle {
            lock.unlock()
            return .notStarted
        }
        let alreadyFinished = finished
        lock.unlock()

        if !alreadyFinished {
            finishSignal.wait()
            // Sofort wieder freigeben: So kommen auch spaetere/weitere Aufrufe
            // durch, statt am schon verbrauchten Signal haengenzubleiben.
            finishSignal.signal()
            // Geweckt hat uns entweder finish() — dann steht der Grund schon — oder
            // der Realtime-Thread, der ihn nicht selbst hinterlegen darf. Also
            // uebersetzen wir seinen Bool hier nach. Das Semaphor sorgt dafuer,
            // dass sein Schreiben vor diesem Lesen liegt.
            if didFinish.pointee {
                finish(reason: .sourceFinished)
            }
        }

        lock.lock()
        defer { lock.unlock() }
        return finishReason
    }

    // MARK: - Kleinkram

    /// Markiert das Ende und weckt alle, die in `waitUntilFinished()` warten.
    /// Der ERSTE Grund gewinnt: laeuft die Quelle gerade aus, waehrend jemand
    /// stop() ruft, bleibt es beim regulaeren Ende.
    private func finish(reason: PCMSinkFinishReason) {
        lock.lock()
        if !finished {
            finished = true
            finishReason = reason
        }
        state = .stopped
        lock.unlock()
        finishSignal.signal()
    }

    /// Startfehler festhalten und den passenden Fehler zum Werfen zurueckgeben.
    /// Der Sink ist danach durch — er ist Einweg, und ein halb aufgebauter
    /// Renderpfad laesst sich nicht sinnvoll wiederbeleben. Wer noch in
    /// waitUntilFinished() haengt, bekommt so `.failed` statt ewiger Wartezeit.
    private func failStart(_ error: PCMSinkError) -> PCMSinkError {
        finish(reason: .failed(error.localizedDescription))
        return error
    }

    /// Gibt den Zwischenpuffer frei. Nur aufrufen, wenn garantiert kein
    /// Renderblock mehr laeuft — also nach `engine.stop()` oder bevor der Knoten
    /// ueberhaupt lief. Der Ende-Merker gehoert bewusst NICHT hierher: Er lebt bis
    /// `deinit`, weil stop() und waitUntilFinished() ihn noch lesen.
    private func cleanupBuffers() {
        scratch?.deallocate()
        scratch = nil
    }
}
#endif
