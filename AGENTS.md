# Savage Mod Player — Projektregeln

## Typ und Zweck

- **Typ:** native macOS-GUI-App mit SwiftUI/AVAudioEngine, Quick-Look-Extension,
  plattformübergreifendes headless CLI (`savage-cli`, macOS + Linux) und kompakte
  HTML5-Variante.
- **Zweck:** Tracker-Modul-Player für MOD, S3M, XM und IT. Die native Variante
  unterstützt alle vier Formate; der Single-File-Browserplayer bleibt bewusst
  auf klassische 4-Kanal-ProTracker-MODs begrenzt.
- **Linux ist Ist-Zustand, nicht Option** (seit 1.5.44/1.5.45): `SavageModPlayerCore`
  und `savage-cli` bauen, testen und spielen unter Linux; App und Quick Look sind
  macOS-only und werden dort per `#if os(macOS)` aus `Package.swift` ausgeblendet.
  Details und Grenzen: [Linux-Plan](tasks/2026-07-05-linux-port/plan.md).
- `SavageModPlayerCore` ist in `Package.swift` iOS-tauglich deklariert, aber ein
  iOS-App-Target oder verifizierter iOS-Buildpfad existiert nicht. iOS ist Option,
  kein Ist-Zustand.
- Die aktuelle Produktversion steht ausschließlich in [VERSION](VERSION).

## Architektur und harte Invarianten

- `Sources/SavageModPlayerCore/Parser/`: strikte, längengeführte Parser und
  `ModuleLoader` als inhaltsbasierter Dispatch. Formatfremde Daten und strukturelle
  Korruption ablehnen; nur dokumentierte, sicher clamp-/ignorierbare Realweltwerte
  tolerant behandeln. Keine pauschale „OpenMPT akzeptiert es“-Toleranz.
- `Sources/SavageModPlayerCore/DSP/`: gemeinsamer Live-/Probe-/Offline-Renderpfad.
  Im Echtzeit-Renderblock niemals Heap-Allokationen, Locks oder dynamische
  Objective-C-Aufrufe einführen. Kanal-/Voice-Puffer bleiben voralloziert; IT
  trennt bis zu 64 Pattern-Kanäle von 256 Voices.
- **`RenderEngine.swift` ist plattformneutral und muss es bleiben.** Kein
  AVFoundation, kein Combine, keine CoreAudio-Typen (`AudioBufferList`, `ObjCBool`,
  `OSStatus`) — sonst bricht der Linux-Build. Der Renderblock hat die neutrale
  Signatur `ModuleRenderBlock`; CoreAudio lebt ausschließlich im Adapter
  `ModPlayerCoordinator.makeSourceNodeRenderBlock`. `ModPlayerCoordinator` und
  `VisualizerState` sind hinter `canImport(AVFoundation)`/`canImport(Combine)`
  geguardet.
- `Sources/SavageModPlayerCore/Audio/`: Ausgabeschicht (`PCMSink` & Co.), aus
  `vicious_sidplayer` übernommene Kopie plus eigenes `ModulePCMSource`. Frei von
  Format-Wissen halten. Änderungen dort mit dem SID-Repo abgleichen — eine
  Extraktion in ein gemeinsames Paket lohnt erst nach Bewährung in beiden.
- **Eine Engine, mehrere Ausgaben.** `ModuleRenderer` (Offline/Quick Look),
  `ModulePCMSource` (Echtzeit-CLI) und `ModPlayerCoordinator` (App) holen alle aus
  `RenderEngine.createRenderBlock`. Ein Fix darf sie nicht auseinanderlaufen
  lassen; `ModulePCMSourceTests` deckt die Gleichheit von Echtzeit- und
  Offlinepfad sample-genau ab.
- `modplayer.js` und `mod-player-worklet.js` bilden Parser/DSP des HTML5-Players;
  `src/` enthält UI-Quellen, `build.py` erzeugt die getrackte
  `savage-mod-player.html`. Generiertes HTML nach Web-/Versionsänderungen neu bauen
  und den Diff prüfen.
- Der gemeinsame 4-Kanal-MOD-DSP in Swift und JavaScript muss mathematisch
  konsistent bleiben. Nach einem Fix in einer Variante die andere prüfen und bei
  ausstehender Parität einen Eintrag in [tasks/backlog.md](tasks/backlog.md)
  anlegen, nicht in dieser Dauerdatei.
