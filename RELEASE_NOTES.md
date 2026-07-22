Savage Mod Player 1.5.46 adds native Linux audio playback and hardens parsers,
rendering, command-line streaming, and Quick Look caching against malformed or
ambiguous input.

## Linux and command-line playback

- The platform-neutral replay engine now builds and tests on both macOS and
  Linux from the same Swift sources.
- `savage-cli --play` outputs through ALSA using the same render engine as the
  macOS app, offline renderer, and Quick Look extension.
- `--stdout` streams bounded PCM chunks immediately instead of buffering a
  complete song and WAV file before writing the first sample.
- Duration and sample-rate arguments reject non-finite and out-of-range values
  with a controlled exit code. Output options that cannot be combined are
  rejected before parsing or rendering.
- A required Ubuntu CI job builds and tests the release core and CLI with their
  ALSA and archive dependencies.

## Parser and playback correctness

- XM and S3M dimensions, pattern grids, instruments, samples, and cumulative
  PCM sizes are validated before allocation. Small malformed files can no
  longer request multi-gigabyte parser structures.
- FastTracker II files now honor the header's linear or Amiga frequency-table
  mode, including the corresponding period and slide behavior.
- The replay core was separated from AVFoundation and Combine without creating
  a second playback implementation; live, streamed, offline, and Quick Look
  rendering continue to share one engine.
- Latent Linux-only compilation and sequencing faults uncovered by the port
  were corrected and covered by cross-platform tests.

## Quick Look and cache reliability

- Preview cache keys now include canonical file identity and sub-second
  modification time. Equal basenames in different folders and rapid in-place
  replacements no longer reuse the wrong audio preview.
- Quick Look still renders at most 60 seconds and shows parser failures as a
  finite text preview.

## Verification and known limits

- The release is covered by the full optimized Swift suite, dedicated
  parser/render/cache tests, JavaScript-to-Swift MOD timing parity, macOS app and
  Quick Look builds, and the mandatory Linux CI job.
- MPTM, VST/AudioUnit plug-in playback, and external MIDI output remain outside
  the native engine. The HTML5 player remains intentionally limited to classic
  four-channel ProTracker MOD files.
- The DMG is Developer ID-signed, notarized by Apple, and includes the app and
  Quick Look extension. No module files are bundled.
