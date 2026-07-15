# Linux-Port: Savage Mod Player

Stand: 2026-07-15 (Ausgangslage neu verifiziert) · Ziel: Repo läuft zusätzlich
unter Linux — zuerst als CLI-Player. Kein separates Repo: `SavageModPlayerCore`
ist der plattformübergreifende Teil, die macOS-App bleibt unverändert.

## Verhältnis zum vicious_sidplayer-Port

Der Plan vom 2026-07-05 wollte dem SID-Port folgen und dessen PCMSink-/ALSA-Code
kopieren. **Das ist überholt:** im SID-Repo liegt bis heute nur `plan.md`, kein
Portcode. Beide Ports laufen ab 2026-07-15 parallel — Daniel im SID-Repo, dieser
Plan hier. Damit entsteht die PCMSink-Abstraktion *hier zuerst* und ist die
Blaupause für den SID-Port, nicht umgekehrt. Bewusst Copy statt gemeinsames
Package; eine Extraktion erst nach Bewährung in beiden Repos.

## Ausgangslage (verifiziert 2026-07-15, Version 1.5.42)

Plattformneutral (nur Foundation): alle Parser inklusive XM, IT und
`ITSampleDecompressor`, dazu `DSPChannel`, `SequencerCore`, `ModuleModels`,
`PlaylistScanner`, `SongPositionScale`. Der XM-/IT-Zuwachs seit dem alten Plan hat
**keine** neue Plattformbindung eingeführt.

Plattformgebunden sind nur:

| Datei | Bindung | Umgang |
|---|---|---|
| `DSP/ModPlayerCoordinator.swift` | AVFoundation (28 Stellen) + Combine | aufteilen, siehe Phase 0 |
| `DSP/ModuleRenderer.swift` | AVFoundation (nur `AVAudioFormat`/`AVAudioPCMBuffer`) | Puffer ersetzen |
| `DSP/VisualizerState.swift` | Combine (`ObservableObject`) | guarden, nur App braucht es |
| 3 Testdateien | AVFoundation | entfällt mit neutralem Renderblock |

`Sources/SavageCLI/` existiert bereits (`savage-cli`, Foundation-only) und deckt
Datei laden, `--info`, `--pattern`, `--out`, `--seconds`, `--rate`, `--normalize`,
`--no-interp` und Exit-Codes ab. Phase 1 ist damit weitgehend erledigt; es fehlen
nur `--stdout` und `--list`. Der WAV-Container in `ModuleRenderer` wird bereits von
Hand geschrieben (RIFF + Int16) und ist portabel.

### Warum der alte Phase-0-Schritt nicht mehr funktioniert

Der alte Plan wollte `ModPlayerCoordinator.swift` **datei-weit** in
`#if canImport(AVFoundation)` hüllen. Das würde den Port unmöglich machen: die
Datei ist gemischt. Zeilen 8–186 enthalten plattformneutrale State-/Puffertypen
(`RealtimePlaybackState`, `RealtimeVUBuffer`, `RenderCapture`), und die statischen
Render-Helfer `createRenderBlock`, `makeRenderState`, `makeRenderChannels` liegen
bei 967–1350 — genau die, die `ModuleRenderer` und damit das CLI brauchen. Ein
Datei-Guard schaltete den Offline-Renderer auf Linux mit ab.

Der eigentliche Blocker ist die Signatur des gemeinsamen Renderblocks:

```
(UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32,
 UnsafeMutablePointer<AudioBufferList>) -> OSStatus
```

`ObjCBool`, `AudioTimeStamp`, `AudioBufferList` und `OSStatus` sind CoreAudio und
existieren unter Linux nicht. Die Verflechtung ist also tiefer als „nur WAV“.

**Der alte Ausweg ist verboten.** Der Plan bot an, den Linux-CLI-Renderpfad direkt
auf `DSPChannel`-Ebene neu zu bauen. Das erzeugte einen zweiten Renderpfad und
verletzt die AGENTS-Invariante, dass Live- und Offlinepfad nicht semantisch
auseinanderlaufen dürfen. Stattdessen: **eine** Engine, neutrale Blocksignatur,
CoreAudio nur noch im macOS-Adapter.

Günstig: `isSilence` und `timestamp` werden in **keinem** der beiden Blöcke
benutzt (`createPreviewRenderBlock` deklariert sie bereits als `_, _`). Der
neutrale Block braucht daher nur `(frameCount, left, right)`.

## Phasen

### Phase 0 — Core kompiliert und testet auf Linux (~1,5–2 PT)

Nicht 0,5 PT wie im alten Plan — der Datei-Split und die Blocksignatur sind echte
Arbeit an einem AGENTS-Hotspot.

- Neutralen Blocktyp einführen:
  `@Sendable (UInt32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void`.
  Den CoreAudio-Adapter (`UnsafeMutableAudioBufferListPointer`, `noErr`) nur im
  macOS-`AVAudioSourceNode`-Pfad behalten.
- Neutralen Renderkern aus `ModPlayerCoordinator.swift` in eine neue Datei
  `DSP/RenderEngine.swift` lösen (`enum RenderEngine`): Render-Helfer,
  `renderChannelFrame`, `maxChannels`, `itVoiceCapacity`, neutrale State-Typen.
  `ModPlayerCoordinator` behält Live-Playback und wird geguarded.
