This release turns the flat playlist into a real folder tree, adds archive support, and makes the startup folder configurable.

## New

- **Hierarchical playlist**: folders (and their subfolders) now appear as a collapsible tree instead of a flat list. All folders start collapsed; the path to the currently playing track expands automatically, and any folder can be toggled by clicking. Track navigation, end-of-song advance, and shuffle work across all folders, so playback never stops at a folder boundary. While a search filter is active, matches are shown as a flat list.
- **Zip and 7-Zip archives**: dropped archives — or archives found inside the startup folder — are treated exactly like folders in the playlist (shown without the file extension). Extraction happens invisibly into a temporary directory, never next to the source files, and is cleaned up when the app quits (plus on launch, as a safety net after crashes). Corrupt archives are skipped silently.
- **Configurable autoplay folder**: a new native Settings window (app menu > Settings, Cmd+,) lets you pick the folder the playlist is filled from at startup. If no folder is set, the app falls back to the previous behavior and looks for an `audio/` directory next to the app or the working directory.

## Notes

- The HTML5 single-file player intentionally stays a compact 4-channel ProTracker player; the playlist tree and archive support are features of the macOS app.
- The DMG contains the app including the Quick Look plugin; no module files are bundled. Songs are loaded via drag & drop or from the configured autoplay folder.
