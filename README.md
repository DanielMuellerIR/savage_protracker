<p align="center">
  <img src="src/AppIcon.png" width="128" alt="Savage Mod Player Icon">
</p>

<h1 align="center">Savage Mod Player</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Amiga/tracker module player as a single-file HTML5 app and a native SwiftUI macOS app with a Quick Look plugin.</strong>
</p>

A cross-platform, self-contained tracker module player in two flavors:

1. **HTML5 (`savage-mod-player.html`)** — a single HTML file (under 50 KB) that runs straight from the file system with a double click, no web server required. Plays classic 4-channel ProTracker MODs.
2. **Native macOS app (`Savage Mod Player.app`)** — a SwiftUI desktop application built on `AVAudioEngine`/`AVAudioSourceNode` with true real-time oscilloscopes and VU meters. Additionally plays multichannel MODs (6/8/… channels, including `6CHN`/`8CHN`/`FLT8`), 15-sample Soundtracker modules, **ScreamTracker 3 (`.s3m`)**, **FastTracker II (`.xm`)**, and **Impulse Tracker (`.it`)** — and ships with a **Quick Look plugin**: pressing the space bar on a `.mod`/`.s3m`/`.xm`/`.it` file in Finder opens a playable audio preview.

Neither variant bundles any module files. Songs are loaded via drag & drop or the file dialog.

<p align="center">
  <img src="docs/screenshot-dark.png" width="900" alt="Savage Mod Player (dark mode) playing a 32-channel FastTracker II module">
</p>

---

## Download