- `ModuleRenderer`: `AVAudioFormat`/`AVAudioPCMBuffer` durch einen eigenen
  Float-Stereopuffer ersetzen. Der RIFF-Writer bleibt.
- `VisualizerState` (Combine) guarden; Aufrufer sind nur App und Coordinator.
- Testaufrufe von `ModPlayerCoordinator.*` auf `RenderEngine.*` umstellen — das ist
  semantisch ohnehin richtiger und macht die drei AVFoundation-Importe überflüssig.
- Im Echtzeit-Renderblock weiterhin **keine** Allokationen, Locks oder dynamischen
  Objective-C-Aufrufe.

**Erfolgskriterien:**
1. ✅ macOS bleibt bitgleich — `savage-cli`-WAVs über den lokalen MOD-Korpus
   byteidentisch zur Baseline vor dem Umbau. Das ist das Hauptgate; der Umbau
   fasst den heißesten Audiopfad an. *Erreicht 2026-07-15: 22 Module, 46,5 MB,
   Sammelhash `a004fb2cc52e1f41432511c6ad49288e7f57a1941ed2d8dd9c06652b7ac1f4a0`
   vor und nach dem Umbau identisch.*
2. ✅ `swift test` auf macOS unverändert grün. *Erreicht: 230 Tests, 2
   übersprungen, 0 Fehler — wie die Baseline. Zusätzlich `bash build_app.sh`
   grün inklusive Appex-Signatur.*
3. ⛔ `swift build` + `swift test` grün im `swift:6.0`-Container. **Offen und
   blockiert** (siehe Rahmenbedingungen). Der Code ist AVFoundation-/Combine-frei
   außerhalb der Guards, aber das ist eine statische Prüfung, kein Compile.
   Bekannte Unbekannte für den ersten Linux-Lauf: `ObjCBool` in
   `PlaylistScanner` (existiert in swift-corelibs-foundation, unverifiziert),
   Foundation-Verhaltensunterschiede und die Swift-Version im Container (lokal
   baut 6.3.3, der Plan nennt 6.0).

### Phase 1 — CLI vervollständigen (~0,25 PT)

- ✅ `--stdout`: PCM-s16le auf stdout (→ `aplay`), Metadaten weiterhin auf stderr.
  *Umgesetzt 2026-07-15; verifiziert: Ausgabe ist byteident zum WAV-Body ohne die
  44 Header-Bytes.*
- ✅ `--list`: Ordnerscan via `PlaylistScanner.isModFile`, ein Pfad je Zeile,
  Exit 1 wenn nichts gefunden. Bewusst ohne `collectEntries` — kein Entpacken,
  kein TempDir, `--list` schreibt nichts auf die Platte.
- Name bleibt `savage-cli` (nicht `savage-mod` wie im alten Plan) — das Target
  existiert und ist in Doku und Tests verankert.
- ⛔ **Erfolgskriterium offen:** `--out`-WAV byteident zwischen macOS- und
  Linux-Build (Determinismus). Braucht denselben Linux-Zugang wie Phase 0.
- Der Linux-Abschnitt in README.md/README.de.md bleibt bewusst ungeschrieben,
  solange kein Linux-Build grün ist — sonst dokumentiert er eine unbelegte
  Fähigkeit.

### Phase 2 — Echtzeit-Playback + Steuerung (blockiert, ~1 PT)

ALSA-`systemLibrary`-Anbindung, Tastatursteuerung (Pause, nächster Titel, Quit).

**Blocker (Stand 2026-07-15):** ein interner Linux-Host ist Linux x86_64 mit
Docker, aber **ohne Swift und ohne alsa-dev**, und als Server ohne nutzbare
Audioausgabe. Das Erfolgskriterium „hörbar korrekt via aplay / Playlist ohne
Aussetzer“ ist damit weder headless noch von einem Agenten verifizierbar — es
braucht einen Linux-Host mit Audio und Daniels Ohren. Erst nach Klärung dieses
Hosts starten; Code ohne Hörtest wäre unbelegt.

### Phase 3 (optional) — Desktop-Integration

MPRIS2, .desktop-Datei, statisches Binary/AppImage. Erst bei Bedarf.

## Rahmenbedingungen

- **Linux-Verifikation ist derzeit blockiert.** Lokal (M5) gibt es weder Docker
  noch Podman noch Colima und kein installiertes Swift-SDK für Linux. Auf dem internen Host
  liegt Docker, aber der Benutzer ist nicht in der `docker`-Gruppe und `sudo`
  verlangt ein Passwort — ein Agent kann den Container dort nicht starten.
  Freischaltung (einmalig, durch Daniel) entweder per
  `sudo usermod -aG docker <user>` auf dem internen Host oder durch Installation des
  Static-Linux-SDK auf dem Mac. Bis dahin gilt jede Aussage „läuft unter Linux“
  als unbelegt, egal wie plausibel der Code aussieht.
- CI: Ubuntu-Job in `.github/workflows/ci.yml`, erst wenn lokal grün. Push von
  `.github/workflows/*` nach GitHub nur auf Auftrag.
- README.md/README.de.md: Linux-Abschnitt nach Phase 1; RELEASE_NOTES pflegen,
  `VERSION`-Bump pro Phase.
- Chirurgisch: App-, Quick-Look- und JS/HTML5-Code nicht anfassen.
- `ModPlayerCoordinator.swift` ist ein AGENTS-Hotspot — nur ein Writer.
