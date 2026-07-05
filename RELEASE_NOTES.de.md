Dieses Release macht aus der flachen Playlist einen echten Ordnerbaum, bringt Archiv-Unterstützung und macht den Start-Ordner konfigurierbar.

## Neu

- **Hierarchische Playlist**: Ordner (und ihre Unterordner) erscheinen jetzt als auf- und zuklappbarer Baum statt als flache Liste. Alle Ordner starten zugeklappt; der Pfad zum gerade laufenden Titel klappt automatisch auf, per Klick lässt sich jeder Ordner öffnen und schließen. Titelwechsel, Weiterschalten am Songende und Shuffle laufen über alle Ordner hinweg — die Wiedergabe stoppt nie an einer Ordnergrenze. Bei aktivem Suchfilter werden Treffer als flache Liste angezeigt.
- **Zip- und 7-Zip-Archive**: Gedroppte Archive — oder Archive im Start-Ordner — werden in der Playlist genau wie Ordner behandelt (angezeigt ohne Dateiendung). Entpackt wird unsichtbar in ein temporäres Verzeichnis, nie neben die Quelldateien; aufgeräumt wird beim Beenden der App (und zusätzlich beim Start, als Fallnetz nach Abstürzen). Defekte Archive werden still übersprungen.
- **Konfigurierbarer Autoplay-Ordner**: Ein neues natives Einstellungs-Fenster (App-Menü > Einstellungen, Cmd+,) erlaubt die Wahl des Ordners, aus dem die Playlist beim Start befüllt wird. Ohne gesetzten Ordner gilt das bisherige Verhalten: Die App sucht ein `audio/`-Verzeichnis neben der App bzw. dem Arbeitsverzeichnis.

## Hinweise

- Der HTML5-Einzeldatei-Player bleibt bewusst ein kompakter 4-Kanal-ProTracker-Player; Playlist-Baum und Archiv-Unterstützung sind Funktionen der macOS-App.
- Das DMG enthält die App inklusive Quick-Look-Plugin; es sind keine Modul-Dateien enthalten. Musik wird per Drag & Drop oder aus dem konfigurierten Autoplay-Ordner geladen.
