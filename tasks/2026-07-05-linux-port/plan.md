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
3. ✅ `swift build` + `swift test` grün im `swift:6.0`-Container. *Erreicht
   2026-07-15 auf Popo: **216 Tests, 0 Fehler, 2 übersprungen**. Die Differenz zu
   den 230 macOS-Tests sind exakt die 14 Testmethoden, die die AVAudioEngine-
   gebundene Live-Klasse instanziieren und deshalb geguardet sind.*

Der erste Linux-Lauf hat drei echte Fehler aufgedeckt, die auf macOS latent waren
— genau der Wert des Ports:

- `PlaylistScanner` rief `url.startAccessingSecurityScopedResource()`, eine reine
  Apple-Sandbox-API → jetzt hinter `#if canImport(Darwin)`.
- `MultiFormatTests` las die WAV-Chunk-Größe mit `load(as: UInt32.self)` aus
  einem `Data`-Slice, dessen Basis nicht 4-Byte-ausgerichtet sein muss. Darwin
  toleriert das, Linux bricht hart ab („misaligned raw pointer") → `loadUnaligned`.
- `extractArchive` lief komplett unter `#if os(macOS)` mit der Begründung, es gebe
  außerhalb kein `Process`/`bsdtar`. **Das war schlicht falsch:**
  swift-corelibs-foundation hat `Process`, und `bsdtar` liegt unter Linux an
  derselben Stelle. Der Guard prüft jetzt die tatsächliche Verfügbarkeit
  (`PlaylistScanner.bsdtarURL`) statt die Plattform — Archive werden damit auch
  unter Linux entpackt (im Container verifiziert). Fehlt bsdtar, überspringen die
  Tests sauber, statt rot zu melden.

Der `ObjCBool`-Verdacht aus der Vorab-Analyse war unbegründet: swift-corelibs-
foundation kennt den Typ, die Zeile kompiliert unverändert.

**Container-Anforderung:** `swift:6.0` bringt kein `bsdtar` mit. Für den vollen
Archiv-Test braucht der Lauf `apt-get install -y libarchive-tools`; ohne das
überspringen zwei Tests. Das gehört in den CI-Job.

### Phase 1 — CLI vervollständigen (~0,25 PT)

- ✅ `--stdout`: PCM-s16le auf stdout (→ `aplay`), Metadaten weiterhin auf stderr.
  *Umgesetzt 2026-07-15; verifiziert: Ausgabe ist byteident zum WAV-Body ohne die
  44 Header-Bytes.*
- ✅ `--list`: Ordnerscan via `PlaylistScanner.isModFile`, ein Pfad je Zeile,
  Exit 1 wenn nichts gefunden. Bewusst ohne `collectEntries` — kein Entpacken,
  kein TempDir, `--list` schreibt nichts auf die Platte.
- Name bleibt `savage-cli` (nicht `savage-mod` wie im alten Plan) — das Target
  existiert und ist in Doku und Tests verankert.
- ✅ **Erfolgskriterium erreicht — aber in korrigierter Form.** Das alte
  Kriterium „`--out`-WAV byteident zwischen macOS- und Linux-Build" ist
  **prinzipiell unerfüllbar** und wurde ersetzt.

  Gemessen 2026-07-15 (identisches MOD, 12 s, Debug-Build beidseitig): Dateigröße
  gleich, **90 von 1.058.400 Samples (0,0085 %) weichen um exakt 1 LSB ab**, nie
  mehr. RMS-Fehler 0,0092 LSB — rund 115 dB unter dem Signal, also weit unterhalb
  jeder Hörschwelle und unterhalb des 16-Bit-Quantisierungsrauschens.

  Ursache belegt, nicht vermutet: `tanh` (Soft-Limiter im Renderblock) rundet in
  glibc und Darwin-libm unterschiedlich. Direkt gemessen mit identischem
  Swift-Code auf beiden Plattformen:

  | | `tanh(0.938268)` | Bitmuster |
  |---|---|---|
  | macOS/arm64 | `0.7344255` | `1060897615` |
  | Linux/x86_64 | `0.73442554` | `1060897616` |

  Beide Ergebnisse sind innerhalb 1 ULP korrekt — die Plattformen sind sich nur
  über das letzte Bit uneins. Byteidentität wäre nur über eine eigene
  tanh-Implementierung erreichbar; das würde den macOS-Klang (minimal) ändern,
  ohne hörbaren Gewinn, und ist deshalb **abgelehnt**.

  **Neues Kriterium:** gleiche Länge, maximale Sample-Abweichung ≤ 1 LSB,
  Fehler-RMS < 0,1 LSB. Für Regressionen innerhalb *einer* Plattform bleibt
  Byteidentität das Gate (macOS: erfüllt, siehe Phase 0).

### Phase 2 — Echtzeit-Playback (✅ Kern erledigt 2026-07-15)

Die Sink-Schicht **kam doch aus dem SID-Port** — Daniel hat sie am 2026-07-15
gebaut, damit war die ursprüngliche Reihenfolge des Plans (SID zuerst, savage
guckt ab) am Ende doch die richtige. Übernommen aus
`vicious_sidplayer/Sources/`, bewusst als Kopie:

- `Audio/PCMSink.swift` — Vertrag (Pull-Modell, interleaved Float, Sendable).
- `Audio/PCMSinkFactory.swift` — einzige Plattformweiche.
- `Audio/ALSAPCMSink.swift`, `Audio/AVAudioEnginePCMSink.swift`,
  `Audio/StdoutPCMSink.swift` — die drei Ausgaben.
- `Sources/CALSA/` — Systemmodul-Brücke zu libasound.

Der Code ist frei von Format-Wissen und ließ sich unverändert übernehmen; nur die
Kommentare zeigten auf SID-Interna und wurden auf den savage-Kontext umgeschrieben.
Eine Extraktion in ein gemeinsames Paket lohnt erst, wenn sich die Schicht in
beiden Repos bewährt hat — bis dahin: Änderungen hier und dort im Blick behalten.

Eigenanteil ist `Audio/ModulePCMSource.swift`: die Brücke vom `ModuleRenderBlock`
(getrennte L/R-Puffer, kein Endesignal) zum `PCMRenderBlock` (interleaved, Rückgabe
= gefüllte Frames). Voralloziierte Chunk-Puffer, damit der Audio-Thread nicht
alloziert; Songende über `endReachedFrame` als kurze Lieferung.

**Verifiziert:**

- `savage-cli --play` spielt auf macOS (AVAudioEngine) und Linux (ALSA).
- Linux-Laufzeit lautlos geprüft, ohne Popos Desktop zu beschallen: `.asoundrc`
  mit `pcm.!default { type null }` biegt `default` auf ALSAs null-Plugin um —
  echter `snd_pcm_open`/`writei`/`drain`-Pfad, Ergebnis `sourceFinished`, Exit 0.
- `ModulePCMSourceTests`: der Echtzeitpfad liefert **sample-identisch** dasselbe
  wie `ModuleRenderer` (Offline), trotz unterschiedlicher Blockgrößen (1024 vs.
  4096) — die „eine Engine"-Invariante ist damit testgedeckt, nicht nur behauptet.
  Zweiter Test: Songende kommt als kurze Lieferung an, sonst hinge der Sink.

**Noch offen aus Phase 2:** Tastatursteuerung (Pause, nächster Titel, Quit) und
Playlist-Wiedergabe über `--list`. Ebenfalls offen: eine Aufnahme über die echte
PipeWire-Kette per `parec` als Dropout-Nachweis unter Last — das null-Device sagt
nichts über Aussetzer auf echter Hardware.

### Phase 3 (optional) — Desktop-Integration

MPRIS2, .desktop-Datei, statisches Binary/AppImage. Erst bei Bedarf.

## Rahmenbedingungen

- **Linux-Verifikation läuft** (seit 2026-07-15 freigeschaltet). Lokal (M5) gibt
  es weder Docker noch Podman noch ein Linux-SDK; verifiziert wird auf dem
  Fleet-Linux-Host im `swift:6.0`-Container:

  ```bash
  tar czf port.tgz Package.swift Sources Tests   # audio/ und .build bleiben draussen
  scp port.tgz <host>:~/savage-linux-check/
  ssh <host> 'cd ~/savage-linux-check && tar xzf port.tgz && \
    docker run --rm -v "$PWD":/src -w /src swift:6.0 bash -c \
    "apt-get update -qq && apt-get install -y -qq libarchive-tools; swift build && swift test"'
  ```

  Der Host ist zugleich Backup-Host — Testlast moderat halten (ein Build/Testlauf
  am Stück, keine Dauerschleifen). Host-Details und die Etikette für GUI-/Audio-
  Zugriffe stehen in der privaten Fleet-Doku, nicht hier.
- CI: Ubuntu-Job in `.github/workflows/ci.yml`, erst wenn lokal grün. Push von
  `.github/workflows/*` nach GitHub nur auf Auftrag.
- README.md/README.de.md: Linux-Abschnitt nach Phase 1; RELEASE_NOTES pflegen,
  `VERSION`-Bump pro Phase.
- Chirurgisch: App-, Quick-Look- und JS/HTML5-Code nicht anfassen.
- `ModPlayerCoordinator.swift` ist ein AGENTS-Hotspot — nur ein Writer.
