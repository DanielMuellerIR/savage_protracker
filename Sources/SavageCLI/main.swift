import Foundation
import SavageModPlayerCore

// Kopflose Kommandozeilen-Schnittstelle zum Core: lädt ein Tracker-Modul (MOD/
// S3M/XM), rendert es mit DERSELBEN DSP-Engine wie die App zu einer WAV-Datei
// und/oder gibt die geparste Struktur als Text aus. Zweck: XM-/DSP-Korrektheit
// headless prüfen (A/B gegen Referenz-Renderer wie openmpt123), ohne die GUI
// bedienen zu müssen. Gleichzeitig das Fundament des geplanten Linux-CLI-Ports.
//
// Nutzung:
//   savage-cli <datei> [--out <pfad.wav>] [--seconds N] [--rate R]
//              [--normalize] [--no-interp] [--info] [--pattern N] [--quiet]
//
// Ohne --out schreibt der Renderer neben die Eingabe (<datei>.wav). --info gibt
// nur die Modul-Struktur aus (kein Render). --normalize hebt den Pegel an (wie
// Quick Look); für rohe Vergleiche weglassen.

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
    savage-cli — headless Tracker-Modul-Renderer (MOD/S3M/XM)

    savage-cli <datei> [optionen]
      -o, --out <pfad>     WAV-Ausgabepfad (Standard: <datei>.wav)
      -s, --seconds N      Renderdauer in Sekunden (0 = ganzer Song)
      -r, --rate R         Samplerate (Standard 44100)
          --normalize      Peak-Normalisierung (wie Quick Look; sonst roh)
          --no-interp      lineare Interpolation aus
          --info           nur Modul-Struktur ausgeben (kein Render)
          --pattern N      Pattern an Order-Position N als Text ausgeben
      -q, --quiet          keine Fortschrittsausgabe

    """.utf8))
    exit(2)
}

func log(_ s: String, quiet: Bool) {
    if !quiet { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

// ---- Struktur-Ausgabe (--info) ----------------------------------------------

func noteName(_ key: Int) -> String {
    // 0-basierter Halbton-Key -> "C-4" o.ä.; -1 = leer, keyOff/keyCut markiert.
    if key == Note.keyOff { return "===" }
    if key == Note.keyCut { return "^^^" }
    guard key >= 0 else { return "..." }
    let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
    return names[key % 12] + String(key / 12)
}

func printInfo(_ mod: Mod) {
    print("Name:            \(mod.name.isEmpty ? "(leer)" : mod.name)")
    print("Format:          \(mod.format)")
    print("Kanäle:          \(mod.channelCount)")
    print("Song-Länge:      \(mod.length) Positionen")
    print("Patterns:        \(mod.patterns.count)")
    print("Order-Table:     \(mod.patternTable)")
    print("Init Speed/BPM:  \(mod.initialSpeed) Ticks/Row @ \(mod.initialTempo) BPM")
    print("Global Volume:   \(mod.initialGlobalVolume)")
    print("Lineare Freq.:   \(mod.linearFrequency)")
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
    if opts.infoOnly { exit(0) }
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
        normalize: opts.normalize
    )
} catch {
    FileHandle.standardError.write(Data("Render-Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let elapsed = Date().timeIntervalSince(started)

let outPath = opts.output ?? (inputPath + ".wav")
do {
    try wav.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("Schreib-Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// data-Chunk-Größe steht ab Byte 40 (nach 44-Byte-Header).
let audioBytes = max(0, wav.count - 44)
let renderedSeconds = Double(audioBytes) / (opts.rate * 4.0) // 16-Bit-Stereo = 4 Byte/Frame
log(String(format: "Fertig: %@ (%.1f s Audio, in %.2f s gerendert)", outPath, renderedSeconds, elapsed), quiet: opts.quiet)
print(outPath)
