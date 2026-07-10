# AGENTS.md — Savage Mod Player

Diese Datei ist die zentrale Projektdokumentation. Sie beschreibt die Architektur, Konventionen und offene Todos für den **Savage Mod Player**.

---

## Typ & Zweck
- **Typ:** GUI-App
- **Zweck:** Nativer Amiga/Tracker-Modul-Player (ProTracker/S3M) mit SwiftUI, AVAudioEngine und Quick-Look-Plugin; plus HTML5-Variante.
- **Plattform:** macOS-GUI, iOS

## Datei-Verzeichnis

| Datei | Wozu |
|---|---|
| [README.md](README.md) | Englische Projektübersicht: Features, Bedienung, Build-Hinweise für HTML5- und Swift-Variante. |
| [README.de.md](README.de.md) | Deutsche Übersetzung der Projektübersicht. |
| [AGENTS.md](AGENTS.md) | Zentrale Doku für AI-Agenten: Architektur, Konventionen, Todos, Fallen. |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | Englische Versionsnotizen (Umbenennung Savage Protracker Player → Savage Mod Player). |
| [RELEASE_NOTES.de.md](RELEASE_NOTES.de.md) | Deutsche Übersetzung der Versionsnotizen. |
| [tasks/2026-07-05-linux-port/plan.md](tasks/2026-07-05-linux-port/plan.md) | Plan für den Linux-Port: CLI-Player auf Basis von `SavageModPlayerCore`. |
| [tasks/2026-07-10-it-support/plan.md](tasks/2026-07-10-it-support/plan.md) | Verbindlicher Meilenstein- und Orchestrierungsplan für Impulse-Tracker-Unterstützung (`.it`). |

---

## Projektüberblick

Der **Savage Mod Player** ist ein plattformübergreifender Amiga-/Tracker-Modul-Player. Er ist als direktes Gegenstück zum **Vicious SID Player** konzipiert und besteht aus zwei Implementierungen:
1. **HTML5-Variante**: Ein kompakter (unter 40 KB minifizierter) Single-File-Browser-Player (`savage-mod-player.html`), der ohne Webserver direkt aus dem Dateisystem per Doppelklick gestartet werden kann. Bewusst auf klassische 4-Kanal-ProTracker-MODs beschränkt (Kompaktheit).
2. **Swift-Variante**: Eine native, hochperformante macOS- & iOS-Anwendung (`Savage Mod Player.app`), implementiert in SwiftUI und `AVAudioEngine`/`AVAudioSourceNode` für eine ressourcenschonende und latenzfreie Wiedergabe.

### Unterstützte Formate (Stand 1.3.0)

| Format | HTML5 | Swift + Quick Look |
|---|---|---|
| ProTracker MOD (M.K., M!K!, FLT4, 4CHN) | ✅ | ✅ |
| Multichannel-MOD (xCHN 2-9, xxCH 10-32, CD81/OKTA/OCTA, FLT8-Pattern-Paare) | ❌ | ✅ |
| Ur-Soundtracker (15 Instrumente, ohne Signatur, per Struktur-Heuristik) | ❌ | ✅ |
| ScreamTracker 3 (S3M, bis 32 PCM-Kanäle) | ❌ | ✅ |
| FastTracker II (XM, Multi-Sample-Instrumente, Hüllkurven) | ❌ | ✅ |

Format-Dispatch am Dateiinhalt: `ModuleLoader.parse(data:)` (`"Extended Module: "` → `XMParser`, SCRM-Header → `S3MParser`, sonst `ModParser`).

**S3M — bewusste Vereinfachungen** (nur exotische Module betroffen): AdLib-Instrumente stumm, Stereo-Samples nur linker Kanal, 16-Bit-Samples auf 8 Bit reduziert (High-Byte), Qxy ohne Volume-Modifier, kein Tempo-Slide (Txx mit x<2), keine ST3.00-„Fast Volume Slides".

### Quick-Look-Plugin

`quicklook/PreviewProvider.swift` + Appex-Bau in `build_app.sh` (swiftc kompiliert Core-Quellen + Provider zu EINEM Modul, Linker-Entry `_NSExtensionMain`; SwiftPM kann keine .appex bauen). Datenbasierte Preview (`QLIsDataBasedPreview`): Modul wird via `ModuleRenderer.renderWavData` offline zu WAV gerendert, Quick Look zeigt den nativen macOS-Audio-Player (Play/Scrubbing im Finder per Leertaste). Der Appex MUSS sandboxed signiert werden (Entitlements in `quicklook/`, Signier-Reihenfolge: erst Appex MIT Entitlements, dann App OHNE `--deep`). Die App-Info.plist deklariert UTIs für .mod/.s3m; zusätzlich claimt der Appex `org.videolan.mod`/`org.videolan.s3m`, weil VLCs exportierte UTIs sonst gewinnen.

---

## Synchronisierungsregel für Fehlerbehebungen (Fixes)

Da beide Player dieselbe mathematische Logik für Wiedergabe und Synthese teilen, gilt für alle Entwickler und KI-Coding-Agents folgende Regel:
> [!IMPORTANT]
> **Gegenseitige Fehlerprüfung:**
> Sobald ein Fehler (z. B. DSP-Ungenauigkeit, Filter-Problem, Hüllkurven-Bug) in einer Variante (z. B. HTML5) behoben wird, muss automatisch ein Todo für die andere Variante (z. B. Swift) in dieser `AGENTS.md` angelegt werden. Die Fehlerbehebung muss dort ebenfalls geprüft und gegebenenfalls implementiert werden, um mathematische Konsistenz zwischen den Plattformen zu wahren.

---

## Dateilayout

```
p_savage_modplayer/
├── savage-mod-player.html  ← Fertig gebauter Single-File-Browserplayer
├── modplayer.js                   ← Mod-Parser & Player-Schnittstelle (Quelle)
├── mod-player-worklet.js          ← AudioWorklet DSP-Synthesizer (Quelle)
├── src/                           ← Assets für Web & DMG
│   ├── app.js                     ← Web-Applikationslogik
│   ├── body.html                  ← Web-HTML-Markup
│   ├── styles.css                 ← Web-Styling
│   ├── AppIcon.png                ← Master-App-Icon (1024x1024)
│   └── DmgBackground.png          ← DMG-Installationshintergrund (1200x1200)
├── Package.swift                  ← Swift Package Manager Manifest
├── Sources/                       ← Native Swift App & Core (SwiftUI)
│   ├── SavageModPlayerApp/ ← SwiftUI Main View & UI-Komponenten
│   ├── SavageModPlayerCore/← AVAudioEngine, Parser & DSP-Engine
│   └── SavageCLI/                 ← headless Render-CLI (Produkt `savage-cli`, Tests/Linux-Port)
├── Tests/                         ← XCTest Unittests
├── build.py                       ← Bündelt & minifiziert savage-mod-player.html
├── build_app.sh                   ← Kompiliert die native macOS App
├── build_dmg.sh                   ← Erzeugt das releasefähige DMG mit Hintergrundbild
├── publish_github.sh              ← Pusht Code und optional das DMG-Release nach GitHub
├── README.md                      ← Detaillierte deutsche README
├── AGENTS.md                      ← Diese Datei
├── VERSION                        ← Globale Versionsnummer
├── LICENSE                        ← MIT-Lizenz
└── .gitignore                     ← Git-Ignore-Regeln
```

