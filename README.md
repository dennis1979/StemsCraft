# StemsCraft

**English** | [繁體中文](README.zh-TW.md)

A native macOS app that splits a song into **drums / bass / vocals / other** stems, entirely on your own machine, and lets you play with them: mute, solo, per-stem volume, tempo change, and a detected beat grid.

## Features

- 4-stem separation (HTDemucs) running locally through ONNX Runtime; no network needed after setup
- Stem player: mute / solo / volume per stem, time-stretch
- Tempo and beat-grid detection
- Drag and drop or open audio files; several songs can be queued and are analysed one by one
- Export stems as WAV
- Persistent library of analysed songs, so reopening a song is instant (default folder `~/Music/StemsCraft`, changeable in Settings)

## Install (pre-built app)

1. Download `StemsCraft-1.0.0.dmg` from the [Releases](../../releases) page and drag **StemsCraft** into Applications. The model is already inside the app.
2. The app is only ad-hoc signed (not notarised), so macOS will block the first launch. Either open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/StemsCraft.app
   ```
3. Requires macOS 14 or later. Release builds are made on Apple silicon.

## Using the app

1. Drag an audio file onto the window (or use the add button) to start. The first time a song is processed it takes from tens of seconds to a few minutes, depending on its length and your Mac.
2. When it finishes you get Original + Drums / Bass / Other / Vocals tracks. Use **M** / **S** to mute or solo, and the sliders for volume.
3. Results are cached, so opening the same file again is instant. Use the export button to save stems as WAV.

If the empty window says **Model not found**, the app could not find the ONNX model; see "Build from source".

## Build from source

The model file is not in this repository (it is about 170 MB and is derived from the Demucs weights), so you generate it once yourself.

**You need:** a Mac with macOS 14+, Xcode 15 or later (Swift 5.9+), and Python 3.10 or later (the author used 3.14). The first model export also downloads the pretrained HTDemucs weights through Demucs, so it needs an internet connection.

```sh
git clone git@github.com:dennis1979/StemsCraft.git StemsCraft
cd StemsCraft

# 1. Create the ONNX model
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python spike2_split_middle.py
```

The script finishes with `PASS` and writes `spike2_split_middle.onnx` and `spike2_split_middle.onnx.data` in the repository root (keep both files together). It also runs a self-check comparing the ONNX model with PyTorch; a worst-case SNR of 50 dB or more is a pass.

```sh
# 2. Build, bundle and sign the app (builds in release mode, ad-hoc signed)
./package.sh

