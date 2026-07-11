The macOS app now plays **Impulse Tracker modules (`.it`)** in sample and instrument mode — the fifth supported tracker format after ProTracker MOD, Soundtracker, ScreamTracker 3, and FastTracker II. Version 1.5.29 also completes two FastTracker II effects and restructures the app UI implementation without changing its appearance or behavior.

## Added

- **Impulse Tracker (`.it`) support**: up to 64 logical channels, a preallocated 256-voice NNA pool, NNA/DCT/DCA, 120-note sample maps, envelopes, fadeout, sustain loops, stereo samples, surround, sample vibrato, pitch-pan, volume/pan swing, and resonant per-voice filters.
- **IT 2.14/2.15 samples**: uncompressed and compressed 8-/16-bit mono or stereo PCM, signed/unsigned and delta variants, forward and ping-pong loops, and separate sustain loops.
- **IT effect semantics**: effect and volume-column memory, `Old Effects`, `Compatible Gxx`, pattern/row delays and loops, tempo/global/channel volume, retrigger, tremor, vibrato, panbrello, and common filter macros.
- **Structured OpenMPT capability analysis**: `cwtv` identifies the creating tracker, `cmwt` controls format compatibility, and full OpenMPT versions come from their dedicated extension fields. XTPM/STPM chunks, legacy ModPlug chunks, MIDI/plugin routing, and the current OpenMPT `PlayBehaviour` bits are parsed at their structural boundaries; known channel, timing, mix, preamp, restart, filter, and PCM compatibility values are applied, including classic, alternative, and modern tempo modes and extended IT patterns from 1 to 1,024 rows.
- **Precise warnings**: compatibility warnings appear only when a limitation is actually reached in the played order path. Dormant MIDI flags, default macros, unused plugin definitions, and metadata remain silent; used external routes identify the instrument, channel, or plugin slot.
- **Public integration**: `.it` works in the loader, playlist scanner, file dialog, drag & drop, Finder “Open with”, `savage-cli`, and the bundled Quick Look extension. `savage-cli --info` reports tracker identity, extension chunks, `PlayBehaviour` state, and concrete capability results.

## Improved

- **FastTracker II effects**: `Hxy` global-volume slide now follows FT2 tick and memory semantics; `Rxy` multi-retrigger applies the FT2 volume modes and remembers both parameter nibbles independently.
- **Maintainability**: the former monolithic `MainView.swift` implementation is split into nine focused source files. This is an internal refactor with regression-tested behavior.
- The tracker grid and oscilloscopes show only the channels actually used by the song, under their original channel numbers; the header shows the used channel count before the BPM.
- Quick Look renders and caches a fast 60-second audio preview; unsupported files show a readable error instead of an endless loading indicator.
- PAL/NTSC moved next to the master oscilloscope and is available only for Paula-based MOD formats.
- Song duration and offline rendering use the same jump/loop/delay/tempo-aware sequencer probe, so the displayed time and the rendered length match the actual playback path.

## Verification

- The full Swift suite (227 tests), dedicated filter/NNA/stereo fixtures, a 64-channel/256-voice release stress test, JS↔Swift MOD parity, the signed app build, and the Quick Look extension pass.
- The new XM effect tests cover `Hxy` tick/memory behavior and `Rxy` volume modes plus per-nibble memory; A/B renders of all eight local XM fixtures are unchanged or improved.
- Playback was compared against the pinned `openmpt123`/libopenmpt reference and, for filter and compatibility details, the OpenMPT and Schism Tracker source implementations.

## Known limitations

- Savage Mod Player remains a native PCM tracker engine: MPTM, VST/AudioUnit plugin playback, and external MIDI output are not supported and warn only when actually used.
- Embedded MIDI macros are limited to common cutoff/resonance filter macros.
- Deprecated pre-1.17 OpenMPT swing, the superseded old loop/jump rule, imprecise legacy ping-pong overshoot, and proprietary envelope release nodes remain feature-specific compatibility limits.
- The HTML5 player remains intentionally limited to classic 4-channel ProTracker MOD files.

## Notes

- The DMG is signed and notarized and includes the app and Quick Look extension; no module files are bundled.