---

## Architektur

### 1. HTML5-Variante
- **Mod-Parser (`modplayer.js`)**: Liest den binären MOD-Datenstrom (1084+ Bytes) ein und extrahiert Instrumente, Patterns und Song-Playlists.
- **AudioWorklet-Mixer (`mod-player-worklet.js`)**: Läuft in einem separaten Audio-Worker-Thread. Führt 4-Kanal-Mischung bei 44,1 kHz mit Paula-Clock-Geschwindigkeit (`3.546.894,6 Hz`) und allen Standard-Effekten (Arpeggio, Slides, Loop, Vibrato, Tremolo) aus.
- **UI (`src/`)**: Vanilla JS und CSS, orientiert am Amiga-Workbench-1.3-Look und einem modernen "Cyber Charcoal"-Farbschema.

### 2. Swift-Variante
- **Parser (`SavageModPlayerCore/Parser/`)**: Reines Swift, parst `.mod`-Varianten (`ModParser`) und `.s3m` (`S3MParser`) in typsichere Werttypen (`struct`); Einstieg ist `ModuleLoader`. S3M-Noten liegen als Halbton-Keys (`Note.key`) vor, S3M-Effekte werden auf ProTracker-IDs bzw. `ModuleEffect.*`-IDs (>= 0x100) übersetzt.
- **DSP / Synthesizer (`SavageModPlayerCore/DSP/`)**: Verwendet `AVAudioSourceNode` innerhalb von `AVAudioEngine`. Läuft direkt auf dem Core Audio Echtzeit-Thread. Kanalzahl dynamisch (bis 32, vorallozierte Puffer); Frequenzmodell pro Modul: Amiga-Paula-Perioden (MOD) oder ST3-Perioden mit C2Spd + 14,3-MHz-Clock (`DSPChannel.s3mMode`).
  - *Wichtig*: Keine Heap-Alloziierungen, Sperren oder dynamische Objective-C-Aufrufe im Render-Block!
- **Offline-Renderer (`ModuleRenderer`)**: rendert Module mit demselben Render-Block zu WAV-Daten (Quick Look, Tests).
- **UI (`SavageModPlayerApp/UI/`)**: Deklaratives SwiftUI. Enthält zentrierende Tracker-Zeilen-Tabellen (dynamische Spaltenzahl, horizontales Scrollen ab 5 Kanälen), Visualizer und CRT-Effekt-Filter.

---

## Aktuelle Todos (Release 1.2.33)

- [x] **Todo 1**: Git-Repository initialisieren & Stammdateien anlegen (`VERSION`, `LICENSE`, `.gitignore`, `AGENTS.md`)
- [x] **Todo 2**: HTML5-Dateien verschieben & `build.py` anpassen (Ausgabe zu `savage-mod-player.html`)
- [x] **Todo 3**: Swift-Dateien verschieben & Paket- und Quelltext-Umbenennung zu `SavageModPlayer` durchführen
- [x] **Todo 4**: macOS Hilfsskripte (`build_app.sh`, `build_dmg.sh`, `publish_github.sh`) integrieren
- [x] **Todo 5**: Grafische Assets (`AppIcon.png` & `DmgBackground.png`) für App und DMG generieren
- [x] **Todo 6**: Echtzeit-Oszilloskope im Swift-Player implementieren:
  - [x] Master-Mix-Wellenform direkt im `AVAudioSourceNode` Render-Block mitschreiben (kein `installTap`)
  - [x] Echte 4-Kanal-Audio-Wellenformen über safe Puffer im `AVAudioSourceNode` Render-Block mitschreiben
- [x] **Todo 7**: Swift-UI-Layout anpassen & Performance-Fokussierung (flüssigeres Scrollen des Tracker-Grids)
- [x] **Todo 8**: Builds verifizieren und `swift test` ausführen
- [x] **Todo 9**: Ausführliche, ansprechende `README.md` im Stammverzeichnis anlegen (Gegenstück zu `vicious-sidplayer`)
- [x] **Todo 10**: Swift-App-Startcrash reproduzieren, Ursache beheben und mit `swift test` plus App-Start selbstständig verifizieren
- [x] **Todo 11**: HTML5-Variante so anpassen, dass gedroppte MOD-Dateien oder Ordner sofort die Wiedergabe starten
- [x] **Todo 12**: Copyright-geschützte Test-MODs im Ordner `audio/` strikt aus Git heraushalten und vor GitHub-Veröffentlichung erneut prüfen
- [x] **Todo 13**: Swift-Finetune wieder an HTML-Worklet-Näherung angleichen und langen One-Shot-Sample-Fortschritt per Test absichern
- [x] **Todo 14**: Swift-DSP-Fix für leere Rows nach langen Samples: `delayNote` darf laufende Noten nicht auf Tick 0 löschen; mit `Rtype.mod` Row 16 Kanal 4 absichern
- [x] **Todo 15**: Swift-5-Sekunden-Lauftest auf zufällige `.mod`-Datei aus `audio/` umstellen, damit pro Lauf mehr echte Module abgedeckt werden
- [x] **Todo 16**: Swift-App-Playlist sichtbar alphabetisch sortieren, Playlist-Einzelklick direkt abspielen und Dark-/Light-Farbpalette auf bessere Lesbarkeit umstellen
- [x] **Todo 17**: `README.md` auf aktuellen Swift-App-Stand bringen und ins Git aufnehmen
- [x] **Todo 18**: Swift-Playlist-Klickziele vergrößern und Freiraum zwischen Playlist-Zeilen entfernen
- [x] **Todo 19**: Swift-Light-Mode von Retro-Overlays befreien und `.gitignore` gegen versehentliche Audio-/Release-Artefakte härten
- [x] **Todo 20**: GitHub-Erstveröffentlichung vorbereiten: Single-File-HTML tracken, Release-/DMG-Skripte härten, Codesign/Notary-Pfad dokumentieren und Player-Herkunft prüfen
- [x] **Todo 21**: DMG selbst per Developer ID signieren, damit Gatekeeper nach Notary-Stapling `spctl -t open` akzeptiert
- [x] **Todo 22**: README klarstellen, dass GitHub-Release-DMGs notarisierte Builds sind
- [x] **Todo 23**: GitHub-Remote und README-Releases-Link auf das tatsächliche Repository `DanielMuellerIR/savage_modplayer` korrigieren

## Pflicht-Regressionstests

