Savage Mod Player 1.5.46 ergänzt native Linux-Audiowiedergabe und härtet Parser,
Rendering, Kommandozeilen-Streaming und Quick-Look-Cache gegen fehlerhafte oder
mehrdeutige Eingaben.

## Linux und Kommandozeilen-Wiedergabe

- Die plattformneutrale Replay-Engine baut und testet jetzt aus denselben
  Swift-Quellen unter macOS und Linux.
- `savage-cli --play` gibt über ALSA aus und nutzt dieselbe Render-Engine wie
  macOS-App, Offline-Renderer und Quick-Look-Erweiterung.
- `--stdout` streamt begrenzte PCM-Blöcke sofort, statt vor dem ersten Sample
  einen vollständigen Song samt WAV-Datei zu puffern.
- Dauer- und Samplerate-Argumente lehnen nicht-endliche oder außerhalb der
  Grenzen liegende Werte mit kontrolliertem Exit-Code ab. Unvereinbare
  Ausgabeoptionen scheitern vor Parsing oder Rendering.
- Ein verpflichtender Ubuntu-CI-Job baut und testet Release-Core und CLI mit
  ihren ALSA- und Archivabhängigkeiten.

## Parser- und Wiedergabekorrektheit

- XM- und S3M-Dimensionen, Pattern-Grids, Instrumente, Samples und kumulierte
  PCM-Größen werden vor der Allokation geprüft. Kleine präparierte Dateien
  können keine mehrere Gigabyte großen Parserstrukturen mehr anfordern.
- FastTracker-II-Dateien beachten jetzt den Header-Modus für lineare oder
  Amiga-Frequenztabellen einschließlich der passenden Perioden- und
  Slide-Semantik.
- Der Replay-Kern wurde von AVFoundation und Combine getrennt, ohne eine zweite
  Wiedergabeimplementierung zu schaffen: Live-, Stream-, Offline- und
  Quick-Look-Rendering teilen weiterhin dieselbe Engine.
- Durch den Port sichtbar gewordene Linux-spezifische Kompilier- und
  Sequenzierungsfehler wurden korrigiert und mit plattformübergreifenden Tests
  abgesichert.

## Quick Look und Cache-Zuverlässigkeit

- Vorschau-Cache-Schlüssel enthalten jetzt die kanonische Dateiidentität und
  die Änderungszeit mit Subsekundenauflösung. Gleiche Basisnamen in
  verschiedenen Ordnern und schnelle In-place-Ersetzungen verwenden nicht mehr
  versehentlich die falsche Audiovorschau.
- Quick Look rendert weiterhin höchstens 60 Sekunden und zeigt Parserfehler als
  endliche Textvorschau.

## Verifikation und bekannte Grenzen

- Die optimierte vollständige Swift-Suite, gezielte Parser-/Render-/Cache-Tests,
  JavaScript-zu-Swift-MOD-Timingparität, macOS-App-/Quick-Look-Builds und der
  verpflichtende Linux-CI-Job decken das Release ab.
- MPTM, VST-/AudioUnit-Plugin-Wiedergabe und externe MIDI-Ausgabe bleiben
  außerhalb der nativen Engine. Der HTML5-Player bleibt bewusst auf klassische
  vierkanalige ProTracker-MOD-Dateien begrenzt.
- Das DMG ist mit Developer ID signiert, von Apple notarisiert und enthält App
  und Quick-Look-Erweiterung. Moduldateien werden nicht mitgeliefert.
