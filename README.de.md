<p align="center">
  <img src="src/AppIcon.png" width="128" alt="Savage Protracker Player Icon">
</p>

<h1 align="center">Savage Protracker Player</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Amiga-/Tracker-Modul-Player als Single-File-HTML5-Version und native SwiftUI-macOS-App mit Quick-Look-Plugin.</strong>
</p>

Ein plattformübergreifender, eigenständiger Tracker-Modul-Player in zwei Varianten:

1. **HTML5 (`savage-protracker-player.html`)** — Eine einzelne HTML-Datei (unter 50 KB), die ohne Webserver direkt per Doppelklick aus dem Dateisystem funktioniert. Spielt klassische 4-Kanal-ProTracker-MODs.
2. **Native macOS App (`Savage Protracker Player.app`)** — SwiftUI-Desktop-Anwendung mit `AVAudioEngine`, `AVAudioSourceNode`, echten Echtzeit-Oszilloskopen und Pegel-Metern. Spielt zusätzlich Multichannel-MODs (6/8/… Kanäle, u. a. `6CHN`/`8CHN`/`FLT8`), 15-Sample-Soundtracker-Module und **ScreamTracker 3 (`.s3m`)** — und bringt ein **Quick-Look-Plugin** mit: Leertaste auf einer `.mod`/`.s3m` im Finder öffnet eine abspielbare Audio-Vorschau.

Beide Varianten enthalten standardmäßig keine Moduldateien. Musikstücke werden per Drag & Drop oder Datei-Dialog geladen.

---

## Download

