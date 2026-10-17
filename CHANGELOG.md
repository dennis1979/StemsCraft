# Changelog

All notable changes to StemCraft are listed here. Versions follow [Semantic Versioning](https://semver.org/).
Chinese version: [CHANGELOG.zh-TW.md](CHANGELOG.zh-TW.md).

## [1.0.0] - 2026-10-17

First public release.

**Requirements:** Apple silicon Mac (M1 or later) running macOS 14 (Sonoma) or later. Intel Macs are not supported.

### Added
- Split a song into four stems (drums, bass, vocals, other) with HTDemucs, running locally through ONNX Runtime. No network connection is needed after setup.
- Stem player: mute, solo and volume for each stem, plus time-stretch.
- Tempo (BPM) and beat-grid detection.
- Drag and drop audio files onto the window, or open them. Several songs can be queued and are analysed one at a time.
- Export stems as WAV files.
- Persistent library of analysed songs, so reopening a song is instant. The default folder is `~/Music/StemsCraft`, which can be changed in Settings.