- **HTML-Drop-Autoplay**: Nach Änderungen an der HTML5-Variante `python3 -m http.server 8765` starten, `http://127.0.0.1:8765/savage-mod-player.html?testDropAutoplay=1` im Browser laden, den Test-Button klicken und prüfen, dass der simulierte Ordner-Drop `PLAYING` meldet.
- **Swift-Audio-Crash**: Nach Swift-Fixes immer `swift test --filter testRealtimePlaybackSurvivesFiveSeconds` ausführen. Der Test lädt ein zufälliges echtes MOD aus `audio/`, startet Wiedergabe und muss 5 Sekunden ohne Crash laufen.
- **Swift-RType-Langsample**: Nach DSP-Änderungen `swift test --filter ModParserTests/testRTypeFourthChannelSampleSurvivesPastRow16` ausführen. Der Test lädt `audio/Rtype.mod`; Pattern 0 Row 16 Kanal 4 muss auch viele Rows später noch hörbar rendern.
- **DSP-Timing & Amplitude**: `swift test --filter DSPChannelTimingTests` — Porta/Vibrato/Tremolo nur auf Tick > 0, ProTracker-Sinustabelle-Amplitude (depth*255/128 bzw. /64), Arpeggio-Zyklus, 9xx-Offset-Memory. Hardware-frei.
- **Sequenzierung**: `swift test --filter CoordinatorSequencingTests` — Pattern-Break-Hang (Dxx > 63), In-Range-Break-Ziel, hardware-freier Demo-Render-Smoke. Läuft ohne `audio/` und ohne Audio-Gerät.
- **JS↔Swift-Parität (headless)**: `node Tests/js/worklet-timing.mjs` — prüft, dass die Browser-Worklet-DSP dieselben Tick-/Amplituden-/Offset-Werte liefert wie `DSPChannel.swift`. Nach jeder DSP-Änderung in EINER Variante beide angleichen (siehe Synchronisierungsregel oben). Die Parität gilt für den gemeinsamen 4-Kanal-MOD-Kern; Multichannel/S3M sind Swift-only.
- **Multiformat**: `swift test --filter MultiFormatTests` — Multichannel-MOD (6CHN/8CHN/xxCH/FLT8), Soundtracker-15-Heuristik, S3M-Parsing (synthetisch + echte Dateien aus `audio/`), S3M-DSP (Perioden, Slides mit Memory, Tremor, Fine-Porta) und WAV-Offline-Render (RIFF-Validität, Nicht-Stille).
- **XM**: `swift test --filter XMParserTests` — Header/Pattern-Entpacker (gepackt + leer), Delta-Dekodierung 8/16-Bit, Keymap/Envelopes/Auto-Vibrato/Fadeout, Effekt-/Volume-Column-Übersetzung, Garbage-Ablehnung; plus Realwelt-Test über alle `.xm` aus `audio/`. XM-DSP (lineare Frequenz, Key-Off, Fadeout, Envelope-Interpolation, Volume-Column) in `DSPChannelTimingTests`.
- **Länge-1-Modul**: `swift test --filter LengthOneModuleTests` — `SongPositionScale` liefert für jede Songlänge (0/1/2/…) einen nicht-leeren Slider-Bereich (Länge 1 = 0…1, nicht das crashende 0…0); Länge-1-Modul parst/rendert/seekt ohne Crash. Hardware-frei.
- **Native App-Build**: Nach jedem Swift-Fix zusätzlich `./build_app.sh` ausführen, nicht nur `swift build` (baut auch die Quick-Look-Extension).
- **Quick Look (manuell)**: Nach App-Build/-Installation im Finder Leertaste auf einer `.mod`/`.s3m` — Audio-Player-Preview muss erscheinen und abspielen. Headless nur teilverifizierbar (Appex-Registrierung via `pluginkit -m -p com.apple.quicklook.preview`).

- [x] **Todo 24**: GitHub-Auftritt mit README-Icon und Social-Preview-Bild aus dem App-Icon aufwerten

## Audit-Durchlauf 2026-06-25 (Stand: 2026-06-25)

Intensiver Bug-/Verbesserungs-Audit beider Varianten. Umgesetzt (je mit Test):
- **Parser**: 6CHN/8CHN/FLT8 werden abgelehnt (Player ist strikt 4-kanalig; sonst Garbage); leere Songs (length 0) abgelehnt; lesbare `LocalizedError`-Meldungen; JS leere Pattern-Order abgesichert.
- **Engine**: Pattern-Break (Dxx > 63) hing den Song auf — geklemmt; Loop-Restart triggert erste Zeile; Master-Oszilloskop als rollender Ringpuffer; Songende-Signal (`songEndPulse`) wertet `loopMode` aus.
- **DSP-Genauigkeit** (Swift + JS identisch): Porta/Vibrato/Tremolo nur Tick > 0; Vibrato/Tremolo mit ProTracker-Sinustabelle und korrekter Tiefe; Arpeggio allokationsfrei (kein Heap im Audio-Thread); 9xx-Offset-Memory; JS-Loop-Wrap/One-Shot-Ende an Swift angeglichen; F00 ignoriert wie Swift; `notePerPeriod` an 856 verankert.
- **UI**: tote Menü-/Tastaturbefehle angeschlossen; Leer-Mod-Crash-Guard; Timer-Leak ersetzt; Lautstärke ab Start korrekt; Theme/loopMode/volume persistent; Recent-Songs-Temp-URLs stabil; Datei-I/O vom Main-Thread genommen; loopMode-Default jetzt `.playlist`.
- **Build**: Minifier verschmilzt `+ +` nicht mehr zu `++`.

Bewusst NICHT umgesetzt: „Vibrato/Tremolo-Offset bei Effekt-Ende zurücksetzen" (hätte Slide-Persistenz und ECx-Note-Cut zerschossen). Offen/optional: Anti-Click-Hüllkurve, JS-Sample-Interpolation als Hi-Fi-Option, VU-Tick-Allokationen reduzieren.

## Multiformat-Ausbau 2026-07-02 (Release 1.3.0)

Swift-Variante um weitere Tracker-Formate + Quick-Look-Plugin erweitert (Details oben unter „Unterstützte Formate" und „Quick-Look-Plugin"):
- **Parser**: Multichannel-MOD (xCHN/xxCH/CD81/OKTA, FLT8 als Pattern-Paare), Ur-Soundtracker-15-Heuristik (strenge Struktur-Checks gegen False-Positives; Repeat-Offset dort in Bytes statt Words), neuer `S3MParser` (Order-Filterung 254/255 mit Bxx-Remap, gepackte Patterns, unsigned→signed Samples).
- **Engine**: Kanäle dynamisch bis 32 (Puffer vorher fix 4), ST3-Periodenmodell pro Kanal konfigurierbar, S3M-Effekte (geteiltes Effekt-Memory D/E/F/I, Fine-/Extra-Fine-Porta, Tremor, Fine-Vibrato, Global Volume, Set Speed/Tempo als eigene interne IDs), Mix-Gain 4/N ab 5 Kanälen, Initial-Tempo/-Speed/-GlobalVolume aus dem Modul-Header.
- **Erledigt damit**: das frühere Deferred-Item „echte Multichannel-Unterstützung (6/8 Kanäle)".
- **Offen/optional**: XM/IT bewusst NICHT geplant (eigene Instrument-Engine nötig).

## Fix-Runde 2026-07-02 (Release 1.3.1)

