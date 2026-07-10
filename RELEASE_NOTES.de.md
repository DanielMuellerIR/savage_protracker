Die macOS-App spielt jetzt **FastTracker-II-Module (`.xm`)** — das vierte unterstützte Tracker-Format nach ProTracker-MOD, Soundtracker und ScreamTracker 3. Neben dem neuen Format wurde die CPU-Last bei der Wiedergabe etwa halbiert und eine Reihe von Wiedergabe- und UI-Fehlern behoben.

## Neu

- **FastTracker II (`.xm`)**: eine eigene XM-Engine mit Multi-Sample-Instrumenten und Keymaps, Lautstärke-/Panning-Hüllkurven (Sustain und Loop), Key-Off mit Volume-Fadeout, Auto-Vibrato, Ping-Pong-Sample-Loops, linearer Frequenztabelle und dem XM-Effektsatz inklusive Volume-Column und Per-Kanal-Effekt-Memory. Die Wiedergabe wurde per A/B-Vergleich gegen libopenmpt mit echten Modulen (8–32 Kanäle) verifiziert.
- **Quick Look, Drag & Drop und Datei-Dialog** akzeptieren `.xm` überall dort, wo `.mod`/`.s3m` bereits funktionierten; die Leertaste auf einer `.xm`-Datei im Finder zeigt die abspielbare Audio-Vorschau.
- **Zeilengenaues Springen**: −10 s/+10 s-Transport-Buttons, −15 s/+30 s-Buttons neben dem Positions-Slider, und ein Klick auf eine Zeile im Pattern-Grid springt direkt dorthin.
- **Wiedergabe per Kommandozeile**: `SavageModPlayer <song.xm|ordner>` (oder „Öffnen mit" im Finder) lädt und spielt sofort — praktisch für Skripte und automatisierte Prüfungen.

## Verbessert

- **CPU-Last bei der Wiedergabe etwa halbiert** (z. B. 32-Kanal-XM von 127 % auf 63 %, 4-Kanal-MOD von 65 % auf 37 %): Pattern-Grid und Kanal-Oszilloskope zeichnen je als ein einziger Canvas, und der UI-Zustand wurde so aufgeteilt, dass Timer nicht mehr das ganze Fenster neu rendern.
- **Ein-Fenster-Verhalten**: Das Öffnen von Dateien erzeugt kein zweites Fenster mehr.
- **Playlist-Lesbarkeit**: proportionale Schrift und ziehbare Seitenleisten-Trenner.

## Behoben

- Eine auf den Player gezogene Datei wurde nicht geöffnet, wenn der Pfad Sonderzeichen enthielt (URL-Dekodierung).
- Beim Springen konnten Noten hängen bleiben; Kanäle werden über den Sprung hinweg stummgeschaltet.
- Zeit- und Positionsanzeige drifteten bei Modulen mit variablen Pattern-Längen.
- Das Entmuten eines Kanals stellt wieder die letzte hörbare Lautstärke her statt voller Lautstärke.
- Module mit nur einer Song-Position brachten den Positions-Slider zum Absturz.

## Hinweise

- Das DMG ist signiert und notarisiert und enthält die App inklusive Quick-Look-Plugin; es sind keine Modul-Dateien enthalten.
- Bekannte Einschränkung: Die seltenen XM-Module im Amiga-Frequenzmodus werden vorerst über die lineare Frequenztabelle angenähert.