# 3. Run it
open dist/StemsCraft.app
```

`package.sh` produces `dist/StemsCraft.app` and `dist/StemsCraft-<version>.dmg` (the version comes from the `VERSION` file) with the model, fonts and licence files inside the app bundle.

### Command-line separation

Without the app you can separate a file from the terminal:

```sh
swift build --package-path app -c release
app/.build/release/StemsCLI <song.mp3|wav|...> spike2_split_middle.onnx <output-dir>
```

It writes `drums.wav`, `bass.wav`, `other.wav` and `vocals.wav` (16-bit, 44.1 kHz, stereo) into the output folder.

### Where the app looks for the model

In this order: inside the app bundle, the `STEMS_MODEL` environment variable, then a path saved in the app's preferences.

### Troubleshooting

- `swift build` fails: install the Xcode command line tools (`xcode-select --install`) and make sure `xcodebuild -version` reports 15 or later.
- The export script cannot install or import `demucs`: use a fresh virtual environment, and a recent Python.
- macOS says the app "is damaged" or "cannot be opened": see the `xattr` command under Install.

## How the model was adapted for macOS

HTDemucs cannot be exported to ONNX as a whole, and Apple platforms have no PyTorch runtime, so StemsCraft splits the model: the signal-processing parts run natively in Swift, and only the real-valued neural core runs in ONNX Runtime.

### Background: earlier approaches

StemsCraft grew out of a web-based prototype. Three separation engines were tried on Apple Silicon before the native app:

| Engine | Where it ran | Outcome |
| --- | --- | --- |
| MDX-Net via ONNX Runtime Web (WebGPU if an adapter is available, otherwise multi-threaded WASM) | Browser | Works, but sounds muffled: the model only processes the lowest 2,048 frequency bins, so highs are cut off (vocals about 14.7 kHz, other about 11 kHz, bass about 5.5 kHz). Slower than Demucs (1 min 05 s for a 4:35 song with WebGPU). Kept only as a comparison. |
| Demucs `htdemucs` with PyTorch on the Apple GPU (MPS) | Local Python server | Cleaner result and faster (29 s for the same 4:35 song). Chosen as the reference model. |
| HPSS (median filtering, no model) | Browser | No licensing concerns, but the result was poor, especially a thin kick drum. Comparison only. |

Core ML was never tried. The native app exists to remove the need for a separate Python server: the user gets a single self-contained app that runs the Demucs model locally.

### Why not export the whole model?

`spike1_export_compare.py` tried a direct export of one HTDemucs sub-model (`htdemucs`, 7.8 s chunks, 44.1 kHz stereo in, 4 stems out). It failed in three places:

1. The legacy `torch.onnx.export` rejects the model: *"STFT does not currently support complex types"*.
2. The dynamo exporter chokes on complex ops (`aten.pad` on the complex STFT output). Even a toy STFT-to-iSTFT round trip produces a graph that ONNX Runtime refuses to load.
3. The exported graph fails to load in ONNX Runtime: `ScatterND` receives `int32` indices, but the ONNX spec requires `int64`.

Workarounds that were tried (kept in the repo as experiments):

- `spike1_export_compare.py` patches Demucs at runtime (no files in the Demucs package are modified): it removes the data-dependent value assert in `pad1d`, and replaces the complex-tensor padding in `HTDemucs._ispec` with the same padding on the real/imaginary planes. The patched model is numerically identical in PyTorch (0.0 difference).
- `fix_scatternd.py` / `fix_scatternd2.py` rewrite the exported graph: 4,096 constant `ScatterND` index tensors are converted from `int32` to `int64`, and one `Cast` is inserted for the one index computed inside the graph (17,730 nodes, 195 MB). ONNX Runtime then loads the model.

The repaired full model loads and runs, but it is large, and its output on a single synthetic test chunk was well below the quality bar (SNR vs PyTorch: drums 39.2 dB, bass 62.7 dB, other 38.6 dB, vocals 16.5 dB; target 50 dB or more). A full-song comparison during development gave 57.3 / 71.7 / 47.5 / 50.2 dB. It was therefore not used.

### The split design that ships

`spike2_split_middle.py` exports only the real-valued core (encoder, cross-domain transformer, decoder, plus de-normalisation). Everything involving complex numbers stays outside the ONNX graph:

```
Swift (Accelerate / vDSP)                        ONNX Runtime                      Swift
mix --STFT--> z --real view--> spectrogram --norm--> [ middle.onnx ] --> spec, wave
                                                                         spec --complex view--> mask --iSTFT--> + time branch --> 4 stems