Nachlese zum Code-Review + GUI-Feedback (je mit Test/Verifikation):
- **Instrument-Vorschau**: eigener, vom Song getrennter Wiedergabe-Pfad (separate `previewEngine` + eigener Kanal). Klingt jetzt auch im gestoppten Zustand und kapert nie mehr einen Song-Kanal (behob den stillen Mute/Solo-Verlust). Headless-Test: Render-Block liefert Signal im Frame-Budget, danach Stille.
- **Auto-Load `audio/`** rekursiv (findet `audio/Autor/x.mod`), und die Temp-Kopien früherer App-Läufe werden beim Start aufgeräumt (`AppMain.init`).
- **GUI**: Klickflächen der Instrument-Zeilen (ganze Box außer DL-Button) und der PLAYLIST/INSTRUMENTE-Tabs vergrößert (`contentShape`); tautologisches `if let bundlePath` entfernt.
- **Code-Review-Fehlalarm** dokumentiert: der NSText-First-Responder-Guard ist funktional (der Feld-Editor eines fokussierten SwiftUI-`TextField` ist eine `NSText`-Subklasse), `codereview-ok`-Marker gesetzt.
- **CI**: Runner auf `macos-15` (Swift 6.0) — der `macos-14`-Runner scheiterte an `swift-tools-version: 6.0`.

GUI-Umbau derselben Runde (visuell per fenstergezieltem Screenshot verifiziert, Multichannel mit dem 16-Kanal-S3M):
- **Oszilloskop-/Transport-Zeile**: Play/Pause liegt jetzt auf der rotierenden Disk im Transport-Balken (Stop/Prev/Next separat), LED-Filter/Hi-Fi/Loop in eine schmale Leiste unter die Oszis verschoben. Die **Kanal-Oszis sind adaptiv breit** (verfügbare Breite / Kanalzahl, Mindestbreite dann Scroll) — bis 16 Kanäle passen gleichzeitig; das VU-Meter schrumpft bei vielen Kanälen mit.
- **Pattern-Ansicht gestrafft**: Zeilenhöhe = Schrift + 6 (statt fix 24); Kanäle mit nur 1-pt-Trennlinie (heller) und eng an den Inhalt gelegten Zellen; bei drohender H-Scrollbar wird die Schrift um 1 verkleinert; **feststehende Zeilennummern-Spalte** (scrollt nicht mit); **eigene, dezent-graue H-Scrollbar** (native ist schwarz/nicht einfärbbar), am unteren sichtbaren Rand gepinnt.
- **Zuletzt gespielter Titel** wird bei ausgeschaltetem Shuffle nach Neustart wieder aufgenommen (`@AppStorage("savage.lastPlayed")`, stabiler Dateiname). Headless verifiziert.

## Code-Review-Runde 2026-07-08 (v1.4.2–1.4.4)

Report `2026-07-05` (MiniMax-Audit, gegen aktuellen Code verifiziert): von 11 realen Funden 9 erledigt, je mit Test/Verifikation:
- **#1** `modplayer.js` Pattern-Konstruktor mit Bounds-Check gegen abgeschnittene MODs (vorher unhandled `RangeError` im Drop-Handler). Regressionstest `Tests/js/pattern-bounds.mjs` durch echten `parseModBuffer`-Pfad; live gegen eine auf 1184 B gekürzte echte MOD gegengeprüft.
- **#2** Arpeggio im JS-Worklet von pro-Effekt allokiertem Array auf Skalare (`arpActive/arpX/arpY`) — wie `DSPChannel.swift`. Neuer Arpeggio-Parität-Test.
- **#14** Mute entmutet auf die letzte hörbare Lautstärke statt hartkodiert 1.0 (Browser-verifiziert).
- **#6** totes `spaceSurfaceHover` entfernt, **#7** `try? removeItem`→`do/catch`, **#13** `@inline(__always)` auf `renderChannelSample`.
- **#9/#10/#12** Light-Theme-Farben semantisch umbenannt (`amigaOrange`=blau→`lightAccent` usw.) + zentraler `Color.accent(theme)`-Helper.

**Noch offen (bewusst aufgeschoben):**
- **#3** `exportActiveModToWav` bricht per naiver Bedingung ab statt via `state.endReached` — kann bei Bxx-Position-Jump auf der letzten Position zu früh stoppen. Mit der XM-Arbeit prüfen (Verhaltensänderung am WAV-Export).
- **#11** Live-Render-Block und `advanceRowForProbe` sind ~80 Zeilen duplizierte Sequencer-Logik (Pattern-Break/Position-Jump/Loop/Delay), subtil auseinandergelaufen — Zusammenführen ist audio-korrektheits-riskant, eigener Task mit Tests.

Hinfällig im Report: #4 (bereits gefixt), #5 (Fehlalarm), #8 (Playlist-UI umgebaut).

## XM-Ausbau 2026-07-09 (FastTracker II)

Swift-Variante um das XM-Format erweitert — eine eigene Instrument-Engine (Entscheidung 2026-07-09: **Float-Sample-Engine projektweit + volles XM in einem Zug**, IT bewusst NICHT). In Meilensteinen, je committet + getestet:

- **M0 — Fundament (Datenmodell + Float):** Neues `Sample` (Float-PCM statt `[Int8]`, Loop inkl. Ping-Pong, Tuning) ist die Wiedergabe-Einheit; `Instrument` bündelt jetzt `[Sample]` + 96er-Keymap + Volume-/Panning-Hüllkurve + Fadeout + Auto-Vibrato. MOD/S3M = Instrument mit genau einem Sample über einen Convenience-Init (alte Signatur), Amplitude bitgleich (int8/256) → MOD-Wiedergabe und JS↔Swift-Parität unverändert. Sample-Felder (finetune/volume/loop/c2spd) liegen jetzt auf `Sample`, nicht mehr auf `Instrument` (`inst.primarySample`).
- **M1 — Parser (`XMParser`):** Header, gepackte Patterns (Bit7 + unkomprimiert, leere Patterns, abw. numRows), strikt über Längenfelder geseekt; Instrumente mit Keymap/Envelopes/Auto-Vibrato/Fadeout; Samples delta-dekodiert + normalisiert (8/16-Bit), Loop in Frames; Noten → `key` (1..96→key-1, 97→`Note.keyOff`), roher `volCmd`; Effekt-Übersetzung inkl. E-Serie + G/H/K/L/P/R/T/X.
- **M2 — Frequenz:** `DSPChannel.xmLinearMode` — lineare Periode (`7680 - realNote*64 - finetune/2`) + exponentielle Frequenz (`8363·2^((4608-period)/768)`, C-4 = 8363 Hz verifiziert).
- **M3 — Voice-Engine:** Volume-/Panning-Hüllkurve (Sustain + Loop, pro Tick interpoliert), Volume-Fadeout (Key-Off, FT2-Quirk: ohne Volume-Hüllkurve sofort still), Auto-Vibrato (Sine/Square/Ramp + Sweep), Ping-Pong-Loop. Renderer: Ausgabe · `xmVolumeScale`, Panning = `effectivePanning` (beide für MOD/S3M neutral).
- **M4 — Effekte:** Volume-Column vollständig (Set Vol/Panning, Vol-/Pan-Slides, Fine-Vol, Vibrato, Tone-Porta), plus Kxx/Lxx/Pxy/X1x/X2x.
- **M5 — Integration:** `ModuleLoader`-Dispatch, `supportedExtensions += xm`, Datei-Importer, Info.plist-UTIs (`com.viben.savage-modplayer.xm` + `org.videolan.xm`) und Quick-Look-`QLSupportedContentTypes`.

