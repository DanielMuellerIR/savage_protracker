Die macOS-App spielt jetzt **Impulse-Tracker-Module (`.it`)** im Sample- und Instrument-Modus — das fünfte unterstützte Tracker-Format nach ProTracker MOD, Soundtracker, ScreamTracker 3 und FastTracker II. Die neue Engine deckt native IT-2.14-/2.15-Wiedergabe vom Parsen bis zum Echtzeit-Audio ab, einschließlich CLI-Rendering, Drag & Drop und Quick Look, und meldet OpenMPT-spezifische Fähigkeiten strukturiert.

## Neu

- **Impulse-Tracker-Unterstützung (`.it`)**: bis zu 64 logische Kanäle, ein vorallozierter 256-Voice-NNA-Pool, NNA/DCT/DCA, 120-Noten-Sample-Maps, Hüllkurven, Fadeout, Sustain-Loops, Stereo-Samples, Surround, Sample-Vibrato, Pitch-Pan, Volume-/Pan-Swing und resonante Filter pro Stimme.
- **IT-2.14-/2.15-Samples**: unkomprimiertes und komprimiertes 8-/16-Bit-PCM in Mono oder Stereo, signed/unsigned- und Delta-Varianten, Vorwärts- und Ping-Pong-Loops sowie separate Sustain-Loops.
- **IT-Effektsemantik**: Effekt- und Volume-Column-Memory, `Old Effects`, `Compatible Gxx`, Pattern-/Row-Delays und -Loops, Tempo-/Global-/Kanallautstärke, Retrigger, Tremor, Vibrato, Panbrello und gängige Filter-Makros.
- **Strukturierte OpenMPT-Capability-Analyse**: `cwtv` identifiziert den erzeugenden Tracker, `cmwt` steuert die Formatkompatibilität, vollständige OpenMPT-Versionen kommen aus ihren eigenen Erweiterungsfeldern. XTPM-/STPM-Chunks, alte ModPlug-Chunks, MIDI-/Plugin-Routing und die aktuellen OpenMPT-`PlayBehaviour`-Bits werden an ihren strukturellen Grenzen geparst; bekannte Kanal-, Timing-, Mix-, Preamp-, Restart-, Filter- und PCM-Kompatibilitätswerte werden angewandt, einschließlich der klassischen, alternativen und modernen Tempo-Modi sowie erweiterter IT-Patterns von 1 bis 1.024 Zeilen.
- **Präzise Warnungen**: Kompatibilitätswarnungen erscheinen nur, wenn eine Einschränkung im tatsächlich abgespielten Order-Pfad erreicht wird. Inaktive MIDI-Flags, Standard-Makros, unbenutzte Plugin-Definitionen und Metadaten bleiben still; genutzte externe Routen benennen Instrument, Kanal oder Plugin-Slot.
- **Öffentliche Integration**: `.it` funktioniert im Loader, Playlist-Scanner, Dateidialog, per Drag & Drop, über Finder-„Öffnen mit", in `savage-cli` und in der mitgelieferten Quick-Look-Extension. `savage-cli --info` meldet Tracker-Identität, Erweiterungs-Chunks, `PlayBehaviour`-Zustand und konkrete Capability-Ergebnisse.

## Verbessert

- Tracker-Grid und Oszilloskope zeigen nur die tatsächlich im Song belegten Kanäle unter ihrer ursprünglichen Kanalnummer; der Header zeigt die genutzte Kanalzahl vor dem BPM.
- Quick Look rendert und cached eine schnelle 60-Sekunden-Audiovorschau; nicht unterstützte Dateien zeigen eine lesbare Fehlermeldung statt eines endlosen Ladeindikators.
- PAL/NTSC ist neben das Master-Oszilloskop gewandert und nur noch für Paula-basierte MOD-Formate verfügbar.
- Songdauer und Offline-Rendering nutzen dieselbe Jump-/Loop-/Delay-/Tempo-bewusste Sequencer-Probe; angezeigte Zeit und gerenderte Länge entsprechen dem tatsächlichen Wiedergabepfad.

## Verifikation

- Die vollständige Swift-Testsuite, gezielte Filter-/NNA-/Stereo-Fixtures, ein 64-Kanal-/256-Voice-Release-Stresstest, die JS↔Swift-MOD-Parität, der signierte App-Build und die Quick-Look-Extension sind grün.
- Die Wiedergabe wurde gegen die eingefrorene `openmpt123`-/libopenmpt-Referenz verglichen, für Filter- und Kompatibilitätsdetails zusätzlich gegen die Quelltexte von OpenMPT und Schism Tracker.

## Bekannte Grenzen

- Savage Mod Player bleibt eine native PCM-Tracker-Engine: MPTM, VST-/AudioUnit-Plugin-Wiedergabe und externe MIDI-Ausgabe werden nicht unterstützt und warnen nur bei tatsächlicher Nutzung.
- Eingebettete MIDI-Makros sind auf gängige Cutoff-/Resonanz-Filter-Makros beschränkt.
- Veraltetes OpenMPT-Swing vor 1.17, die abgelöste alte Loop-/Jump-Regel, das unpräzise Legacy-Ping-Pong-Überschwingen und proprietäre Envelope-Release-Nodes bleiben featurespezifische Kompatibilitätsgrenzen.
- Der HTML5-Player bleibt bewusst auf klassische 4-Kanal-ProTracker-MODs beschränkt.

## Hinweise

- Das DMG ist signiert und notarisiert und enthält App und Quick-Look-Extension; Moduldateien sind nicht enthalten.
