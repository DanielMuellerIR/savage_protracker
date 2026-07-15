import Foundation
import SavageModPlayerCore

// Kopflose Kommandozeilen-Schnittstelle zum Core: lädt ein Tracker-Modul (MOD/
// S3M/XM/IT), rendert es mit DERSELBEN DSP-Engine wie die App zu einer WAV-Datei
// und/oder gibt die geparste Struktur als Text aus. Zweck: XM-/DSP-Korrektheit
// headless prüfen (A/B gegen Referenz-Renderer wie openmpt123), ohne die GUI
// bedienen zu müssen. Gleichzeitig das Fundament des geplanten Linux-CLI-Ports.
//
// Nutzung:
//   savage-cli <datei> [--out <pfad.wav>] [--seconds N] [--rate R]
//              [--normalize] [--no-interp] [--info] [--pattern N] [--quiet]
//              [--stdout] [--list <ordner>]
//
// Ohne --out schreibt der Renderer neben die Eingabe (<datei>.wav). --info gibt
// nur die Modul-Struktur aus (kein Render). --normalize hebt den Pegel an (wie
// Quick Look); für rohe Vergleiche weglassen. --stdout schreibt rohes PCM nach
// stdout (Pipe-Wiedergabe, z.B. `savage-cli x.mod --stdout | aplay ...`).
// --list scannt einen Ordner und listet die spielbaren Module.

struct Options {
    var input: String?
    var output: String?
    var seconds: Double = 0        // 0 = ganzer Song (bis endReached, Kappung 600 s)
    var rate: Double = 44100
    var normalize = false
    var interpolation = true
    var infoOnly = false
    var dumpPattern: Int?          // Order-Index, dessen Pattern als Text ausgegeben wird
    var quiet = false
    var toStdout = false           // rohes PCM-s16le nach stdout statt in eine WAV-Datei
    var listDir: String?           // Ordner rekursiv nach spielbaren Modulen durchsuchen
    var play = false               // Echtzeit-Wiedergabe ueber die Audio-Ausgabe der Plattform
}

func parseArgs(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--out", "-o":      i += 1; o.output = i < argv.count ? argv[i] : nil
        case "--seconds", "-s":  i += 1; o.seconds = Double(i < argv.count ? argv[i] : "0") ?? 0
        case "--rate", "-r":     i += 1; o.rate = Double(i < argv.count ? argv[i] : "44100") ?? 44100
        case "--normalize":      o.normalize = true
        case "--no-interp":      o.interpolation = false
        case "--info":           o.infoOnly = true
        case "--pattern":        i += 1; o.dumpPattern = Int(i < argv.count ? argv[i] : "")
        case "--quiet", "-q":    o.quiet = true
        case "--stdout":         o.toStdout = true
        case "--play":           o.play = true
        case "--list":           i += 1; o.listDir = i < argv.count ? argv[i] : nil
        case "--help", "-h":     printUsageAndExit()
        default:
            if o.input == nil { o.input = a }
        }
        i += 1
    }
    return o
}

func printUsageAndExit() -> Never {
    FileHandle.standardError.write(Data("""
    savage-cli — headless Tracker-Modul-Renderer (MOD/S3M/XM/IT)

    savage-cli <datei> [optionen]
      -o, --out <pfad>     WAV-Ausgabepfad (Standard: <datei>.wav)
      -s, --seconds N      Renderdauer in Sekunden (0 = ganzer Song)
      -r, --rate R         Samplerate (Standard 44100)
          --normalize      Peak-Normalisierung (wie Quick Look; sonst roh)
          --no-interp      lineare Interpolation aus
          --info           nur Modul-Struktur ausgeben (IT intern analysierbar)
          --pattern N      Pattern an Order-Position N als Text ausgeben
      -q, --quiet          keine Fortschrittsausgabe
          --stdout         rohes PCM (s16le, stereo) nach stdout statt in eine Datei
          --list <ordner>  Ordner rekursiv nach spielbaren Modulen durchsuchen
          --play           Echtzeit-Wiedergabe (macOS: AVAudioEngine, Linux: ALSA)

    Beispiel (Linux):
      savage-cli song.mod --stdout | aplay -f S16_LE -c2 -r44100

    """.utf8))
    exit(2)
}