**Bewusst vereinfacht / offen (dokumentiert im Code):**
- **Amiga-Frequenz-XMs** (`flags` Bit0 = 0, selten) werden vorerst über das lineare Modell approximiert — echte Amiga-Periodentabelle ist ein Feinschliff (TODO in `configure`).
- **Hxy** (globales Volume-Slide, braucht einen Per-Tick-Hook im Coordinator) und **Rxy** (Multi-Retrig mit Volume-Modi) noch nicht umgesetzt; **Gxx** (Set Global Volume) läuft.
- **restartPos** ignoriert (Song wrappt auf 0); Order-Einträge ≥ numPatterns → leeres Pattern.
- XM-Effekt-Memory für 1xx/2xx/Axy/5xy/6xy ist implementiert (Param 0 =
  letzter Nicht-Null-Parameter dieses Effekt-Typs); Hxy/Pxy/Rxy-Memory bleibt
  optionaler Feinschliff mit den noch offenen Effekten.

**Test-Korpus:** 8 echte XM von Battle of the Bits liegen (gitignored) in `audio/` — der Realwelt-Test `XMParserTests/testRealXMFilesParseAndRender` parst + rendert sie (8–32 Kanäle, alle liefern hörbares Signal).

## XM-Korrektheit-Fix + headless Render-CLI (2026-07-09)

