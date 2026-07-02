# AGENTS.md — Savage Protracker Player

Diese Datei ist die zentrale Projektdokumentation. Sie beschreibt die Architektur, Konventionen und offene Todos für den **Savage Protracker Player**.

---

## Projektüberblick

Der **Savage Protracker Player** ist ein plattformübergreifender Amiga-/Tracker-Modul-Player. Er ist als direktes Gegenstück zum **Vicious SID Player** konzipiert und besteht aus zwei Implementierungen:
1. **HTML5-Variante**: Ein kompakter (unter 40 KB minifizierter) Single-File-Browser-Player (`savage-protracker-player.html`), der ohne Webserver direkt aus dem Dateisystem per Doppelklick gestartet werden kann. Bewusst auf klassische 4-Kanal-ProTracker-MODs beschränkt (Kompaktheit).
2. **Swift-Variante**: Eine native, hochperformante macOS- & iOS-Anwendung (`Savage Protracker Player.app`), implementiert in SwiftUI und `AVAudioEngine`/`AVAudioSourceNode` für eine ressourcenschonende und latenzfreie Wiedergabe.

### Unterstützte Formate (Stand 1.3.0)

| Format | HTML5 | Swift + Quick Look |
|---|---|---|
| ProTracker MOD (M.K., M!K!, FLT4, 4CHN) | ✅ | ✅ |
| Multichannel-MOD (xCHN 2-9, xxCH 10-32, CD81/OKTA/OCTA, FLT8-Pattern-Paare) | ❌ | ✅ |
| Ur-Soundtracker (15 Instrumente, ohne Signatur, per Struktur-Heuristik) | ❌ | ✅ |
| ScreamTracker 3 (S3M, bis 32 PCM-Kanäle) | ❌ | ✅ |

Format-Dispatch am Dateiinhalt: `ModuleLoader.parse(data:)` (SCRM-Header → `S3MParser`, sonst `ModParser`).

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
p_savage_protracker/
├── savage-protracker-player.html  ← Fertig gebauter Single-File-Browserplayer
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
│   ├── SavageProtrackerPlayerApp/ ← SwiftUI Main View & UI-Komponenten
│   └── SavageProtrackerPlayerCore/← AVAudioEngine, Parser & DSP-Engine
├── Tests/                         ← XCTest Unittests
├── build.py                       ← Bündelt & minifiziert savage-protracker-player.html
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
- **Parser (`SavageProtrackerPlayerCore/Parser/`)**: Reines Swift, parst `.mod`-Varianten (`ModParser`) und `.s3m` (`S3MParser`) in typsichere Werttypen (`struct`); Einstieg ist `ModuleLoader`. S3M-Noten liegen als Halbton-Keys (`Note.key`) vor, S3M-Effekte werden auf ProTracker-IDs bzw. `ModuleEffect.*`-IDs (>= 0x100) übersetzt.
- **DSP / Synthesizer (`SavageProtrackerPlayerCore/DSP/`)**: Verwendet `AVAudioSourceNode` innerhalb von `AVAudioEngine`. Läuft direkt auf dem Core Audio Echtzeit-Thread. Kanalzahl dynamisch (bis 32, vorallozierte Puffer); Frequenzmodell pro Modul: Amiga-Paula-Perioden (MOD) oder ST3-Perioden mit C2Spd + 14,3-MHz-Clock (`DSPChannel.s3mMode`).
  - *Wichtig*: Keine Heap-Alloziierungen, Sperren oder dynamische Objective-C-Aufrufe im Render-Block!
- **Offline-Renderer (`ModuleRenderer`)**: rendert Module mit demselben Render-Block zu WAV-Daten (Quick Look, Tests).
- **UI (`SavageProtrackerPlayerApp/UI/`)**: Deklaratives SwiftUI. Enthält zentrierende Tracker-Zeilen-Tabellen (dynamische Spaltenzahl, horizontales Scrollen ab 5 Kanälen), Visualizer und CRT-Effekt-Filter.

---

## Aktuelle Todos (Release 1.2.33)

- [x] **Todo 1**: Git-Repository initialisieren & Stammdateien anlegen (`VERSION`, `LICENSE`, `.gitignore`, `AGENTS.md`)
- [x] **Todo 2**: HTML5-Dateien verschieben & `build.py` anpassen (Ausgabe zu `savage-protracker-player.html`)
- [x] **Todo 3**: Swift-Dateien verschieben & Paket- und Quelltext-Umbenennung zu `SavageProtrackerPlayer` durchführen
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
- [x] **Todo 23**: GitHub-Remote und README-Releases-Link auf das tatsächliche Repository `DanielMuellerIR/savage_protracker` korrigieren

