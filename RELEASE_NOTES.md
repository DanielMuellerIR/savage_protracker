## 1.5.25 — 2026-07-11

- The header now shows the number of pattern channels actually used by the song, before BPM.
- PAL/NTSC moved next to the master oscilloscope and is available only for Paula-based MOD formats.
- Quick Look now renders and caches a fast 60-second audio preview; unsupported files show a readable error instead of an endless loading indicator.

The macOS app now plays **Impulse Tracker modules (`.it`)** in sample and instrument mode. The new engine covers native IT 2.14/2.15 playback from parsing through real-time audio, CLI rendering, drag & drop, and Quick Look.

## Added

- **Impulse Tracker (`.it`) support**: up to 64 logical channels, a preallocated 256-voice NNA pool, NNA/DCT/DCA, 120-note sample maps, envelopes, fadeout, sustain loops, stereo samples, surround, sample vibrato, pitch-pan, volume/pan swing, and resonant per-voice filters.
- **IT 2.14/2.15 samples**: uncompressed and compressed 8-/16-bit mono or stereo PCM, signed/unsigned and delta variants, forward and ping-pong loops, and separate sustain loops.
- **IT effect semantics**: effect and volume-column memory, `Old Effects`, `Compatible Gxx`, pattern/row delays and loops, tempo/global/channel volume, retrigger, tremor, vibrato, panbrello, and common filter macros.
- **Public integration**: `.it` works in the loader, playlist scanner, file dialog, drag & drop, Finder “Open with”, `savage-cli`, and the bundled Quick Look extension. The app shows an Impulse Tracker format badge and renders all pattern rows and up to 64 channels.
- **Compatibility reporting**: unsupported MIDI/plugin routing, limited custom MIDI macros, newer tracker versions, and unknown MPTM/IT extensions produce visible non-fatal warnings.

## Verification

- The full Swift suite, dedicated filter/NNA/stereo fixtures, a 64-channel/256-voice release stress test, JS↔Swift MOD parity, the signed app build, and the Quick Look extension pass.
- Playback was compared against the pinned `openmpt123`/libopenmpt reference and, for filter and compatibility details, the OpenMPT and Schism Tracker source implementations.

## Known limitations

- MPTM, proprietary OpenMPT extensions, VST/plugin playback, and external MIDI output are not supported.
- Embedded MIDI macros are limited to common cutoff/resonance filter macros.
- Pattern lengths from 32 through 200 rows are supported; shorter or longer extension patterns are rejected with a parser error.
- The HTML5 player remains intentionally limited to classic 4-channel ProTracker MOD files.

## Notes

- The DMG is signed and notarized and includes the app and Quick Look extension; no module files are bundled.
