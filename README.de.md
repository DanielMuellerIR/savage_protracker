<p align="center">
  <img src="src/AppIcon.png" width="128" alt="Savage Mod Player Icon">
</p>

<h1 align="center">Savage Mod Player</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Amiga-/Tracker-Modul-Player als Single-File-HTML5-Version und native SwiftUI-macOS-App mit Quick-Look-Plugin.</strong>
</p>

Ein plattformübergreifender, eigenständiger Tracker-Modul-Player in zwei Varianten:

1. **HTML5 (`savage-mod-player.html`)** — Eine einzelne HTML-Datei (unter 50 KB), die ohne Webserver direkt per Doppelklick aus dem Dateisystem funktioniert. Spielt klassische 4-Kanal-ProTracker-MODs.
2. **Native macOS App (`Savage Mod Player.app`)** — SwiftUI-Desktop-Anwendung mit `AVAudioEngine`, `AVAudioSourceNode`, echten Echtzeit-Oszilloskopen und Pegel-Metern. Spielt zusätzlich Multichannel-MODs (6/8/… Kanäle, u. a. `6CHN`/`8CHN`/`FLT8`), 15-Sample-Soundtracker-Module und **ScreamTracker 3 (`.s3m`)** — und bringt ein **Quick-Look-Plugin** mit: Leertaste auf einer `.mod`/`.s3m` im Finder öffnet eine abspielbare Audio-Vorschau.

Beide Varianten enthalten standardmäßig keine Moduldateien. Musikstücke werden per Drag & Drop oder Datei-Dialog geladen.

<p align="center">
  <img src="docs/screenshot-dark.png" width="900" alt="Savage Mod Player (Dark Mode) spielt ein 16-Kanal-ScreamTracker-3-Modul">
</p>

---

## Download

