# AGENTS.md — Savage Protracker Player

Diese Datei ist die zentrale Projektdokumentation. Sie beschreibt die Architektur, Konventionen und offene Todos für den **Savage Protracker Player**.

---

## Projektüberblick

Der **Savage Protracker Player** ist ein plattformübergreifender 4-Kanal-Amiga-ProTracker-MOD-Player. Er ist als direktes Gegenstück zum **Vicious SID Player** konzipiert und besteht aus zwei Implementierungen:
1. **HTML5-Variante**: Ein kompakter (unter 40 KB minifizierter) Single-File-Browser-Player (`savage-protracker-player.html`), der ohne Webserver direkt aus dem Dateisystem per Doppelklick gestartet werden kann.
2. **Swift-Variante**: Eine native, hochperformante macOS- & iOS-Anwendung (`Savage Protracker Player.app`), implementiert in SwiftUI und `AVAudioEngine`/`AVAudioSourceNode` für eine ressourcenschonende und latenzfreie Wiedergabe.

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
- **Parser (`SavageProtrackerPlayerCore/Parser/`)**: Reines Swift, parst `.mod`-Dateien in typsichere Werttypen (`struct`).
- **DSP / Synthesizer (`SavageProtrackerPlayerCore/DSP/`)**: Verwendet `AVAudioSourceNode` innerhalb von `AVAudioEngine`. Läuft direkt auf dem Core Audio Echtzeit-Thread.
  - *Wichtig*: Keine Heap-Alloziierungen, Sperren oder dynamische Objective-C-Aufrufe im Render-Block!
- **UI (`SavageProtrackerPlayerApp/UI/`)**: Deklaratives SwiftUI. Enthält zentrierende Tracker-Zeilen-Tabellen, Visualizer und CRT-Effekt-Filter.

---

## Aktuelle Todos (Release 1.2.2-dev)

- [x] **Todo 1**: Git-Repository initialisieren & Stammdateien anlegen (`VERSION`, `LICENSE`, `.gitignore`, `AGENTS.md`)
- [x] **Todo 2**: HTML5-Dateien verschieben & `build.py` anpassen (Ausgabe zu `savage-protracker-player.html`)
- [ ] **Todo 3**: Swift-Dateien verschieben & Paket- und Quelltext-Umbenennung zu `SavageProtrackerPlayer` durchführen
- [ ] **Todo 4**: macOS Hilfsskripte (`build_app.sh`, `build_dmg.sh`, `publish_github.sh`) integrieren
- [ ] **Todo 5**: Grafische Assets (`AppIcon.png` & `DmgBackground.png`) für App und DMG generieren
- [ ] **Todo 6**: Echtzeit-Oszilloskope im Swift-Player implementieren:
  - [ ] Master-Mix-Wellenform über `installTap` auf `audioEngine.mainMixerNode` abgreifen
  - [ ] Echte 4-Kanal-Audio-Wellenformen über safe Puffer im `AVAudioSourceNode` Render-Block mitschreiben
- [ ] **Todo 7**: Swift-UI-Layout anpassen & Performance-Fokussierung (flüssigeres Scrollen des Tracker-Grids)
- [ ] **Todo 8**: Builds verifizieren und `swift test` ausführen
- [ ] **Todo 9**: Ausführliche, ansprechende `README.md` im Stammverzeichnis anlegen (Gegenstück zu `vicious-sidplayer`)