- `quicklook/PreviewProvider.swift` rendert höchstens 60 Sekunden WAV. Die Appex
  wird sandboxed und zuerst mit Entitlements signiert; danach die App ohne
  `--deep`. Parserfehler müssen eine endliche Textvorschau statt eines Hängers
  liefern.

## Sicherheit, Assets und Öffentlichkeit

- Das Repo ist veröffentlichbar. Keine privaten Hosts, Remotes, Kontakte,
  Assistentenformulierungen, lokalen Home-Pfade oder persönliche Fleet-Notizen in
  öffentliche Dateien übernehmen.
- Moduldateien unter `audio/`, lokale Referenz-WAVs und A/B-Berichte sind
  ungebundene Testdaten und bleiben aus Git. Für Regressionen synthetische,
  rechtlich unbedenkliche Fixtures bevorzugen. Vor GitHub den getrackten Stand
  erneut auf Audio-/Release-Artefakte und private Daten prüfen.
- Tests dürfen fehlende lokale Korpora sauber überspringen; ein grüner Skip ist
  kein Beleg für Realwelt-Kompatibilität. Bei Parser-/DSP-Änderungen vorhandene
  lokale Korpora zusätzlich prüfen, ohne sie zu committen.
- Veröffentlichung und Release-Erstellung sind externe Wirkungen. GitHub,
  Notarisierung oder `publish_github.sh` nur nach Daniels konkretem Auftrag;
  vorher den Workflow `github-publish` laden.

## Git, Version und Parallelität

- Vor Änderungen ausschließlich den privaten kanonischen Fleet-Remote aus den
  globalen Regeln fetchen und nur einen sicheren Stand verwenden. Automatische
  Commits/Pushes gehen ausschließlich dorthin; `origin`/GitHub bleiben ohne
  konkreten Auftrag unangetastet.
- Nur Scope-Pfade stagen. Fremdes WIP erhalten; keine destruktiven Git- oder
  Dateibefehle. Reine AGENTS-/CLAUDE-/Doku-Reorganisation erhöht die
  Produktversion nicht.
- Eine echte Produktänderung aktualisiert `VERSION`, die betroffene Nutzer- und
  Release-Doku sowie eingebettete Versionsartefakte. Danach gezielt testen,
  committen und ausschließlich zum privaten kanonischen Fleet-Remote pushen.
  Expected-Ausgaben nie still regenerieren.
- Gemeinsame Hotspots (`ModuleModels.swift`, `DSPChannel.swift`,
  `AudioCoordinator.swift`, Parser-/Sequencer-Kern, `ContentView.swift`,
  `build_app.sh`) nur seriell editieren. Nie zwei Writer im selben logischen Repo
  oder Worktree-Verbund; die abgeschlossene IT-Roadmap ist kein aktiver
  Parallelarbeitsvertrag.

## Änderung → Pflichtprüfung

Die vollständigen Befehle, Fixture-Regeln und Quick-Look-Fallen stehen in
[docs/testing.md](docs/testing.md). Mindestmatrix:

| Änderung | Pflichtprüfung |
|---|---|
| Swift allgemein | gezielter Test, vollständiges `swift test`, `git diff --check` |
| App/Core/Quick Look | zusätzlich `bash build_app.sh` |
| `RenderEngine`, `Audio/`, `Package.swift`, Parser-Kern | zusätzlich Linux-Lauf (Docker, siehe Linux-Plan) — der Build dort ist der einzige Beleg für Plattformneutralität |
| Audio-Renderpfad angefasst | `savage-cli`-WAVs über den lokalen MOD-Korpus byteidentisch zu vorher (Baseline vor der Änderung erzeugen) |
| gemeinsamer MOD-DSP | `DSPChannelTimingTests`, Sequencer-Tests und `node Tests/js/worklet-timing.mjs` |
| MOD/S3M/XM/IT-Parser oder -DSP | passende Format-Suite plus lokale Realweltdateien, falls vorhanden |
| Webquelle/Version | `python3 build.py`, generierten HTML-Diff prüfen, Browser-Smoke bei UI-Verhalten |
| Quick Look | Build/Signatur/PluginKit headless; Finder-Leertaste als manueller Endtest |
| Release | volle Suite, App-/Appex-Signatur, DMG/Notary nur bei Auftrag, EN/DE-Doku konsistent |