## Pflicht-Regressionstests

- **HTML-Drop-Autoplay**: Nach Änderungen an der HTML5-Variante `python3 -m http.server 8765` starten, `http://127.0.0.1:8765/savage-protracker-player.html?testDropAutoplay=1` im Browser laden, den Test-Button klicken und prüfen, dass der simulierte Ordner-Drop `PLAYING` meldet.
- **Swift-Audio-Crash**: Nach Swift-Fixes immer `swift test --filter testRealtimePlaybackSurvivesFiveSeconds` ausführen. Der Test lädt ein zufälliges echtes MOD aus `audio/`, startet Wiedergabe und muss 5 Sekunden ohne Crash laufen.
- **Swift-RType-Langsample**: Nach DSP-Änderungen `swift test --filter ModParserTests/testRTypeFourthChannelSampleSurvivesPastRow16` ausführen. Der Test lädt `audio/Rtype.mod`; Pattern 0 Row 16 Kanal 4 muss auch viele Rows später noch hörbar rendern.
- **DSP-Timing & Amplitude**: `swift test --filter DSPChannelTimingTests` — Porta/Vibrato/Tremolo nur auf Tick > 0, ProTracker-Sinustabelle-Amplitude (depth*255/128 bzw. /64), Arpeggio-Zyklus, 9xx-Offset-Memory. Hardware-frei.
- **Sequenzierung**: `swift test --filter CoordinatorSequencingTests` — Pattern-Break-Hang (Dxx > 63), In-Range-Break-Ziel, hardware-freier Demo-Render-Smoke. Läuft ohne `audio/` und ohne Audio-Gerät.
- **JS↔Swift-Parität (headless)**: `node Tests/js/worklet-timing.mjs` — prüft, dass die Browser-Worklet-DSP dieselben Tick-/Amplituden-/Offset-Werte liefert wie `DSPChannel.swift`. Nach jeder DSP-Änderung in EINER Variante beide angleichen (siehe Synchronisierungsregel oben). Die Parität gilt für den gemeinsamen 4-Kanal-MOD-Kern; Multichannel/S3M sind Swift-only.
- **Multiformat**: `swift test --filter MultiFormatTests` — Multichannel-MOD (6CHN/8CHN/xxCH/FLT8), Soundtracker-15-Heuristik, S3M-Parsing (synthetisch + echte Dateien aus `audio/`), S3M-DSP (Perioden, Slides mit Memory, Tremor, Fine-Porta) und WAV-Offline-Render (RIFF-Validität, Nicht-Stille).
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

## Fallen / Agent-Hinweise

- **Quick Look + VLC (verifiziert 2026-07-02)**: Ist eine App installiert, die `.mod` als Medien-UTI EXPORTIERT (VLC → `org.videolan.mod`, konform zu `public.audio`), nimmt Quick Look für `.mod` seinen System-Medien-Fast-Path und fragt Dritt-Preview-Extensions GAR NICHT an (bekannte QL-Einschränkung, gleiches Prinzip wie bei mp3). `.s3m` ist davon nicht betroffen — dort spawnt unsere Extension nachweislich (`pgrep -lf SavageProtrackerQuickLook` während `qlmanage -p file.s3m`). Ohne VLC greift die importierte `public.data`-UTI der App und auch `.mod` läuft über unsere Extension. Nicht dagegen ankämpfen (eigener UTI-Export wäre ein unzuverlässiger Koinflip gegen VLC).
- **Appex-Registrierung nach Rebuild**: `build_app.sh` löscht/erzeugt das .app neu — danach kennt PluginKit den Appex u. U. nicht mehr. Für lokale Tests: `pluginkit -a "<app>/Contents/PlugIns/SavageProtrackerQuickLook.appex"`; Kontrolle mit `pluginkit -m -p com.apple.quicklook.preview`. Bei Installation nach `/Applications` passiert das automatisch.
- **`qlmanage -p -o dir` (headless) nutzt moderne Preview-Extensions NICHT** — nur den Legacy-Pfad. Ein leeres Ergebnis dort heißt nicht, dass die Extension kaputt ist; Prozess-Spawn-Check (siehe oben) ist der verlässliche Headless-Beweis.
