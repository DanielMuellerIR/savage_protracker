# Savage Protracker Player 1.3.0

The macOS app grows from a 4-channel ProTracker player into a multi-format tracker player — and previews modules right in Finder.

## New

- **Multichannel MOD support**: `6CHN`/`8CHN`, generic `xCHN`/`xxCH` up to 32 channels, `CD81`/`OKTA`, and `FLT8` (StarTrekker pattern pairs).
- **15-sample Soundtracker**: original Ultimate Soundtracker modules without a signature are detected via structural heuristics.
- **ScreamTracker 3 (`.s3m`)**: packed patterns, volume column (also shown in the tracker grid), per-channel panning, C2Spd-based ST3 period model, and S3M effects including fine/extra-fine slides with effect memory, tremor, fine vibrato, global volume, and speed/tempo commands.
- **Quick Look plugin**: press the space bar on a `.mod`/`.s3m` file in Finder to get a playable audio preview (native macOS player with play and scrubbing). The plugin ships inside the app bundle — install the app, launch it once, done. Note: if VLC is installed, macOS intercepts `.mod` (not `.s3m`) previews with its built-in media preview; this is a Quick Look system limitation.
- **Dynamic UI**: tracker grid, VU meters, scopes, and mute/solo adapt to the module's channel count (horizontal scrolling from 5 channels up).

## Notes

- The HTML5 single-file player intentionally stays a compact 4-channel ProTracker player.
- The DMG contains the app including the Quick Look plugin; no module files are bundled. Songs are loaded via drag & drop or from a local `audio/` folder.