**Kernfehler gefunden & behoben (das „klingt kaputt" bei _Starfish - Life Support_):**
Der XM-Parser las die zweite Instrument-Header-Hälfte (Keymap +33, Envelopes +129,
Envelope-Metadaten +225.., Vibrato +235.., Fadeout +239) IMMER an ihren festen
Offsets. Manche Konverter schreiben aber einen verkürzten „sample-only"-Header
(`instrumentSize` 38 statt 263) OHNE zweite Hälfte — dann trafen die festen Offsets
Sample-Header-/PCM-Bytes: absurde Auto-Vibrati (depth 229), Envelope-Punkte wie
(8202, 64054) → Lautstärke ×1000 → Clipping, Müll-Fadeout/-Keymap. `Starfish` hatte
9 von 12 solcher Minimal-Header-Instrumente (die anderen 7 Test-XM: 0 — daher war nur
diese Datei grob kaputt). Fix in `XMParser`: zweite Hälfte nur bei
`instrumentSize >= 241` parsen, sonst keine Envelopes/Vibrato/Fadeout + leere Keymap
(→ immer Sample 0). Regressionstests: `testMinimalHeaderInstrumentHasNoGarbage`
(synthetisch, CI-tauglich) + Invariante im Realwelt-Test (keine Envelope-Value > 64 /
Frame > 1024 / Vibrato-Typ > 3 / Depth > 15).

**Neues Werkzeug — headless Render-CLI (`Sources/SavageCLI/`, Produkt `savage-cli`):**
Lädt ein Modul und rendert es mit DERSELBEN DSP-Engine (`ModuleRenderer`) zu WAV —
ohne GUI. `savage-cli <datei> [--out x.wav] [--seconds N] [--rate R] [--normalize]
[--no-interp] [--info] [--pattern N] [--quiet]`. `--info` gibt die geparste Struktur
aus (Instrumente/Samples/Envelopes/Auto-Vibrato), `--pattern N` dumpt ein Pattern als
Text. `--normalize` = Peak-Anhebung wie Quick Look; ohne = rohe Engine-Ausgabe für
A/B-Vergleiche. Auch das Fundament des geplanten Linux-CLI-Ports. `ModuleRenderer.renderWavData`
hat dafür einen `normalize`-Parameter bekommen (Default true, unverändert für Quick Look).

**Verifikationsmethode (headless, statt Computer-use):** `brew install libopenmpt` →
`openmpt123 --render --output-type wav --samplerate 44100 --channels 2 --no-float
--force -q <datei>` erzeugt eine Referenz-WAV. Beide (unsere `savage-cli`-Ausgabe +
Referenz) mono-mischen, auf Unit-RMS normieren, dann Kurzzeit-RMS-Hüllkurven-Korrelation
+ STFT-Cosine je Sekunde vergleichen (numpy/scipy). Nach dem Fix: alle 8 Test-XM
global-Spektrum-Cosine 0.94–1.0 (Timbre korrekt). Kontrolle openmpt-vs-openmpt = 0.999
(Metrik ist strikt/aussagekräftig).

**Bekannter Rest (kein „kaputt", aufgeschoben):** Die zwei DICHTESTEN 32-Kanal-XM
(_Galgox – Razer City_, _Xemogasa – sapphire eyes_) haben env-Korrelation ~0.64–0.68
(Frame-Cosine ~0.78) — ein diffuser, breitbandiger (±1–2,6 dB), zeitlich konstanter
Rest (kein Timing-Drift, kein Interpolations-/Limiter-/Detune-Effekt nachweisbar; per
Ausschluss geprüft). Vermutlich die Summe vieler kleiner FT2-Envelope-/Volume-Column-
Mikroquirks, die erst bei 32 Kanälen sichtbar werden. Kandidaten für später: XM-Perioden-Slide-
Skalierung (1xx/2xx/3xx ×4? — Experiment war ergebnislos, unverifiziert), Volume-Column-
Fine-Slide-Basis (currentVolume vs. volume).

**GETESTET & VERWORFEN (2026-07-09):** Der Kandidat „Instrument-ohne-Note-Envelope-Reset"
(FT2-Quirk: ein Instrument-Eintrag ohne neue Note triggert Volume-/Panning-Hüllkurve neu
+ Fadeout zurück, ohne Sample-Neuanschlag) wurde in `DSPChannel.playNote` implementiert und
per A/B gegen openmpt123 über ALLE 8 Test-XM gemessen — Ergebnis **byte-identisch**
(env-Korr/Frame-Cosine unverändert, u. a. Galgox 0.556, Xemogasa 0.710). Keine dieser
XM nutzt die Technik mit einem Hüllkurven-Instrument → null Effekt. Als spekulative
Echtzeit-Audio-Thread-Änderung ohne messbaren Nutzen wieder entfernt. Der diffuse Rest
liegt NICHT an diesem Quirk (bestätigt die „zeitlich konstant, kein Envelope-Timing"-Diagnose).

## CPU-Optimierung + Auto-Play-Argument (2026-07-09)

Die App-CPU bei Wiedergabe wurde ~HALBIERT (gemessen, sichtbares GUI, `top`):
**32-Kanal-XM 127 % → 63 %**, **4-Kanal-MOD 65 % → 37 %**. Methodik: App mit Song-
Argument headless starten (siehe unten), Fenster sichtbar, `sample <pid>` + `top`.

**Kette der Ursachen (per `sample`-Profiler gefunden, nicht geraten):**
1. **Disc-Rotation-Timer**: Ein 30-Hz-Timer erhöhte `diskRotation` als **@State auf
   MainView** → die ganze `MainView.body` (2000+ Zeilen) rerenderte 30×/s. Fix:
   `SpinningDiskButton` mit LOKALEM Rotations-State (TransportViews.swift).
2. **Tracker-Grid**: 64×32 = bis 2048 **SwiftUI-Text-Views** in einer ScrollView
   wurden bei jedem Zeilenwechsel (~20×/s bei schnellen Songs) neu gelayoutet
   (`ScrollView.sizeThatFits` sättigte den Main-Thread — der GRÖSSTE Posten). Fix:
   **alle Zellen in EINEM `Canvas`** (`ChannelCellsCanvas`), Equatable OHNE
   currentRow → nur bei Pattern-Wechsel neu gezeichnet, sonst bloß verschoben; die
   aktuelle Zeile ist ein separates Highlight-Band. Row-Nummern bleiben leichte
   Views (mit `.id` für scrollTo).
3. **32 Kanal-Streifen**: je (VU-Canvas + Scope-Canvas + 2 SwiftUI-Buttons), 30×/s.
   Fix: **alle VU+Oszilloskope in EINEM `Canvas`** (`ChannelScopesCanvas`); die
   Mute/Solo-Footer beobachten den visualizerState NICHT (kein 30-Hz-Rerender) und
   nutzen `onTapGesture` statt des teuren SwiftUI-Button.

**Architektur-Split (State vom Coordinator getrennt, damit MainView nicht bei jeder
Änderung neu evaluiert — klassisches ObservableObject invalidiert ALLE Beobachter):**
- `VisualizerState` (30 Hz: VU, Oszis, Spielzeit) — beobachten nur die Scope-/Zeit-Subviews.
- `TransportState` (row-rate: currentPosition/currentRow) — beobachten nur Grid,
  Positions-Slider, PAT-Anzeige, Marker-Map. `coordinator.currentPosition/-Row`
  bleiben als Convenience-Accessoren (leiten auf `transport` um).
- MainView beobachtet nur noch den Coordinator (seltene Änderungen).

Nebenbei: XM-Key-Off wird im Grid jetzt als `===` gezeigt (vorher „C#21", Key 253).

**Auto-Play per Argument / Öffnen-mit:** `SavageModPlayer <song.xm|ordner>` lädt und
spielt sofort (MainView.onAppear liest `CommandLine.arguments`); Finder-„Öffnen mit"
via `.onOpenURL`. Ermöglicht headless CPU-/GUI-Tests OHNE Klicken.

## GUI-/DSP-Fix-Runde 2026-07-09 (Abend) — Starfish-Blocker gelöst

Große Bug-Fix-Runde aus Daniels GUI-Review (alle committet, 87 Tests grün, NICHTS
auf GitHub). Erledigt:
- **Datei-Drop öffnete nichts** (`fe9eda9`): `URL(fileURLWithPath:)` auf einen
  `file://`-String → kaputter Pfad. Fix: `NSItemProvider.loadObject(ofClass: URL.self)`.
- **Single-Window** (`fa18060`): `WindowGroup`→`Window`; „Öffnen mit"/Dock-Drop nutzt
  das bestehende Fenster, spielt das richtige Lied (onAppear/onOpenURL-Race via Flag).
- **numRows-Timing** (`fa47a84`): Sequencer nahm fix 64 Reihen/Pattern an; XM ist
  variabel. Starfish-Dauer 212,6s→178,8s (=openmpt 178,9s). `patternRowCount`.
- **Zeit-/Positionsanzeige** (`b8ca754`): `cumulativeRows`/`positionAndRow` statt `*64`.
- **Porta ×4** (`9e25bc1`): XM 1xx/2xx/3xx slidet param*4 (libopenmpt). `portaScale`.
- **Ping-Pong ohne Endpunkt-Dopplung** (`9eb9365`): `end-over` statt `end-1-over`.
  Starfish frame-cosine 0.829→0.880, Höhen im Ausklang korrekt. Ohrbestätigt (Pattern 2+).
- **Playlist-Font** proportional statt monospaced (nur Tracker-Grid bleibt mono).
- **Splitter**: ziehbarer vertikaler (Playlist-Breite) + „zuletzt gespielt"-Höhe (`ResizableDivider`).
- **±10s-Buttons + Zeilen-Klick-Seek** (`23e55e2`): Klick auf Zeilennummer → Sprung;
  `seek(toPosition:row:)` rekonstruiert Speed/Tempo/GlobalVolume (`reconstructGlobalParams`).
- **Seek stummschaltung** (`2b27a57`): `applySeek` setzt `ch.playing=false` gegen hängende Kanäle.

**GELÖST — Starfish-Pitch-Rampe am Ende des ersten Patterns (2026-07-09):**
Der hörbare Fehler in _BotB 9805 Starfish - Life Support.xm_ war kein Ping-Pong-,
Envelope- oder Auto-Vibrato-Problem, sondern **fehlendes XM-Effekt-Memory für 1xx**.
Wichtiges Debugging-Detail: `savage-cli --pattern N` nimmt einen **Order-Index**,
keinen rohen Pattern-Index. Die frühere Analyse mit `--pattern 26` dumpte deshalb
Order 26 → Pattern 21 (30 Reihen) und sah die echte Stelle nicht. Der erste
abgespielte Pattern ist Order 0 → Pattern 26 (64 Reihen). Dort stehen auf den ersten
zwei Kanälen:

```text
60| ... 0105 | ... 0105
61| ... 0100 | ... 0100
62| ... 0100 | ... 0100
63| ... 0100 | ... 0100
```

In FastTracker II bedeutet `100`: **den letzten 1xx-Parameter wiederholen**. Unser
DSP behandelte den Parameter 0 als echten Wert 0; dadurch machte Row 60 mit `105`
einen kurzen Pitch-Slide-Up, ab Row 61 wurde `periodDelta` aber 0 und die Rampe blieb
stehen. Das klang wie „geht ein Stück hoch und bleibt dann dort".

Fix in `DSPChannel`: pro Kanal eigener XM-Memory für `1xx`, `2xx` und
`Axy/5xy/6xy` (`xmPortaUpMemory`, `xmPortaDownMemory`, `xmVolumeSlideMemory`),
zurückgesetzt in `reset()`. Aktiv nur in `xmLinearMode`; MOD und S3M bleiben auf
ihren bisherigen Pfaden. `portaScale` ×4 bleibt erhalten, d. h. Starfish macht bei
Speed 4 pro Row drei Schritte à `5*4` Periodeneinheiten und die Tonhöhe steigt über
Rows 60–63 weiter bis zum Pattern-Wechsel.

Regression: `DSPChannelTimingTests/testXMPortaUpZeroReusesPreviousParameter`
bildet exakt `105,100` nach; `testXMVolumeSlideZeroReusesPreviousParameter`
deckt `A00` analog ab. Verifiziert mit `swift test --filter DSPChannelTimingTests`,
komplettem `swift test` (89 Tests inkl. Starfish-Real-XM-Render),
`node Tests/js/worklet-timing.mjs`, `git diff --check` und `./build_app.sh`.

Bekannter Rest im Seek-Feature: Per-Kanal-Slide-/Sustain-Zustände werden beim Sprung
NICHT rekonstruiert → gehaltene Noten von vor dem Sprung fehlen (bewusster Kompromiss).

## Offene Punkte / Nächste Schritte (Stand 2026-07-09)

XM-Kern (M0–M5) steht, committet, getestet; im echten App-GUI verifiziert (spielt
32-Kanal-XM). Aus dem GUI-Test offen (Reihenfolge = Priorität):

1. **Pattern-Grid zeichnet evtl. nicht alle Reihen** — der `TrackerGridView` wurde
   2026-07-09 komplett auf einen Canvas umgebaut (siehe CPU-Abschnitt): alle 64
   Zeilen werden in einem fix-hohen Canvas gezeichnet, vertikal gescrollt. Das alte
   Equatable-VStack-Clipping ist damit hinfällig. Falls Daniel im Screenshot noch
   fehlende Reihen sieht: gegen die neue Canvas-Höhe (`rowCount*(fontSize+6)`) prüfen.
2. **XM-Song-Korrektheit** — ✅ ERLEDIGT für den Release-Blocker (2026-07-09):
   Minimal-Header-Instrument-Garbage behoben; Starfish-Pitch-Rampe durch XM-1xx-
   Effekt-Memory behoben und per Regressionstest abgesichert. Rest: nur noch
   subtile Envelope-/Volume-Column-Feinheiten bei den 2 dichtesten 32-Kanal-Songs
   (dokumentiert oben, kein „kaputt").
3. **CPU-Optimierung (Kern)** — ✅ ERLEDIGT (2026-07-09, siehe Abschnitt oben): CPU
   ~halbiert (32ch 127 → 63 %, 4ch 65 → 37 %). Kernursachen (Disc-Timer-@State,
   2048-Zellen-Grid-ScrollView, 32 Streifen-Buttons) per Profiler gefunden + gefixt
   (Grid + Scopes als je EIN Canvas; VisualizerState/TransportState-Split).
4. **Deferred aus den Meilensteinen:** Amiga-Frequenz-XMs (echte Periodentabelle statt linearer Näherung); XM-Effekte **Hxy** (globales Vol-Slide, braucht Per-Tick-Hook im Coordinator) + **Rxy** (Multi-Retrig); Memory/Feinheiten für die noch offenen XM-Effekte.
5. **Länge-1-Modul: Headless-Test** — ✅ ERLEDIGT (2026-07-09). Die Crash-verhindernde Arithmetik wurde aus `PositionSlider` in den pure Core-Helfer `SongPositionScale` ausgelagert (der eigentliche SwiftUI-`Slider`-Crash bei `mod.length == 1` ist selbst nicht headless reproduzierbar). Regressionstest `LengthOneModuleTests` — Invariante „Slider-Range nie leer" (Längen 0/1/2/…) + Länge-1-Modul parst/rendert/seekt ohne Crash. Repro-Datei `audio/_ZZ_len1_crashtest.xm` entfernt.
6. **Release** — ✅ ERLEDIGT (2026-07-10): v1.5.0 auf GitHub veröffentlicht (Tag + notarisiertes DMG, Notary-Profil per `NOTARY_PROFILE`-Env). READMEs auf XM aktualisiert, neuer Screenshot (32-Kanal-XM „Razer City", Dark Mode), Release-Notes EN/DE neu geschrieben.

**Hinweis Standard-Playlist-Ordner:** Durch das App-Starten aus dem Repo wurde der Auto-Load-/Standard-Ordner auf `audio/` gezogen; Daniel hatte einen anderen gesetzt. Nächste Session ggf. zurückstellen anbieten (Wert steckt in `@AppStorage`).

## IT-Ausbau (seit 2026-07-10)

Daniel hat die schrittweise Unterstützung von Impulse Tracker (`.it`) freigegeben.
Der verbindliche Langzeitplan liegt unter
`tasks/2026-07-10-it-support/`; `state.md`, `decisions.md` und `handoff.md` sind
die maßgebliche Übergabe zwischen Sessions.

Wichtige Leitplanken:

- IT ist ein eigener Wiedergabe-/Kompatibilitätsmodus, kein S3M-Untermodus.
- Vor dem Parserausbau werden Renderer-Stopp-Semantik, A/B-Harness und der
  duplizierte Sequencer in getrennten M0-Paketen abgesichert.
- NNA erfordert getrennte Pattern-Kanal- und Voice-Zustände sowie einen
  vorallokierten Voice-Pool.
- `.it` wird erst nach dem abschließenden Integrations-Gate öffentlich in Loader,
  App-UTI und Quick Look aktiviert.
- Die Agentenzelle ist auf vier feste Subagenten-Identitäten begrenzt; kein
  Subagent darf weitere Agenten erzeugen.
- **IT-001 (Version 1.5.2):** Gestoppte geloopte Stimmen liefern im gemeinsamen
  Sample-Renderer sofort Stille. Ein gerätefreier Regressionstest läuft über
  denselben privaten Pfad wie Live-, Probe- und Offline-Wiedergabe; vor dem Fix
  waren alle 32 Testframes trotz `playing == false` hörbar. Reviewer-`ACCEPT`,
  90 Swift-Tests, JS-Parität und signierter App-/Quick-Look-Build sind grün.
- **IT-002 (Version 1.5.3):** `savage-cli --no-interp` wird bis in
  `ModuleRenderer` durchgereicht. Der Default bleibt interpoliert und damit für
  Quick Look unverändert; ein synthetischer WAV-Test beweist bytegleichen
  Default/`true`-Output sowie hörbares, gleich langes, aber verschiedenes PCM
  mit `false`. Reviewer-`ACCEPT`, 91 Swift-Tests, CLI-Build, JS-Parität und
  signierter App-/Quick-Look-Build sind grün.
- **IT-003 (Version 1.5.4):** Ein wertbasierter Sequencer-Trace friert Frame,
  Position/Pattern, Row/Tick, Speed/Tempo/Global Volume sowie Jump-, Break-,
  Loop- und Delay-Zustände ein. Live-/Offline-Renderblock und Probe stimmen über
  104 Abtastpunkte elementweise überein; Coverage beweist echte E61-Row-
  Transition und drei EE2-Tick-Wraps. Reviewer-`ACCEPT`, 92 Swift-Tests,
  JS-Parität und signierter App-/Quick-Look-Build sind grün.
- **IT-004 (Version 1.5.5):** Die doppelte Tick-, Row-, Sprung-, Delay- und
  Effektlogik läuft jetzt in einem gemeinsamen statischen, allokationsfreien
  `SequencerCore`; Live/Offline/Probe rufen denselben Kern. Die IT-003-Tests
  blieben bytegleich. Reviewer-`ACCEPT`, 92 Swift-Tests, alle gezielten
  Sequencer-/DSP-/Crash-/RType-Tests, JS-Parität und signierter App-/Quick-Look-
  Build sind grün.
- **IT-005 (Version 1.5.6):** `Note.effectPresent` unterscheidet explizite
  Nullparameter-Befehle von leeren Zellen, bleibt per optionalem Codable-Feld
  legacy-kompatibel und wird in MOD/S3M/XM nach der bestehenden Übersetzung
  eingefroren. Echte MOD-C00/D00/100-, S3M-D00- und XM-Nullparameter-Fixtures
  sowie leere Zellen sind getestet. Reviewer-`ACCEPT`, 93 Swift-Tests,
  JS-Parität und signierter App-/Quick-Look-Build sind grün.
- **IT-006 (Version 1.5.7):** Der gemeinsame Renderblock kann optional
  vorallozierte Float-Stereo-Daten vor `tanh` sowie kanalweise Mono-Stems vor
  Panning, Mix-Gain und Limiter in festen Offline-Blöcken erfassen. Der
  bestehende WAV-Pfad bleibt bytegleich; der Consumer wird erst nach der
  Callback-Rückkehr bedient und es gibt keine songlangen Stem-Puffer. Ein
  synthetischer Mehrkanal-Test rekonstruiert Panning/Mix und Int16-Ausgabe bis
  auf 1 LSB. Reviewer-`ACCEPT`, 94 Swift-Tests, JS-Parität und signierter
  App-/Quick-Look-Build sind grün.
- **IT-007 (Version 1.5.8):** `tools/reference_compare.py` rendert MOD, S3M und
  XM reproduzierbar mit `savage-cli` und der eingefrorenen `openmpt123`-Version
  und schreibt deterministische JSON-Berichte mit Pegel-, RMS-Hüllkurven-,
  Lag-, Onset-, Timing- und STFT-Metriken. Das Werkzeug nutzt ausschließlich
  die Python-Standardbibliothek, lehnt `.it` vor jedem Unterprozess ab und
  hält Module/WAVs/Berichte aus Git. 14 synthetische Tests, doppelte
  Realwelt-Smokes für alle drei Formate, Reviewer-`ACCEPT`, 94 Swift-Tests,
  JS-Parität und signierter App-/Quick-Look-Build sind grün. M0 ist damit
  abgeschlossen.
- **IT-008 (Version 1.5.9):** Die gemeinsamen Modelltypen wurden bytegleich aus
  `ModParser.swift` in `ModuleModels.swift` ausgelagert. Öffentliche Signaturen,
  Defaults, Raw Values, Codable-Verhalten sowie Parser- und Audiosemantik bleiben
  unverändert; `.it` und neue Playback-Semantik sind noch deaktiviert. Reviewer-
  `ACCEPT`, 44 gezielte Parser-Tests, 94 Swift-Tests, JS-Parität und signierter
  App-/Quick-Look-Build sind grün. M1 ist damit gestartet.
- **IT-009 (Version 1.5.10):** `ModuleFormat.it` und das werttypische
  `PlaybackSemantics` mit eigenem `ITCompatibility`-Profil bilden die interne
  Typgrenze für ProTracker-, ST3-, FT2- und IT-Regeln. `Old Effects` und
  `Compatible Gxx` müssen später ausdrücklich aus dem IT-Header kommen; `.it`
  bleibt im Loader und in der App deaktiviert. Reviewer-`ACCEPT`, 99 Swift-Tests,
  JS-Parität und signierter App-/Quick-Look-Build sind grün.

## Fallen / Agent-Hinweise

- **Notarisierung ist pro-Mac (verifiziert 2026-07-03)**: Das notarytool-Keychain-Profil wird nicht über iCloud gesynct. Der in `build_dmg.sh` hartkodierte Default-Profilname existiert nicht zwangsläufig auf dem gerade genutzten Mac — dann bricht `--notarize` mit „Notary-Keychain-Profil nicht gefunden" ab. Lösung: ein vorhandenes Profil per `NOTARY_PROFILE=<profil> bash build_dmg.sh --notarize` übergeben (oder das bereits gebaute, signierte DMG direkt mit `xcrun notarytool submit … --keychain-profile <profil> --wait` + `xcrun stapler staple`). Die konkreten Profilnamen pro Mac stehen in der privaten Setup-Notiz, nicht hier (Public-Repo).
- **Release-Notes ohne eigene H1**: `publish_github.sh` setzt den Release-Titel via `--title` UND nutzt `RELEASE_NOTES.md` als Text. Beginnt die Notes-Datei mit einer `#`-Überschrift, erscheint der Titel auf GitHub doppelt. Notes-Dateien deshalb direkt mit dem ersten Absatz starten.

- **Quick Look + VLC (verifiziert 2026-07-02)**: Ist eine App installiert, die `.mod` als Medien-UTI EXPORTIERT (VLC → `org.videolan.mod`, konform zu `public.audio`), nimmt Quick Look für `.mod` seinen System-Medien-Fast-Path und fragt Dritt-Preview-Extensions GAR NICHT an (bekannte QL-Einschränkung, gleiches Prinzip wie bei mp3). `.s3m` ist davon nicht betroffen — dort spawnt unsere Extension nachweislich (`pgrep -lf SavageModPlayerQuickLook` während `qlmanage -p file.s3m`). Ohne VLC greift die importierte `public.data`-UTI der App und auch `.mod` läuft über unsere Extension. Nicht dagegen ankämpfen (eigener UTI-Export wäre ein unzuverlässiger Koinflip gegen VLC).
- **Appex-Registrierung nach Rebuild**: `build_app.sh` löscht/erzeugt das .app neu — danach kennt PluginKit den Appex u. U. nicht mehr. Für lokale Tests: `pluginkit -a "<app>/Contents/PlugIns/SavageModPlayerQuickLook.appex"`; Kontrolle mit `pluginkit -m -p com.apple.quicklook.preview`. Bei Installation nach `/Applications` passiert das automatisch.
- **`qlmanage -p -o dir` (headless) nutzt moderne Preview-Extensions NICHT** — nur den Legacy-Pfad. Ein leeres Ergebnis dort heißt nicht, dass die Extension kaputt ist; Prozess-Spawn-Check (siehe oben) ist der verlässliche Headless-Beweis.
- **QL-Audio-Preview braucht `QLPreviewReply(fileURL:)` (verifiziert 2026-07-02)**: Eine Daten-Reply (`dataOfContentType: .wav`) zeigt für Audio nur die generische Info-Karte (Titel erscheint, aber kein Player). Erst die Datei-URL-Variante (laut `QLPreviewReply.h` explizit inkl. `UTTypeAudio`) liefert das native Player-UI. Deshalb schreibt der Provider die gerenderte WAV in den Temp-Bereich des Extension-Containers und liefert die URL.