Ready-made builds of the macOS app are available as notarized DMGs on the [releases page](https://github.com/DanielMuellerIR/savage_modplayer/releases). Download the DMG, open it, and drag the app into your Applications folder.

The HTML5 player needs no download beyond the repository itself: simply open `savage-mod-player.html` in a browser.

---

## Installing the Quick Look plugin

The Quick Look plugin is embedded in the app bundle (`Contents/PlugIns/`) — there is nothing to install separately:

1. Drag the app from the DMG into **`/Applications`**.
2. **Launch the app once** (this is when macOS registers the bundled Quick Look extension).
3. Select a `.mod`, `.s3m`, `.xm`, or `.it` file in Finder and press the **space bar** — the preview shows the macOS audio player with play, scrubbing, and volume. It renders up to the first 60 seconds, then caches that preview for unchanged files so later openings are immediate. Unsupported files show their parser error instead of an endless loading indicator.

If no preview appears:

- Reload the Quick Look service: run `qlmanage -r` in Terminal, then open the preview again.
- Check the registration: `pluginkit -m -p com.apple.quicklook.preview | grep -i savage` should list an entry; if it does not, launch the app once or copy it to `/Applications` again.
- **Note on `.mod` and VLC**: if VLC (or another app that registers `.mod` as an audio/video type) is installed, macOS may intercept `.mod` files with its built-in media preview before third-party plugins are consulted — a Quick Look system limitation. The extension also claims the verified VLC identifiers for `.s3m`, `.xm`, and `.it`.

---

## Features

- **Format support (macOS app)**: ProTracker MOD, multichannel MOD (`xCHN`/`xxCH`/`CD81`/`OKTA`/`FLT8`), 15-sample Soundtracker, ScreamTracker 3 (`.s3m`), FastTracker II (`.xm`), and native Impulse Tracker 2.14/2.15 (`.it`) files in sample or instrument mode. IT support includes 64 pattern channels, a preallocated 256-voice NNA pool, compressed 8/16-bit mono/stereo samples, envelopes, filters, effects, sustain loops, and compatibility flags. The HTML5 player deliberately stays compact and plays 4-channel MODs.
- **Quick Look preview (macOS app)**: the bundled Quick Look plugin renders and caches up to the first 60 seconds of `.mod`/`.s3m`/`.xm`/`.it` files with the player engine, then shows the native audio player with play and scrubbing in Finder (space bar). Unsupported files show a readable reason.
- **Drag & drop**: drop individual `.mod`/`.s3m`/`.xm`/`.it` files, entire folders (recursively), or Zip/7-Zip archives onto the player.
- **Automatic playlist**: a configurable autoplay folder (macOS app: Settings, Cmd+,) is scanned at startup and loaded as a playlist; without configuration, an `audio/` subfolder next to the player or the app is used.
- **Hierarchical playlist**: folders and archives appear as a collapsible tree. Folders start collapsed, the path to the playing track expands automatically, and playback and shuffle run across all folders.
- **Archives as folders (macOS app)**: Zip and 7-Zip archives are extracted invisibly to a temporary directory (cleaned up on quit) and shown in the playlist like regular folders.
- **Playlist handling**: a single click on a playlist entry loads and starts the track. When a song ends, the playlist can advance automatically.
- **Real-time oscilloscopes**:
  - A true stereo master-mix oscilloscope fed straight from the audio render path.
  - Separate per-channel scopes (dynamic channel count) visualizing the actual waveforms from the synthesizer render block.
- **Multiple themes**:
  - **Dark**: graphite/black palette with good contrast and muted accent colors.
  - **Light**: a classic, bright macOS-like style with sober contrast.
- **PAL & NTSC clocks**: switchable Paula clocking (3.546 MHz PAL vs. 3.580 MHz NTSC) for Paula-based MOD formats; the control is hidden for formats with their own frequency model.
- **Volume & stereo separation**: psychoacoustic (quadratic) volume scaling and adjustable stereo separation (bleed from 0% mono to 100% hard panning).
- **Hi-fi resampling**: switchable linearly interpolated sample playback for a smoother sound (can be disabled for the original 8-bit crunch).
- **WAV & stem export**: export the entire song to a stereo WAV file, or export individual instrument samples as WAV.
- **Full keyboard control**: space bar for play/pause, left/right arrows for song positions, up/down arrows to switch songs in the playlist.

---

## Controls & display explained

The transport buttons speak for themselves, but the tracker-specific readouts and toggles carry a bit of Amiga history. Every item below is also available as a **tooltip in the app** — hover over a control and wait a moment for the explanation to appear. Since tooltips take a few seconds to show and are easy to miss, they are collected here as well.

**Header readouts**

- **CH** (used channels): counts the pattern channels that actually contain notes, instruments, volume data, or effects; reserved empty channels are not included. The tracker grid and channel oscilloscopes show exactly these channels while retaining their original channel numbers, so IT's reserved 64-channel capacity and gaps do not create empty columns or a needless scrollbar.
- **BPM** (beats per minute): playback tempo. The Amiga standard is 125. Adjustable with −/+; a song can also change its own tempo via effects. Switching songs sets the new module's header value.
- **SPD** (speed): ticks per pattern row (Amiga standard 6). Lower = rows advance faster, higher = slower. Together with BPM this sets the effective speed.
- **PAT** (pattern position): the current pattern and the total in the song's play order. A pattern is a block of notes (usually 64 rows); the song plays them in this sequence.

**Clock** (shown next to the master oscilloscope for Paula-based MOD formats only)

- **PAL** (3.546 MHz Paula clock): as on European Amigas — the reference pitch and speed for most modules.
- **NTSC** (3.580 MHz Paula clock): as on US Amigas — modules sound slightly higher and run a little faster than with PAL.

**Sound options**

- **LED filter**: the Amiga's switchable low-pass filter at ~3.2 kHz that rolls off the highs — the duller original sound, as when the power LED was lit on a real Amiga.
- **Hi-Fi interpolation**: smooths samples during resampling (softer sound). Turned off it sounds like the original hardware — raw 8-bit audio with audible aliasing.
- **Stereo separation**: 100% = hard Amiga panning (channels fully left/right), 0% = mono. In between, crosstalk is blended in to reduce headphone fatigue. Most audible on headphones; barely noticeable on laptop speakers.
- **Loop mode**: what happens when the song ends — continue the playlist, repeat the song, or stop.

**Transport & navigation**

- **Shuffle**: when on, track changes and song ends jump randomly through the playlist; when off, the playlist plays in order.
- **−15 s / +30 s**: skip backward/forward (row-accurate; approximate across tempo changes).
- **Position slider**: pick a spot in the song — also works while stopped, in which case Play starts from there.

---

## Technical background

### Synthesis & Paula emulation

The audio engine simulates the Amiga Paula hardware behavior:
- **Clocking**: the clock generator uses the PAL Paula frequency of `3,546,894.6 Hz`. The pitch factor is derived from the ratio to the current audio output rate.
- **Stereo panning**: Amiga-style hardware panning (channels 1 and 4 left, channels 2 and 3 right) with adjustable software blending to avoid headphone fatigue.
- **Effects**: faithful playback of all standard ProTracker commands, including arpeggio (`0x0`), slides (`0x1`/`0x2`), tone portamento (`0x3`), vibrato (`0x4`), volume slides (`0xA`), position jump (`0xB`), volume set (`0xC`), pattern break (`0xD`), extended effects (`0xE` such as loop, cut, note delay, retrigger), and tempo control (`0xF`).

For ScreamTracker 3 the engine switches to the ST3 period model (C2Spd-based periods against the 14.3 MHz ST3 clock) instead of Amiga Paula periods; the ProTracker effect set is extended with S3M specifics (fine/extra-fine slides with effect memory, tremor, fine vibrato, global volume).

For FastTracker II the engine runs a dedicated instrument voice model: linear frequency table (exponential frequency from linear periods), multi-sample instruments with keymaps, volume and panning envelopes (sustain and loop, interpolated per tick), key-off with volume fadeout, auto-vibrato with sweep, and ping-pong sample loops. The XM effect set including the volume column and per-channel effect memory is translated onto the shared DSP core.

For Impulse Tracker the engine separates 64 logical pattern channels from a preallocated pool of 256 playback voices. It implements sample and instrument mode, NNA/DCT/DCA, 120-note sample maps, IT 2.14/2.15 compression, stereo and sustain loops, pitch/pan/filter envelopes, resonant per-voice filters, sample vibrato, surround, IT effect memory, and the `Old Effects`/`Compatible Gxx` profiles.

### Known Impulse Tracker limitations

- Native IT 2.14/2.15 playback is the target. MPTM, proprietary OpenMPT extensions, VST/plugin playback, and external MIDI output are not supported.
- Embedded MIDI macros are limited to the common cutoff/resonance filter macros. Files using MIDI/plugin routing or unknown extensions remain playable where possible and produce a visible warning.
- Pattern lengths are accepted from 32 through 200 rows, as defined by this implementation's compatibility target. Shorter or longer extension patterns are rejected with a parser error.

### Architecture

| Layer | HTML5 | macOS (Swift) |
|---|---|---|
| Parser | `modplayer.js` | `ModuleLoader` plus MOD/S3M/XM/IT parsers (SavageModPlayerCore) |
| DSP / mixer | `mod-player-worklet.js` (AudioWorklet) | `ModPlayerCoordinator.swift` (`AVAudioSourceNode`, up to 64 logical channels / 256 IT voices) |
| UI | vanilla JS + CSS grid | SwiftUI + Canvas |
| Quick Look | — | `quicklook/PreviewProvider.swift` (appex, offline WAV render) |

---

## Build

### HTML5

```bash
python3 build.py                  # → savage-mod-player.html (~48 KB)
python3 build.py --no-min         # without minification
```

The generated single-file variant `savage-mod-player.html` is part of
the repository so the player can be used directly without a local build.

### macOS app

```bash
bash build_app.sh                 # → "Savage Mod Player.app" (incl. Quick Look appex)
```

Besides the app itself, `build_app.sh` compiles the Quick Look extension
(`quicklook/`) and places it inside the app bundle under `Contents/PlugIns/`.

At startup the app fills the playlist from the autoplay folder configured in
the Settings window (Cmd+,). If none is set, it looks for an `audio/` directory
next to the application and automatically loads any `.mod`/`.s3m`/`.xm`/`.it` files (or
`mod.*` files) found there. These files are local test data only and do not
belong in the git repository.

For release builds, `build_app.sh` automatically signs with the Developer ID
`Developer ID Application: Daniel Mueller (9QSWKSR4NQ)` if it is available in
the keychain. Local unsigned builds are possible with
`SIGN_APP=0 bash build_app.sh`.

### DMG (for releases)

```bash
bash build_dmg.sh                 # → build/Savage Mod Player.dmg
bash build_dmg.sh --notarize      # sign, notarize, and staple the DMG
```

The DMG contains a Retina-compatible background image (1x/2x TIFF via
`tiffutil`). Notarization expects a keychain profile, by default
`SavageModPlayerNotary`. It can be created once interactively:

```bash
xcrun notarytool store-credentials SavageModPlayerNotary
```

### Tests

```bash
swift test
swift test --filter MultiFormatTests
node Tests/js/worklet-timing.mjs
```

The suite covers the parsers (all MOD variants, S3M, XM, IT, synthetic and real files),
DSP timing, sequencing, the Quick Look plugin's offline WAV renderer, and the
parity between the Swift and browser DSP implementations.

---

## Publishing to GitHub

```bash
bash publish_github.sh --dry-run --release
bash publish_github.sh --release
```

The publishing script sets `origin` to
`https://github.com/DanielMuellerIR/savage_modplayer.git`, blocks accidentally
tracked audio and release artifacts, and with `--release` creates the matching
GitHub release entry with the DMG asset.

## Origin

The ProTracker engine was first developed in the sister project
[FraktalLab](https://github.com/DanielMuellerIR/FraktalLab) as a custom
TypeScript/AudioWorklet implementation (`AmiModPanel` / `utils/modplayer`, no
`libopenmpt`). For this project it was extracted into a standalone single-file
HTML player and additionally ported to a native Swift engine built on
`AVAudioSourceNode`. Bundled MOD files are not part of this repository.

## License

**WTFPL** (Do What The Fuck You Want To Public License) — see [LICENSE](LICENSE).