Fertige Builds der macOS-App stehen als notarisierte DMGs auf der [Releases-Seite](https://github.com/DanielMuellerIR/savage_modplayer/releases) bereit. DMG herunterladen, öffnen und die App in den Programme-Ordner ziehen.

Der HTML5-Player benötigt keinen Download über die Releases hinaus: Die Datei `savage-mod-player.html` lässt sich direkt im Browser öffnen.

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
- **Drag & Drop**: Einzelne `.mod`-/`.s3m`-Dateien, ganze Ordner (rekursiv) oder Zip-/7-Zip-Archive können auf den Player gezogen werden.
- **Automatische Playlist**: Ein konfigurierbarer Autoplay-Ordner (macOS-App: Einstellungen, Cmd+,) wird beim Start gescannt und als Playlist geladen; ohne Konfiguration wird ein `audio/`-Unterordner neben dem Player bzw. der App verwendet.
- **Hierarchische Playlist**: Ordner und Archive erscheinen als auf- und zuklappbarer Baum. Ordner starten zugeklappt, der Pfad zum laufenden Titel klappt automatisch auf, und Wiedergabe wie Shuffle laufen über alle Ordner hinweg.
- **Archive wie Ordner (macOS-App)**: Zip- und 7-Zip-Archive werden unsichtbar in ein temporäres Verzeichnis entpackt (aufgeräumt beim Beenden) und in der Playlist wie normale Ordner angezeigt.
- **Playlist-Bedienung**: Einzelklick auf einen Playlist-Eintrag lädt und startet den Titel direkt. Nach dem Songende kann die Playlist automatisch weiterlaufen.
- **Echtzeit-Oszilloskope**:
  - Ein echtes Stereo-Master-Mischungs-Oszilloskop direkt aus dem Audio-Renderpfad.
  - Separate Spur-Oszilloskope für jeden Kanal (dynamische Kanalzahl), die die tatsächlichen Schwingungsformen direkt aus dem Synthesizer-Render-Block visualisieren.
- **Multi-Theme**:
  - **Dark**: Graphit-/Schwarzpalette mit gutem Kontrast und gedämpften Akzentfarben.
  - **Light**: klassischer, heller macOS-naher Stil mit nüchternem Kontrast.
- **PAL- & NTSC-Taktfrequenzen**: Umschaltbare Paula-Taktung (3,546 MHz PAL vs. 3,580 MHz NTSC).
- **Lautstärke & Stereo-Separation**: Psychoakustische (quadratische) Lautstärkeskalierung und einstellbare Stereo-Separation (Bleed von 0% Mono bis 100% Hard-Panning).
- **Hi-Fi Resampling**: Umschaltbares linear-interpoliertes Sample-Playback für weicheren Sound (deaktivierbar für originalen 8-Bit-Crunch).
- **WAV- & Stem-Export**: Export des gesamten Songs in eine Stereo-WAV-Datei sowie Export einzelner Instrumentensamples als WAV.
- **Komplette Tastatursteuerung**: Leertaste für Play/Pause, Pfeiltasten links/rechts für Song-Positionen, Pfeiltasten oben/unten für Song-Wechsel in der Playlist.

---

## Bedienelemente & Anzeigen erklärt

Die Transport-Tasten erklären sich von selbst, doch die tracker-typischen Anzeigen und Schalter tragen ein Stück Amiga-Geschichte in sich. Jeder Punkt hier ist in der App auch als **Tooltip** hinterlegt — einfach mit dem Mauszeiger auf einem Bedienelement verweilen, bis die Erklärung erscheint. Weil Tooltips ein paar Sekunden brauchen und leicht zu übersehen sind, sind sie hier zusätzlich gesammelt.

**Kopfzeilen-Anzeigen**

- **BPM** (Beats per Minute): Wiedergabe-Tempo. Der Amiga-Standard ist 125. Mit −/+ veränderbar; ein Song kann sein Tempo per Effekt auch selbst umstellen. Bei Songwechsel wird der Header-Wert des neuen Moduls gesetzt.
- **SPD** (Speed): Ticks pro Pattern-Zeile (Amiga-Standard 6). Kleiner = die Zeilen laufen schneller durch, größer = langsamer. Zusammen mit BPM ergibt das die effektive Geschwindigkeit.
- **PAT** (Pattern-Position): aktuelles Pattern und Gesamtzahl in der Abspielreihenfolge des Songs. Ein Pattern ist ein Notenblock (meist 64 Zeilen); der Song spielt sie in dieser Reihenfolge ab.

**Taktfrequenz**

- **PAL** (3,546 MHz Paula-Takt): wie bei europäischen Amigas — die Referenz-Tonhöhe und -Geschwindigkeit der meisten Module.
- **NTSC** (3,580 MHz Paula-Takt): wie bei US-Amigas — Module klingen minimal höher und laufen etwas schneller als mit PAL.

**Klang-Optionen**

- **LED-Filter**: der zuschaltbare Amiga-Tiefpass bei ~3,2 kHz, der die Höhen kappt — der dumpfere Originalklang, wie wenn am echten Amiga die Power-LED leuchtete.
- **Hi-Fi-Interpolation**: glättet die Samples beim Resampling (weicherer Klang). Ausgeschaltet klingt es wie die Original-Hardware — roher 8-Bit-Sound mit hörbarem Aliasing.
- **Stereo-Separation**: 100 % = hartes Amiga-Panning (Kanäle ganz links/rechts), 0 % = Mono. Dazwischen wird Übersprechen beigemischt, das Kopfhörer-Ermüdung vermeidet. Am deutlichsten mit Kopfhörern hörbar; über Laptop-Lautsprecher kaum.
- **Loop-Modus**: was nach dem Songende passiert — Playlist fortsetzen, den Song wiederholen oder stoppen.

**Transport & Navigation**

- **Shuffle** (Zufallswiedergabe): eingeschaltet springen Titelwechsel und Songende zufällig durch die Playlist; ausgeschaltet spielt die Playlist der Reihe nach.
- **−15 s / +30 s**: zurück-/vorspringen (zeilengenau; bei Tempo-Wechseln näherungsweise).
- **Positions-Schieberegler**: eine Stelle im Song wählen — funktioniert auch bei gestoppter Wiedergabe: Play startet dann ab dieser Stelle.

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
| Parser | `modplayer.js` | `ModuleLoader`/`ModParser`/`S3MParser` (SavageModPlayerCore) |
| DSP / Mixer | `mod-player-worklet.js` (AudioWorklet) | `ModPlayerCoordinator.swift` (`AVAudioSourceNode`, bis 32 Kanäle) |
| UI | Vanilla JS + CSS Grid | SwiftUI + Canvas |
| Quick Look | — | `quicklook/PreviewProvider.swift` (Appex, WAV-Offline-Render) |

---

## Build

### HTML5

```bash
python3 build.py                  # → savage-mod-player.html (~48 KB)
python3 build.py --no-min         # ohne Minifizierung
```

Die erzeugte Single-File-Variante `savage-mod-player.html` ist Teil des
Repositories, damit der Player auch ohne lokalen Build direkt genutzt werden
kann.

### macOS App

```bash
bash build_app.sh                 # → "Savage Mod Player.app" (inkl. Quick-Look-Appex)
```

`build_app.sh` kompiliert neben der App auch die Quick-Look-Extension
(`quicklook/`) und legt sie im App-Bundle unter `Contents/PlugIns/` ab.

Die App befüllt die Playlist beim Start aus dem Autoplay-Ordner, der im Einstellungs-Fenster (Cmd+,) konfiguriert ist. Ist keiner gesetzt, sucht sie nach einem `audio/`-Verzeichnis neben der Anwendung und lädt dort gefundene `.mod`-/`.s3m`-Dateien (oder `mod.*`-Dateien) automatisch in die Playlist. Diese Dateien sind nur lokale Testdaten und gehören nicht ins Git-Repository.

Für Release-Builds signiert `build_app.sh` automatisch mit der Developer-ID
`Developer ID Application: Daniel Mueller (9QSWKSR4NQ)`, sofern sie im
Schlüsselbund verfügbar ist. Lokale unsignierte Builds sind mit
`SIGN_APP=0 bash build_app.sh` möglich.

### DMG (für Releases)

```bash
bash build_dmg.sh                 # → build/Savage Mod Player.dmg
bash build_dmg.sh --notarize      # DMG signieren, notarisieren und stapeln
```

Das DMG enthält ein Retina-kompatibles Hintergrundbild (1x/2x TIFF via `tiffutil`).
Für die Notarisierung wird ein Keychain-Profil erwartet, standardmäßig
`SavageModPlayerNotary`. Es kann einmalig interaktiv angelegt werden:

```bash
xcrun notarytool store-credentials SavageModPlayerNotary
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
`https://github.com/DanielMuellerIR/savage_modplayer.git`, blockt
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

## Lizenz

**WTFPL** (Do What The Fuck You Want To Public License) — siehe [LICENSE](LICENSE).