Fertige Builds der macOS-App stehen als notarisierte DMGs auf der [Releases-Seite](https://github.com/DanielMuellerIR/savage_protracker/releases) bereit. DMG herunterladen, öffnen und die App in den Programme-Ordner ziehen.

Der HTML5-Player benötigt keinen Download über die Releases hinaus: Die Datei `savage-protracker-player.html` lässt sich direkt im Browser öffnen.

---

## Quick-Look-Plugin installieren

Das Quick-Look-Plugin steckt bereits im App-Bundle (`Contents/PlugIns/`) — es gibt nichts separat zu installieren:

1. App aus dem DMG nach **`/Applications`** ziehen.
2. Die App **einmal starten** (dabei registriert macOS die enthaltene Quick-Look-Extension).
3. Im Finder eine `.mod`- oder `.s3m`-Datei markieren und die **Leertaste** drücken — die Vorschau zeigt den macOS-Audio-Player mit dem fertig gerenderten Stück (Play, Scrubbing, Lautstärke). Der erste Aufruf braucht ein bis zwei Sekunden, weil der Song komplett durch die Player-Engine gerendert wird.

Falls keine Vorschau erscheint:

- Quick-Look-Dienst neu laden: `qlmanage -r` im Terminal, dann die Vorschau erneut öffnen.
- Registrierung prüfen: `pluginkit -m -p com.apple.quicklook.preview | grep -i savage` muss einen Eintrag zeigen; falls nicht, App einmal starten oder neu nach `/Applications` kopieren.
- **Hinweis zu `.mod` und VLC**: Ist VLC (oder eine andere App, die `.mod` als Audio-/Video-Typ registriert) installiert, fängt macOS `.mod`-Dateien mit seiner eingebauten Medien-Vorschau ab, bevor Drittanbieter-Plugins gefragt werden — eine Systembeschränkung von Quick Look. `.s3m`-Vorschauen funktionieren davon unabhängig immer.

---

## Funktionsumfang

- **Formatvielfalt (macOS-App)**: ProTracker-MOD, Multichannel-MOD (`xCHN`/`xxCH`/`CD81`/`OKTA`/`FLT8`), 15-Sample-Soundtracker und ScreamTracker 3 (`.s3m`) inklusive Volume-Column, Panning und S3M-Effekten. Der HTML5-Player bleibt bewusst kompakt und spielt 4-Kanal-MODs.
- **Quick-Look-Vorschau (macOS-App)**: Das mitgelieferte Quick-Look-Plugin rendert `.mod`/`.s3m` mit der Player-Engine und zeigt im Finder (Leertaste) den nativen Audio-Player mit Play und Scrubbing.
- **Drag & Drop**: Einzelne `.mod`-/`.s3m`-Dateien oder ganze Ordner (rekursiv) können auf den Player gezogen werden.
- **Automatische Playlist**: Wenn im selben Ordner wie der Player oder die App ein Unterordner namens `audio/` vorhanden ist, wird dieser beim Start automatisch gescannt und als alphabetisch sortierte Playlist geladen.
- **Playlist-Bedienung**: Einzelklick auf einen Playlist-Eintrag lädt und startet den Titel direkt. Nach dem Songende kann die Playlist automatisch weiterlaufen.
- **Echtzeit-Oszilloskope**:
  - Ein echtes Stereo-Master-Mischungs-Oszilloskop direkt aus dem Audio-Renderpfad.
  - Separate Spur-Oszilloskope für jeden Kanal (dynamische Kanalzahl), die die tatsächlichen Schwingungsformen direkt aus dem Synthesizer-Render-Block visualisieren.
- **Multi-Theme**:
  - **Dark**: Graphit-/Schwarzpalette mit gutem Kontrast und gedämpften Akzentfarben.
  - **Light**: klassischer, heller macOS-naher Stil mit nüchternem Kontrast.
- **PAL- & NTSC-Taktfrequenzen**: Umschaltbare Paula-Taktung (7,09 MHz PAL vs. 7,16 MHz NTSC).
- **Lautstärke & Stereo-Separation**: Psychoakustische (quadratische) Lautstärkeskalierung und einstellbare Stereo-Separation (Bleed von 0% Mono bis 100% Hard-Panning).
- **Hi-Fi Resampling**: Umschaltbares linear-interpoliertes Sample-Playback für weicheren Sound (deaktivierbar für originalen 8-Bit-Crunch).
- **WAV- & Stem-Export**: Export des gesamten Songs in eine Stereo-WAV-Datei sowie Export einzelner Instrumentensamples als WAV.
- **Komplette Tastatursteuerung**: Leertaste für Play/Pause, Pfeiltasten links/rechts für Song-Positionen, Pfeiltasten oben/unten für Song-Wechsel in der Playlist.

---

## Technischer Hintergrund

### Synthese & Paula-Emulation

Die Audio-Engine simuliert das Amiga Paula-Hardwareverhalten:
- **Taktung**: Der Taktgeber rechnet mit der PAL-Paula-Frequenz von `3.546.894,6 Hz`. Der Pitch-Faktor ergibt sich aus dem Frequenzverhältnis zur aktuellen Audio-Ausgaberate.
- **Stereo-Panning**: Amiga-typisches Hardware-Panning (Kanäle 1 und 4 links, Kanäle 2 und 3 rechts) mit einstellbarer Software-Mischung zur Vermeidung von Kopfhörer-Ermüdung.
- **Effekte**: Vollständige Wiedergabetreue für alle Standard-ProTracker-Befehle, einschließlich Arpeggio (`0x0`), Slides (`0x1`/`0x2`), Tone Portamento (`0x3`), Vibrato (`0x4`), Volume Slides (`0xA`), Position Jump (`0xB`), Volume Set (`0xC`), Pattern Break (`0xD`), Extended Effects (`0xE` wie Loop, Cut, Note Delay, Retrigger) und Tempo-Steuerung (`0xF`).

Für ScreamTracker 3 rechnet die Engine im ST3-Periodenmodell (C2Spd-basierte Perioden gegen die ST3-Clock 14,3 MHz) statt in Amiga-Paula-Perioden; die ProTracker-Effekte werden um S3M-Spezifika (Fine-/Extra-Fine-Slides mit Effekt-Memory, Tremor, Fine-Vibrato, Global Volume) ergänzt.

### Architektur

| Schicht | HTML5 | macOS (Swift) |
|---|---|---|
| Parser | `modplayer.js` | `ModuleLoader`/`ModParser`/`S3MParser` (SavageProtrackerPlayerCore) |
| DSP / Mixer | `mod-player-worklet.js` (AudioWorklet) | `ModPlayerCoordinator.swift` (`AVAudioSourceNode`, bis 32 Kanäle) |
| UI | Vanilla JS + CSS Grid | SwiftUI + Canvas |
| Quick Look | — | `quicklook/PreviewProvider.swift` (Appex, WAV-Offline-Render) |

---

## Build

### HTML5

```bash
python3 build.py                  # → savage-protracker-player.html (~48 KB)
python3 build.py --no-min         # ohne Minifizierung
```

Die erzeugte Single-File-Variante `savage-protracker-player.html` ist Teil des
Repositories, damit der Player auch ohne lokalen Build direkt genutzt werden
kann.

### macOS App

```bash
bash build_app.sh                 # → "Savage Protracker Player.app" (inkl. Quick-Look-Appex)
```

`build_app.sh` kompiliert neben der App auch die Quick-Look-Extension
(`quicklook/`) und legt sie im App-Bundle unter `Contents/PlugIns/` ab.

Die App sucht beim Start nach einem `audio/`-Verzeichnis neben der Anwendung und lädt dort gefundene `.mod`-/`.s3m`-Dateien (oder `mod.*`-Dateien) automatisch in die Playlist. Diese Dateien sind nur lokale Testdaten und gehören nicht ins Git-Repository.

Für Release-Builds signiert `build_app.sh` automatisch mit der Developer-ID
`Developer ID Application: Daniel Mueller (9QSWKSR4NQ)`, sofern sie im
Schlüsselbund verfügbar ist. Lokale unsignierte Builds sind mit
`SIGN_APP=0 bash build_app.sh` möglich.

### DMG (für Releases)

```bash
bash build_dmg.sh                 # → build/Savage Protracker Player.dmg
bash build_dmg.sh --notarize      # DMG signieren, notarisieren und stapeln
```

Das DMG enthält ein Retina-kompatibles Hintergrundbild (1x/2x TIFF via `tiffutil`).
Für die Notarisierung wird ein Keychain-Profil erwartet, standardmäßig
`SavageProtrackerNotary`. Es kann einmalig interaktiv angelegt werden:

```bash
xcrun notarytool store-credentials SavageProtrackerNotary
```

### Tests

```bash
swift test
swift test --filter MultiFormatTests
node Tests/js/worklet-timing.mjs
```

Die Suite deckt Parser (alle MOD-Varianten, S3M, synthetische und echte Dateien),
DSP-Timing, Sequenzierung, den Offline-WAV-Renderer des Quick-Look-Plugins und
die Parität zwischen Swift- und Browser-DSP ab.

---

## GitHub-Veröffentlichung

```bash
bash publish_github.sh --dry-run --release
bash publish_github.sh --release
```

Das Veröffentlichungsskript setzt `origin` auf
`https://github.com/DanielMuellerIR/savage_protracker.git`, blockt
versehentlich getrackte Audio- und Release-Artefakte und erzeugt bei
`--release` den passenden GitHub-Release-Eintrag mit DMG-Asset.

## Herkunft

Die ProTracker-Engine entstand zuerst im Schwesterprojekt
[FraktalLab](https://github.com/DanielMuellerIR/FraktalLab) als eigene
TypeScript-/AudioWorklet-Implementierung (`AmiModPanel` / `utils/modplayer`,
kein `libopenmpt`). Für dieses Projekt wurde sie als eigenständiger
Single-File-HTML-Player herausgelöst und zusätzlich als native Swift-Engine mit
`AVAudioSourceNode` portiert. Mitgelieferte MOD-Dateien sind nicht Teil dieses
Repositories.

## KI-Unterstützung

Bei Umsetzung, Portierung und Fehlersuche wurde KI-gestütztes Pair-Programming
als Werkzeug genutzt. Autor und Maintainer ist Daniel Müller.

## Lizenz

**MIT-Lizenz** — siehe [LICENSE](LICENSE).