func log(_ s: String, quiet: Bool) {
    if !quiet { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

// ---- Struktur-Ausgabe (--info) ----------------------------------------------

func noteName(_ key: Int) -> String {
    // 0-basierter Halbton-Key -> "C-4" o.ä.; Spezialnoten separat markieren.
    if key == Note.keyOff { return "===" }
    if key == Note.keyCut { return "^^^" }
    if key == Note.keyFade { return "~~~" }
    guard key >= 0 else { return "..." }
    let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
    return names[key % 12] + String(key / 12)
}

func printInfo(_ mod: Mod) {
    print("Name:            \(mod.name.isEmpty ? "(leer)" : mod.name)")
    print("Format:          \(mod.format)")
    print("Kanäle:          \(mod.usedChannelCount) genutzt, \(mod.displayChannelCount) sichtbar, \(mod.channelCount) technisch")
    print("Song-Länge:      \(mod.length) Positionen")
    print("Patterns:        \(mod.patterns.count)")
    print("Order-Table:     \(mod.patternTable)")
    print("Init Speed/BPM:  \(mod.initialSpeed) Ticks/Row @ \(mod.initialTempo) BPM")
    print("Global Volume:   \(mod.initialGlobalVolume)")
    print("Lineare Freq.:   \(mod.linearFrequency)")
    if mod.format == .it {
        printITInfo(mod)
        return
    }
    let realInstruments = mod.instruments.compactMap { $0 }
    print("Instrumente:     \(realInstruments.count)")
    for inst in realInstruments {
        let env = inst.volumeEnvelope
        let envDesc: String
        if let e = env {
            let pts = e.points.map { "(\($0.frame),\($0.value))" }.joined(separator: " ")
            envDesc = "volEnv[sus=\(e.sustainEnabled ? String(e.sustainPoint) : "-"),loop=\(e.loopEnabled ? "\(e.loopStart)..\(e.loopEnd)" : "-")]: \(pts)"
        } else {
            envDesc = "volEnv=none"
        }
        let av = inst.autoVibrato.map { "autoVib[t\($0.type) d\($0.depth) r\($0.rate) sw\($0.sweep)]" } ?? "autoVib=none"
        print(String(format: "  #%02d '%@'  samples=%d fadeout=%d  %@  %@",
                     inst.index, inst.name, inst.samples.count, inst.fadeout, envDesc, av))
        for (si, s) in inst.samples.enumerated() {
            let loop = s.loopType == .none ? "none" : "\(s.loopType)[\(s.loopStart)..\(s.loopStart + s.loopLength)]"
            print(String(format: "      s%d '%@' len=%d vol=%d ft=%d rel=%d pan=%.2f loop=%@",
                         si, s.name, s.pcm.count, s.volume, s.finetune, s.relativeNote, s.panning, loop))
        }
        if !inst.keymap.isEmpty {
            // Nur ausgeben, wenn nicht trivial (alles Sample 0).
            let distinct = Set(inst.keymap)
            if distinct.count > 1 {
                print("      keymap: \(inst.keymap.map { String($0) }.joined(separator: ""))")
            }
        }
    }
}

func envelopeDescription(_ label: String, _ envelope: Envelope?) -> String {
    guard let envelope else { return "\(label)=none" }
    let points = envelope.points.map { "(\($0.frame),\($0.value))" }.joined(separator: " ")
    let sustain = envelope.sustainEnabled
        ? "\(envelope.sustainStart)..\(envelope.sustainEnd)"
        : "-"
    let loop = envelope.loopEnabled ? "\(envelope.loopStart)..\(envelope.loopEnd)" : "-"
    return "\(label)[mode=\(envelope.valueMode.rawValue),sus=\(sustain),loop=\(loop),carry=\(envelope.carryEnabled)]: \(points)"
}

func printITInfo(_ mod: Mod) {
    if let properties = mod.itProperties {
        if let identity = properties.trackerIdentity {
            print("Tracker:          \(identity.displayName)")
        }
        print(String(
            format: "IT-Versionen:    cwtv=0x%04X (Ersteller), cmwt=0x%04X (benoetigte IT-Semantik)",
            properties.createdWithVersion,
            properties.compatibleWithVersion
        ))
        print("IT-Modus:         \(properties.usesInstruments ? "Instrument" : "Sample")")
        print("IT-Mix/PanSep:    \(properties.mixVolume) / \(properties.panSeparation)")
        if case let .impulseTracker(compatibility)? = mod.playbackSemantics {
            print("IT-Flags:         oldFx=\(compatibility.oldEffects) compatGxx=\(compatibility.compatibleGxx)")
        }
        if let extensions = properties.openMPTExtensions {
            let created = extensions.createdWithVersion?.displayName ?? "-"
            let saved = extensions.lastSavedWithVersion?.displayName ?? "-"
            print("OpenMPT-Version:  erstellt \(created), zuletzt gespeichert \(saved)")
            print("OpenMPT-Timing:   \(tempoModeName(extensions.tempoMode)), Rows/Beat \(extensions.rowsPerBeat.map(String.init) ?? "Header/4"), Rows/Takt \(extensions.rowsPerMeasure.map(String.init) ?? "Header/16")")
            print("OpenMPT-Mix:      Level \(extensions.rawMixLevel.map(String.init) ?? "Header"), Sample-/Synth-Preamp \(extensions.samplePreamp.map(String.init) ?? "Header")/\(extensions.synthPreamp.map(String.init) ?? "-")")
            print("Erweiterungen:    \(extensions.chunks.count) strukturierte Chunks")
            for chunk in extensions.chunks {
                print("  \(chunk.context.rawValue).\(chunk.id) [\(chunk.classification.rawValue), \(chunk.size) B]: \(chunk.summary)")
            }
            if !extensions.playBehaviours.isEmpty {
                let flags = extensions.playBehaviours.map {
                    "\($0.bit):\($0.behaviour?.displayName ?? "unbekannt")"
                }.joined(separator: ", ")
                print("MSF.-Bits:        \(flags)")
            }
        }
        if let findings = properties.capabilityReport?.findings.filter({ $0.detected }) {
            print("Capabilities:     \(findings.count) erkannte Merkmale")
            for finding in findings {
                let use = finding.used ? "verwendet" : "nicht verwendet"
                print("  \(finding.identifier): \(capabilitySupportName(finding.support)), \(use) — \(finding.detail)")
            }
        }
    }
    if !mod.compatibilityWarnings.isEmpty {
        print("Einschränkungen:")
        for warning in mod.compatibilityWarnings { print("  WARNUNG: \(warning)") }
    } else {
        print("Einschränkungen:  keine hörbar relevanten")
    }

    let instruments = mod.instruments.compactMap { $0 }
    print("Instrumente:     \(instruments.count)")
    for instrument in instruments {
        if let properties = instrument.itProperties {
            let pan = properties.defaultPanning.map(String.init) ?? "sample/channel"
            print(String(
                format: "  #%02d '%@' NNA=%d DCT=%d DCA=%d fade=%d gv=%d pan=%@ pps=%d/center%d",
                instrument.index, instrument.name,
                properties.newNoteAction.rawValue,
                properties.duplicateCheckType.rawValue,
                properties.duplicateCheckAction.rawValue,
                instrument.fadeout,
                properties.globalVolume,
                pan,
                properties.pitchPanSeparation,
                properties.pitchPanCenter
            ))
            let cutoff = properties.initialFilterCutoff.map(String.init) ?? "-"
            let resonance = properties.initialFilterResonance.map(String.init) ?? "-"
            print("      swing vol/pan=\(properties.randomVolumeVariation)/\(properties.randomPanningVariation) filter=\(cutoff)/\(resonance)")
            if properties.midiChannel > 0 {
                print("      MIDI-Kanal/Programm/Bank=\(properties.midiChannel)/\(properties.midiProgram)/\(properties.midiBank) (nicht wiedergegeben)")
            }
        } else {
            print(String(format: "  #%02d '%@' fade=%d", instrument.index, instrument.name, instrument.fadeout))
        }
        print("      \(envelopeDescription("volEnv", instrument.volumeEnvelope))")
        print("      \(envelopeDescription("panEnv", instrument.panningEnvelope))")
        print("      \(envelopeDescription("pitchEnv", instrument.pitchEnvelope))")
        if let mapping = instrument.noteSampleMapping {
            let empty = mapping.entries.count { $0.sampleID == 0 }
            let transposed = mapping.entries.enumerated().count { $0.offset != $0.element.targetNote }
            let sampleIDs = Set(mapping.entries.map(\.sampleID).filter { $0 > 0 }).sorted()
            print("      notemap entries=120 samples=\(sampleIDs) empty=\(empty) transposed=\(transposed)")
            let exceptions = mapping.entries.enumerated().compactMap { source, entry -> String? in
                guard entry.sampleID == 0 || entry.targetNote != source else { return nil }
                return "\(noteName(source))->\(noteName(entry.targetNote))/S\(entry.sampleID)"
            }
            if !exceptions.isEmpty { print("      notemap exceptions: \(exceptions.joined(separator: " "))") }
        }
    }

    let samples = mod.samplePool.enumerated().compactMap { index, sample in
        sample.map { (index, $0) }
    }
    print("Samples:         \(samples.count)")
    for (index, sample) in samples {
        let loop = sample.loopType == .none
            ? "none"
            : "\(sample.loopType)[\(sample.loopStart)..\(sample.loopStart + sample.loopLength)]"
        let sustain = sample.sustainLoop.map {
            "\($0.type)[\($0.start)..\($0.start + $0.length)]"
        } ?? "none"
        let properties = sample.itProperties
        print(String(
            format: "  S%02d '%@' len=%d vol=%d gv=%d c5=%d pan=%@ loop=%@ sustain=%@ stereo=%@",
            index, sample.name, sample.pcm.count, sample.volume,
            properties?.globalVolume ?? 64,
            properties?.c5Speed ?? sample.c2spd,
            properties?.defaultPanning.map(String.init) ?? "-",
            loop,
            sustain,
            sample.rightPCM == nil ? "no" : "yes"
        ))
    }
}

func tempoModeName(_ mode: ITTempoMode) -> String {
    switch mode {
    case .classic: return "klassisch"
    case .alternative: return "alternativ"
    case .modern: return "modern"
    }
}

func capabilitySupportName(_ support: ITCapabilitySupport) -> String {
    switch support {
    case .supported: return "unterstützt"
    case .irrelevantForPCM: return "für PCM-IT irrelevant"
    case .metadataOnly: return "nur Metadaten"
    case .midiOrPluginOnly: return "nur MIDI/Plugin"
    case .unsupported: return "nicht unterstützt"
    case .differentPlayback: return "abweichende Wiedergabe"
    }
}

func dumpPattern(_ mod: Mod, orderIndex: Int) {
    guard orderIndex >= 0, orderIndex < mod.patternTable.count else {
        print("Order-Index \(orderIndex) außerhalb 0..\(mod.patternTable.count - 1)")
        return
    }
    let patIdx = mod.patternTable[orderIndex]
    guard patIdx >= 0, patIdx < mod.patterns.count else { print("Pattern-Index ungültig"); return }
    let pat = mod.patterns[patIdx]
    print("--- Order \(orderIndex) -> Pattern \(patIdx) (\(pat.rows.count) Zeilen, \(mod.channelCount) Kanäle) ---")
    for (r, row) in pat.rows.enumerated() {
        var cells: [String] = []
        for ch in 0..<min(mod.channelCount, row.notes.count) {
            let n = row.notes[ch]
            // Note: bei XM key-basiert, bei MOD period-basiert.
            let nn: String
            if n.key >= 0 || n.key == Note.keyOff || n.key == Note.keyCut { nn = noteName(n.key) }
            else if n.period > 0 { nn = String(format: "p%03d", Int(n.period)) }
            else { nn = "..." }
            let inst = n.instrument > 0 ? String(format: "%02d", n.instrument) : ".."
            let vol = n.volCmd > 0 ? String(format: "%02X", n.volCmd) : ".."
            let fx = n.hasEffect ? String(format: "%02X%02X", n.effectId & 0xFF, n.effectData & 0xFF) : "...."
            cells.append("\(nn) \(inst) \(vol) \(fx)")
        }
        print(String(format: "%02d| %@", r, cells.joined(separator: " | ")))
    }
}

// ---- Hauptprogramm ----------------------------------------------------------

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

// --list: Ordner scannen und spielbare Module ausgeben (ein Pfad je Zeile, damit
// die Ausgabe pipe-/skriptfreundlich bleibt). Braucht keine Eingabedatei.
if let listDir = opts.listDir {
    let dirURL = URL(fileURLWithPath: listDir)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
        FileHandle.standardError.write(Data("Fehler: Kein Ordner: \(listDir)\n".utf8))
        exit(1)
    }
    // Direkt enumerieren statt collectEntries: kein Entpacken, kein TempDir —
    // --list soll nur zeigen, was da ist, und nichts auf die Platte schreiben.
    guard let enumerator = FileManager.default.enumerator(
        at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else {
        FileHandle.standardError.write(Data("Fehler: Ordner nicht lesbar: \(listDir)\n".utf8))
        exit(1)
    }
    var count = 0
    var paths: [String] = []
    while let fileURL = enumerator.nextObject() as? URL {
        if PlaylistScanner.isModFile(fileURL) {
            paths.append(fileURL.path)
            count += 1
        }
    }
    for path in paths.sorted() { print(path) }
    log("\(count) spielbare Module in \(listDir)", quiet: opts.quiet)
    exit(count > 0 ? 0 : 1)
}

guard let inputPath = opts.input else { printUsageAndExit() }

let inputURL = URL(fileURLWithPath: inputPath)
guard let data = try? Data(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("Fehler: Datei nicht lesbar: \(inputPath)\n".utf8))
    exit(1)
}

let mod: Mod
do {
    mod = try ModuleLoader.parse(data: data)
} catch {
    FileHandle.standardError.write(Data("Parse-Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}

if opts.infoOnly || opts.dumpPattern != nil {
    printInfo(mod)
    if let p = opts.dumpPattern { print(""); dumpPattern(mod, orderIndex: p) }
    exit(0)
}

// --play: Echtzeit-Wiedergabe ueber die Audio-Ausgabe der Plattform. Laeuft ueber
// dieselbe Engine wie Offline-Render und App — nur die Ausgabe ist eine andere
// (AVAudioEngine auf macOS, ALSA auf Linux). Blockiert bis Songende oder Ctrl-C.
if opts.play {
    let format = PCMSinkFactory.preferredFormat(channels: 2)
    let source = ModulePCMSource(mod: mod, format: format)
    let sink = PCMSinkFactory.makeDefault(format: format)
    log(
        "Spiele '\(mod.name.isEmpty ? inputURL.lastPathComponent : mod.name)' "
        + "(\(mod.format), \(mod.channelCount) ch) @ \(Int(format.sampleRate)) Hz … Ctrl-C beendet.",
        quiet: opts.quiet
    )
    do {
        try sink.start(render: source.renderBlock())
    } catch {
        FileHandle.standardError.write(Data("Wiedergabe-Fehler: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    let reason = sink.waitUntilFinished()
    switch reason {
    case .sourceFinished, .stopped, .outputClosed:
        log("Wiedergabe beendet (\(reason)).", quiet: opts.quiet)
        exit(0)
    case .failed(let detail):
        FileHandle.standardError.write(Data("Wiedergabe abgebrochen: \(detail)\n".utf8))
        exit(1)
    case .notStarted:
        FileHandle.standardError.write(Data("Wiedergabe startete nicht.\n".utf8))
        exit(1)
    }
}

let maxDuration = opts.seconds > 0 ? opts.seconds : 600.0
log("Rendere '\(mod.name.isEmpty ? inputURL.lastPathComponent : mod.name)' (\(mod.format), \(mod.channelCount) ch) …", quiet: opts.quiet)

let started = Date()
let wav: Data
do {
    wav = try ModuleRenderer.renderWavData(
        mod: mod,
        sampleRate: opts.rate,
        maxDurationSeconds: maxDuration,
        normalize: opts.normalize,
        useInterpolation: opts.interpolation
    )
} catch {
    FileHandle.standardError.write(Data("Render-Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let elapsed = Date().timeIntervalSince(started)

// data-Chunk-Größe steht ab Byte 40 (nach 44-Byte-Header).
let audioBytes = max(0, wav.count - 44)
let renderedSeconds = Double(audioBytes) / (opts.rate * 4.0) // 16-Bit-Stereo = 4 Byte/Frame

// --stdout: nur die PCM-Nutzdaten ohne RIFF-Header, damit die Ausgabe direkt in
// einen Player gepiped werden kann (aplay & Co. erwarten rohes s16le). Die
// Statusmeldung geht wie gehabt auf stderr und verschmutzt den Stream nicht.
if opts.toStdout {
    FileHandle.standardOutput.write(wav.dropFirst(44))
    log(String(format: "Fertig: %.1f s Audio nach stdout (in %.2f s gerendert)", renderedSeconds, elapsed), quiet: opts.quiet)
    exit(0)
}

let outPath = opts.output ?? (inputPath + ".wav")
do {
    try wav.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("Schreib-Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}

log(String(format: "Fertig: %@ (%.1f s Audio, in %.2f s gerendert)", outPath, renderedSeconds, elapsed), quiet: opts.quiet)
print(outPath)