GUI-Fokus erst nach Zustimmung. Ein App- oder Finder-Handtest ersetzt nie die
headless Gates; nach einem sichtbaren Test die Test-App wieder ausblenden.

## Progressive Detailregeln und bestätigte Fallen

Vor einer betroffenen Änderung gezielt [docs/testing.md](docs/testing.md) lesen:

- Notary-Keychain-Profile sind pro Mac und müssen vor Nutzung verifiziert werden;
  konkrete Profilnamen bleiben in privater Setup-Doku.
- `RELEASE_NOTES.md` beginnt ohne eigene H1, weil `publish_github.sh` den
  GitHub-Release-Titel separat setzt.
- VLC kann `.mod` als `org.videolan.mod` exportieren; dann nimmt Quick Look den
  System-Medienpfad und fragt die Extension nicht an. `.s3m` eignet sich als
  belastbarer Extension-Smoke.
- Ein Rebuild kann die lokale Appex-Registrierung verlieren; mit `pluginkit`
  registrieren und prüfen. `qlmanage -p -o` testet moderne Preview-Extensions
  nicht zuverlässig.
- Audio benötigt `QLPreviewReply(fileURL:)`; eine WAV-Datenreply zeigt nur die
  generische Infokarte.

Die IT-Implementierung M0–M10 ist abgeschlossen. Dauerhafte Semantik und
Capability-Grenzen stehen in
[tasks/2026-07-10-it-support/decisions.md](tasks/2026-07-10-it-support/decisions.md)
und [openmpt-capability-audit.md](tasks/2026-07-10-it-support/openmpt-capability-audit.md).
Historische Start-/Branch-Anweisungen aus `handoff.md` und `state.md` sind
geschlossen und dürfen nicht reaktiviert werden.

## Aktive nächste Schritte

Nur [tasks/backlog.md](tasks/backlog.md) ist die aktive Projektliste. Dort stehen
unter anderem die offene Release-Notes-Entscheidung, der GUI-Dateiargument-Smoke,
der Rest des Linux-Ports (Tastatursteuerung, Playlist, Dropout-Nachweis),
optionale Visualizer-/Churn-Arbeit und seltene XM-Feinheiten. Erledigte Release-,
UI-, Audit- und IT-Chronik liegt in Release Notes, Tasks und
[docs/AGENTS-history-through-2026-07-12.md](docs/AGENTS-history-through-2026-07-12.md).

## Verzeichnisstruktur

- [CLAUDE.md](CLAUDE.md) — dünne Claude-Brücke zu diesem Kanon.
- [README.md](README.md) und [README.de.md](README.de.md) — Produkt, Bedienung,
  Build und CLI; [RELEASE_NOTES.md](RELEASE_NOTES.md) und
  [RELEASE_NOTES.de.md](RELEASE_NOTES.de.md) — aktuelle Release-Historie.
- [docs/testing.md](docs/testing.md) — Test-/Build-/Quick-Look-Runbook;
  `docs/screenshot-dark.png` ist ein Produktasset, keine Regelquelle.
- [tasks/backlog.md](tasks/backlog.md) — echte offene Arbeit;
  [Linux-Plan](tasks/2026-07-05-linux-port/plan.md) und
  [IT-Plan](tasks/2026-07-10-it-support/plan.md) — optionale bzw. abgeschlossene
  größere Vorhaben.
- [docs/AGENTS-history-through-2026-07-12.md](docs/AGENTS-history-through-2026-07-12.md)
  — ausgelagerte erledigte AGENTS-Chronik. `archive/p_modplayer_*` ist ein
  gitignorierter lokaler Sonderbestand und keine aktive Regelquelle.
- `Sources/SavageModPlayerCore/` — Parser, `DSP/` (Renderkern, plattformneutral),
  `Audio/` (Ausgabeschicht/PCMSink), `Playlist/`; `Sources/CALSA/` — Systemmodul
  für ALSA (nur Linux); `Sources/SavageCLI/` — `savage-cli` (macOS + Linux).
- `Sources/` und `Tests/` — native Produkte und Tests; `quicklook/` — Extension;
  `src/`, `modplayer.js`, `mod-player-worklet.js` und
  `savage-mod-player.html` — Webquelle und generiertes Single-File-Produkt.
