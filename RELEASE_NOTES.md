Savage Protracker Player is now **Savage Mod Player**. Since the app plays ProTracker MOD, multichannel MOD, Soundtracker, and ScreamTracker 3 modules — with more formats planned — the old name no longer covered what it does. This release contains the rename and no functional changes beyond it.

## Changed

- **New name everywhere**: the app bundle is now `Savage Mod Player.app`, the window title, About panel, and DMG follow suit. The HTML5 player file is now `savage-mod-player.html`.
- **Repository renamed** to `savage_modplayer`. GitHub redirects all old links (web, git remotes, releases) to the new address automatically.
- **New bundle identifier** (`com.viben.SavageModPlayer`): macOS treats this as a new app, so preferences — including the autoplay folder — start fresh. Set the autoplay folder once again under Settings (Cmd+,). If you still have the old app in your Applications folder, delete it to avoid two Quick Look providers.

## Notes

- Functionally identical to 1.4.0 (hierarchical playlist, Zip/7-Zip archives, configurable autoplay folder).
- The DMG contains the app including the Quick Look plugin; no module files are bundled.