```

- The STFT/iSTFT are re-implemented in Swift with Accelerate (`Spectrogram.swift`): `nfft = 4096`, `hop = 1024`, periodic Hann window, orthonormal scaling, centred reflect padding, top frequency bin dropped and 2 frames trimmed on each side, exactly as Demucs' `_spec` / `_ispec`.
- The ONNX model takes `x` (spectrogram, `[1, 4, 2048, T]`), `xt` (waveform, `[1, 2, 343980]`) and the normalisation statistics, and returns `spec` and `wave`.
- `Separator.swift` runs the whole-song normalisation, splits the song into 7.8 s chunks with a 25 % triangular-weighted overlap, and overlap-adds the results. The app uses `shifts = 0` (no random-shift averaging).
- The app creates ONNX Runtime sessions with default options, i.e. on the CPU. The Core ML execution provider is not enabled.

### Verification (measured on the author's Mac)

| Check | Script | Result |
| --- | --- | --- |
| Split model equals the full PyTorch model (before ONNX) | `spike2_split_middle.py` | max abs difference 0.0 |
| ONNX core vs PyTorch core, one 7.8 s chunk | `spike2_split_middle.py` | SNR 81.8 dB (`spec`), 84.0 dB (`wave`); bar was 50 dB |
| Swift STFT / iSTFT vs PyTorch | development-time check (not included) | forward 132 dB, inverse 137 dB; bar was 100 dB |
| Model size | | graph 2.3 MB plus about 168 MB of external weights (`.onnx.data`), versus 195 MB for the repaired full model |
| Speed, one 7.8 s chunk | | ONNX Runtime 1.5 s, PyTorch 1.6 s |
| Speed, 275 s song, full Swift pipeline (CPU) | `StemsCLI` | about 76 s. For reference, PyTorch on CPU took 75 s and ONNX Runtime on CPU 76 s in a development-time comparison; the earlier Python server on the Apple GPU (MPS) took 29 s on the same song, with different settings, so the numbers are not strictly comparable. |

These are single runs on one machine, not benchmarks. The native app currently trades speed (CPU instead of the GPU) for not needing Python; enabling the Core ML or Metal execution provider is a possible future improvement and has not been tested.

## Repository layout

| Path | What it is |
| --- | --- |
| `app/` | Swift package: `StemsCore` (separation, STFT, beat analysis, player), `StemsApp` (SwiftUI app), `StemsCLI`, `StemsDebug` |
| `spike2_split_middle.py` | Exports the neural core of HTDemucs to ONNX; this is the model the app uses |
| `requirements.txt` | Python packages for the export script |
| `spike1_export_compare.py`, `spike1_diag.py`, `fix_scatternd.py`, `fix_scatternd2.py` | Earlier experiments with exporting the whole model (kept as a record, see above) |
| `Assets/` | App icon, logo, fonts |
| `package.sh` | Builds and packages the `.app` / `.dmg` |
| `THIRD_PARTY_NOTICES.md` | Licences of the software and model this project builds on |

## Future work

- **Hardware acceleration.** The app currently runs the model on the CPU through ONNX Runtime. The Swift package already exposes the Core ML execution provider (`appendCoreMLExecutionProviderWithOptionsV2`), so a first step is to make it opt-in (compute units `CPUAndGPU`, `CPUAndNeuralEngine` or `All`) and compare it with the CPU path. Things to check: FP16 precision on the GPU / Neural Engine against the 50 dB SNR bar used above, how much of the graph Core ML actually accepts, and first-launch compile time for the 168 MB weights. A direct conversion of the model core with `coremltools` is a larger alternative.
- Run the separation in a background process or in smaller steps to reduce memory use on long songs.
- Notarised and signed release builds (the current `package.sh` only ad-hoc signs).

## License

StemsCraft's own source code is released under the [MIT License](LICENSE), Copyright (c) 2026 北極熊喝水.

The full texts of third-party licences and the notices required by them are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Third-party software, models and assets

StemsCraft builds on the following work. Their copyrights and licenses remain with their respective owners and are **not** changed by StemsCraft's MIT license.

| Component | Used for | Copyright | License |
| --- | --- | --- | --- |
| [Demucs / HTDemucs](https://github.com/facebookresearch/demucs) (code and pretrained `htdemucs` weights) | Source separation. The ONNX model produced by `spike2_split_middle.py`, and the Swift STFT/mask pipeline (`Spectrogram.swift`, `Separator.swift`), are derived from this model and code. | Copyright (c) Meta Platforms, Inc. and affiliates | MIT |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) via [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) | Runs the model on-device. Linked into the app. | Copyright (c) Microsoft Corporation | MIT |
| [Barlow](https://github.com/jpt/barlow) and Barlow Condensed fonts (`Assets/Fonts`) | UI typography. License text in `Assets/Fonts/OFL.txt`. | Copyright 2017 The Barlow Project Authors | SIL Open Font License 1.1 |
| [PyTorch](https://github.com/pytorch/pytorch), [ONNX](https://github.com/onnx/onnx) | Build-time only, for exporting the model. Not redistributed. | Their respective authors | BSD-style / Apache-2.0 |
| Apple frameworks (SwiftUI, AVFoundation, Accelerate) | Audio decoding, playback, DSP, UI. Provided by macOS / Xcode, not redistributed. | Apple Inc. | Apple SDK license |

Other Python packages listed in `requirements.txt` (numpy, onnx, onnxscript, onnxruntime) are used only to export the model. They are not distributed with StemsCraft and carry their own licences.

If you use or cite the model, please also credit the original paper:

> Simon Rouard, Francisco Massa, Alexandre Défossez. *Hybrid Transformers for Music Source Separation.* arXiv:2211.08553 (2022).

## Disclaimer

Only process audio you have the right to use. This repository does not include any copyrighted music, and the authors take no responsibility for how the app is used.
