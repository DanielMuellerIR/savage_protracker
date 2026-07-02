<p align="center">
  <img src="src/AppIcon.png" width="128" alt="Savage Protracker Player Icon">
</p>

<h1 align="center">Savage Protracker Player</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Amiga/tracker module player as a single-file HTML5 app and a native SwiftUI macOS app with a Quick Look plugin.</strong>
</p>

A cross-platform, self-contained tracker module player in two flavors:

1. **HTML5 (`savage-protracker-player.html`)** — a single HTML file (under 50 KB) that runs straight from the file system with a double click, no web server required. Plays classic 4-channel ProTracker MODs.
2. **Native macOS app (`Savage Protracker Player.app`)** — a SwiftUI desktop application built on `AVAudioEngine`/`AVAudioSourceNode` with true real-time oscilloscopes and VU meters. Additionally plays multichannel MODs (6/8/… channels, including `6CHN`/`8CHN`/`FLT8`), 15-sample Soundtracker modules, and **ScreamTracker 3 (`.s3m`)** — and ships with a **Quick Look plugin**: pressing the space bar on a `.mod`/`.s3m` file in Finder opens a playable audio preview.

Neither variant bundles any module files. Songs are loaded via drag & drop or the file dialog.

---

## Download

Ready-made builds of the macOS app are available as notarized DMGs on the [releases page](https://github.com/DanielMuellerIR/savage_protracker/releases). Download the DMG, open it, and drag the app into your Applications folder.

The HTML5 player needs no download beyond the repository itself: simply open `savage-protracker-player.html` in a browser.

---

## Installing the Quick Look plugin

The Quick Look plugin is embedded in the app bundle (`Contents/PlugIns/`) — there is nothing to install separately:

1. Drag the app from the DMG into **`/Applications`**.
2. **Launch the app once** (this is when macOS registers the bundled Quick Look extension).
3. Select a `.mod` or `.s3m` file in Finder and press the **space bar** — the preview shows the macOS audio player with the fully rendered song (play, scrubbing, volume). The first invocation takes a second or two because the song is rendered through the player engine in its entirety.

If no preview appears:

- Reload the Quick Look service: run `qlmanage -r` in Terminal, then open the preview again.
- Check the registration: `pluginkit -m -p com.apple.quicklook.preview | grep -i savage` should list an entry; if it does not, launch the app once or copy it to `/Applications` again.
- **Note on `.mod` and VLC**: if VLC (or another app that registers `.mod` as an audio/video type) is installed, macOS intercepts `.mod` files with its built-in media preview before third-party plugins are consulted — a Quick Look system limitation. `.s3m` previews always work regardless.

---

## Features

- **Format support (macOS app)**: ProTracker MOD, multichannel MOD (`xCHN`/`xxCH`/`CD81`/`OKTA`/`FLT8`), 15-sample Soundtracker, and ScreamTracker 3 (`.s3m`) including the volume column, panning, and S3M effects. The HTML5 player deliberately stays compact and plays 4-channel MODs.
- **Quick Look preview (macOS app)**: the bundled Quick Look plugin renders `.mod`/`.s3m` with the player engine and shows the native audio player with play and scrubbing in Finder (space bar).
- **Drag & drop**: drop individual `.mod`/`.s3m` files or entire folders (recursively) onto the player.
- **Automatic playlist**: if a subfolder named `audio/` exists next to the player or the app, it is scanned at startup and loaded as an alphabetically sorted playlist.
- **Playlist handling**: a single click on a playlist entry loads and starts the track. When a song ends, the playlist can advance automatically.
- **Real-time oscilloscopes**:
  - A true stereo master-mix oscilloscope fed straight from the audio render path.
  - Separate per-channel scopes (dynamic channel count) visualizing the actual waveforms from the synthesizer render block.
- **Multiple themes**:
  - **Dark**: graphite/black palette with good contrast and muted accent colors.
  - **Light**: a classic, bright macOS-like style with sober contrast.
- **PAL & NTSC clocks**: switchable Paula clocking (7.09 MHz PAL vs. 7.16 MHz NTSC).
- **Volume & stereo separation**: psychoacoustic (quadratic) volume scaling and adjustable stereo separation (bleed from 0% mono to 100% hard panning).
- **Hi-fi resampling**: switchable linearly interpolated sample playback for a smoother sound (can be disabled for the original 8-bit crunch).
- **WAV & stem export**: export the entire song to a stereo WAV file, or export individual instrument samples as WAV.
- **Full keyboard control**: space bar for play/pause, left/right arrows for song positions, up/down arrows to switch songs in the playlist.

---

## Technical background

### Synthesis & Paula emulation

The audio engine simulates the Amiga Paula hardware behavior:
- **Clocking**: the clock generator uses the PAL Paula frequency of `3,546,894.6 Hz`. The pitch factor is derived from the ratio to the current audio output rate.
- **Stereo panning**: Amiga-style hardware panning (channels 1 and 4 left, channels 2 and 3 right) with adjustable software blending to avoid headphone fatigue.
- **Effects**: faithful playback of all standard ProTracker commands, including arpeggio (`0x0`), slides (`0x1`/`0x2`), tone portamento (`0x3`), vibrato (`0x4`), volume slides (`0xA`), position jump (`0xB`), volume set (`0xC`), pattern break (`0xD`), extended effects (`0xE` such as loop, cut, note delay, retrigger), and tempo control (`0xF`).

For ScreamTracker 3 the engine switches to the ST3 period model (C2Spd-based periods against the 14.3 MHz ST3 clock) instead of Amiga Paula periods; the ProTracker effect set is extended with S3M specifics (fine/extra-fine slides with effect memory, tremor, fine vibrato, global volume).

### Architecture

| Layer | HTML5 | macOS (Swift) |
|---|---|---|
| Parser | `modplayer.js` | `ModuleLoader`/`ModParser`/`S3MParser` (SavageProtrackerPlayerCore) |
| DSP / mixer | `mod-player-worklet.js` (AudioWorklet) | `ModPlayerCoordinator.swift` (`AVAudioSourceNode`, up to 32 channels) |
| UI | vanilla JS + CSS grid | SwiftUI + Canvas |
| Quick Look | — | `quicklook/PreviewProvider.swift` (appex, offline WAV render) |

---

## Build

### HTML5

```bash
python3 build.py                  # → savage-protracker-player.html (~48 KB)
python3 build.py --no-min         # without minification
```

The generated single-file variant `savage-protracker-player.html` is part of
the repository so the player can be used directly without a local build.

### macOS app

```bash
bash build_app.sh                 # → "Savage Protracker Player.app" (incl. Quick Look appex)
```

Besides the app itself, `build_app.sh` compiles the Quick Look extension
(`quicklook/`) and places it inside the app bundle under `Contents/PlugIns/`.

At startup the app looks for an `audio/` directory next to the application and
automatically loads any `.mod`/`.s3m` files (or `mod.*` files) found there into
the playlist. These files are local test data only and do not belong in the
git repository.

For release builds, `build_app.sh` automatically signs with the Developer ID
`Developer ID Application: Daniel Mueller (9QSWKSR4NQ)` if it is available in
the keychain. Local unsigned builds are possible with
`SIGN_APP=0 bash build_app.sh`.

### DMG (for releases)

```bash
bash build_dmg.sh                 # → build/Savage Protracker Player.dmg
bash build_dmg.sh --notarize      # sign, notarize, and staple the DMG
```

The DMG contains a Retina-compatible background image (1x/2x TIFF via
`tiffutil`). Notarization expects a keychain profile, by default
`SavageProtrackerNotary`. It can be created once interactively:

```bash
xcrun notarytool store-credentials SavageProtrackerNotary
```

### Tests

```bash
swift test
swift test --filter MultiFormatTests
node Tests/js/worklet-timing.mjs
```

The suite covers the parsers (all MOD variants, S3M, synthetic and real files),
DSP timing, sequencing, the Quick Look plugin's offline WAV renderer, and the
parity between the Swift and browser DSP implementations.

---

## Publishing to GitHub

```bash
bash publish_github.sh --dry-run --release
bash publish_github.sh --release
```

The publishing script sets `origin` to
`https://github.com/DanielMuellerIR/savage_protracker.git`, blocks accidentally
tracked audio and release artifacts, and with `--release` creates the matching
GitHub release entry with the DMG asset.

## Origin

The ProTracker engine was first developed in the sister project
[FraktalLab](https://github.com/DanielMuellerIR/FraktalLab) as a custom
TypeScript/AudioWorklet implementation (`AmiModPanel` / `utils/modplayer`, no
`libopenmpt`). For this project it was extracted into a standalone single-file
HTML player and additionally ported to a native Swift engine built on
`AVAudioSourceNode`. Bundled MOD files are not part of this repository.

## AI assistance

AI-assisted pair programming was used as a tool during implementation, porting,
and debugging. The author and maintainer is Daniel Müller.

## License

**MIT license** — see [LICENSE](LICENSE).
