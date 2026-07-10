The macOS app now plays **FastTracker II modules (`.xm`)** — the fourth supported tracker format after ProTracker MOD, Soundtracker, and ScreamTracker 3. Alongside the new format, playback CPU usage was roughly halved and a number of playback and UI issues were fixed.

## Added

- **FastTracker II (`.xm`) support**: a dedicated XM engine with multi-sample instruments and keymaps, volume/panning envelopes (sustain and loop), key-off with volume fadeout, auto-vibrato, ping-pong sample loops, the linear frequency table, and the XM effect set including the volume column and per-channel effect memory. Playback was verified A/B against libopenmpt with real 8–32 channel modules.
- **Quick Look, drag & drop, and file dialog** accept `.xm` everywhere `.mod`/`.s3m` already worked; pressing the space bar on an `.xm` file in Finder shows the playable audio preview.
- **Row-accurate seeking**: −10 s/+10 s transport buttons, −15 s/+30 s buttons next to the position slider, and clicking a row in the pattern grid jumps straight to it.
- **Command-line playback**: `SavageModPlayer <song.xm|folder>` (or Finder's "Open with") loads and plays immediately — handy for scripts and automated checks.

## Improved

- **Playback CPU usage roughly halved** (e.g. a 32-channel XM dropped from 127 % to 63 %, a 4-channel MOD from 65 % to 37 %): the pattern grid and the per-channel scopes each render as a single canvas, and UI state was split so timers no longer re-render the whole window.
- **Single-window behavior**: opening files no longer spawns a second window.
- **Playlist readability**: proportional font and draggable sidebar splitters.

## Fixed

- Dropping a file onto the player failed to open it when the path contained special characters (URL decoding).
- Seeking could leave notes hanging; channels are now muted across the jump.
- Time and position display drifted on modules with variable pattern lengths.
- Unmuting a channel restores its last audible volume instead of full volume.
- Modules with a single song position crashed the position slider.

## Notes

- The DMG is signed and notarized and contains the app including the Quick Look plugin; no module files are bundled.
- Known limitation: the rare XM modules using Amiga frequency mode are approximated with the linear frequency table for now.
