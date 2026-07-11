## 1.5.25 — 2026-07-11

- Die Kopfzeile zeigt vor BPM die Anzahl der tatsächlich verwendeten Pattern-Kanäle.
- PAL/NTSC liegt jetzt neben dem Master-Oszilloskop und ist nur bei Paula-basierten MOD-Formaten verfügbar.
- Quick Look rendert und cached jetzt eine schnelle 60-Sekunden-Audiovorschau; nicht unterstützte Dateien zeigen einen lesbaren Fehler statt eines endlosen Ladeindikators.

Die macOS-App spielt jetzt **Impulse-Tracker-Module (`.it`)** im Sample- und Instrument-Modus. Die neue Engine deckt native IT-2.14-/2.15-Wiedergabe vom Parser über Echtzeit-Audio bis CLI-Rendering, Drag & Drop und Quick Look ab.

## Neu

- **Impulse Tracker (`.it`)**: bis zu 64 logische Kanäle, ein vorallozierter 256-Voice-NNA-Pool, NNA/DCT/DCA, 120er Sample-Maps, Hüllkurven, Fadeout, Sustain-Loops, Stereo-Samples, Surround, Sample-Vibrato, Pitch-Pan, Volume-/Pan-Swing und resonante Filter pro Voice.
- **IT-2.14-/2.15-Samples**: unkomprimiertes und komprimiertes 8-/16-Bit-Mono-/Stereo-PCM, Signed-/Unsigned- und Delta-Varianten, Forward-/Ping-Pong-Loops sowie getrennte Sustain-Loops.
- **IT-Effektsemantik**: Effekt- und Volume-Column-Memory, `Old Effects`, `Compatible Gxx`, Pattern-/Row-Delays und Loops, Tempo, Global-/Channel-Volume, Retrigger, Tremor, Vibrato, Panbrello und gebräuchliche Filtermakros.
- **Öffentliche Integration**: `.it` funktioniert im Loader, Playlist-Scanner, Datei-Dialog, Drag & Drop, Finder-„Öffnen mit“, in `savage-cli` und in der Quick-Look-Extension. Die App zeigt ein Impulse-Tracker-Format-Badge und rendert alle Pattern-Zeilen sowie bis zu 64 Kanäle.
- **Kompatibilitätsmeldungen**: nicht unterstütztes MIDI-/Plugin-Routing, eingeschränkte Custom-MIDI-Makros, neuere Tracker-Versionen und unbekannte MPTM-/IT-Erweiterungen erzeugen sichtbare, nicht-fatale Warnungen.

## Verifikation

- Die vollständige Swift-Suite, gezielte Filter-/NNA-/Stereo-Fixtures, der 64-Kanal-/256-Voice-Release-Stresstest, die JS↔Swift-MOD-Parität, der signierte App-Build und die Quick-Look-Extension sind grün.
- Die Wiedergabe wurde gegen die festgeschriebene `openmpt123`-/libopenmpt-Referenz und bei Filter-/Kompatibilitätsdetails zusätzlich gegen die OpenMPT- und Schism-Tracker-Implementierungen geprüft.

## Bekannte Einschränkungen

- MPTM, proprietäre OpenMPT-Erweiterungen, VST-/Plugin-Wiedergabe und externe MIDI-Ausgabe werden nicht unterstützt.
- Eingebettete MIDI-Makros sind auf gebräuchliche Cutoff-/Resonance-Filtermakros begrenzt.
- Pattern-Längen von 32 bis 200 Zeilen werden unterstützt; kürzere oder längere Erweiterungs-Patterns werden mit einem Parserfehler abgelehnt.
- Der HTML5-Player bleibt bewusst auf klassische 4-Kanal-ProTracker-MODs beschränkt.

## Hinweise

- Das DMG ist signiert und notarisiert und enthält App und Quick-Look-Extension; Moduldateien werden nicht mitgeliefert.
