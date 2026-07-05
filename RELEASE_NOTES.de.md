Aus dem Savage Protracker Player wird der **Savage Mod Player**. Da die App ProTracker-MOD, Multichannel-MOD, Soundtracker und ScreamTracker 3 spielt — und weitere Formate geplant sind — deckte der alte Name nicht mehr ab, was sie kann. Dieses Release enthält die Umbenennung und darüber hinaus keine funktionalen Änderungen.

## Geändert

- **Neuer Name überall**: Das App-Bundle heißt jetzt `Savage Mod Player.app`; Fenstertitel, About-Panel und DMG ziehen mit. Der HTML5-Player heißt jetzt `savage-mod-player.html`.
- **Repository umbenannt** in `savage_modplayer`. GitHub leitet alle alten Links (Web, Git-Remotes, Releases) automatisch auf die neue Adresse um.
- **Neue Bundle-ID** (`com.viben.SavageModPlayer`): macOS behandelt die App dadurch als neue App, die Einstellungen — inklusive Autoplay-Ordner — beginnen leer. Den Autoplay-Ordner einmal neu unter Einstellungen (Cmd+,) setzen. Wer die alte App noch im Programme-Ordner hat, sollte sie löschen, damit nicht zwei Quick-Look-Provider registriert sind.

## Hinweise

- Funktional identisch mit 1.4.0 (hierarchische Playlist, Zip-/7-Zip-Archive, konfigurierbarer Autoplay-Ordner).
- Das DMG enthält die App inklusive Quick-Look-Plugin; es sind keine Modul-Dateien enthalten.
