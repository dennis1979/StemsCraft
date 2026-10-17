#!/usr/bin/env python3
"""Diagnose WHERE the ORT-vs-torch error lives: edges vs middle, and spectrum.

Reuses spike1's dummy input. Prints per-stem mean/max abs diff in three time
zones (first 0.5s / middle / last 0.5s) and the dominant frequency of the diff.
Writes only stem-osx/spike1_diag.json.
"""

import json
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
os.environ.setdefault("HF_HUB_OFFLINE", "1")

FIXED = os.path.join(ROOT, "htdemucs_chunk_fixed.onnx")
OUT = os.path.join(ROOT, "spike1_diag.json")
SOURCES = ["drums", "bass", "other", "vocals"]
SR = 44100


def main():
    import torch
    import onnxruntime as ort
    from demucs.pretrained import get_model
    from spike1_export_compare import dummy_input, apply_export_patches

    base = get_model("htdemucs").models[0].eval()
    x = dummy_mix = dummy_input()
    with torch.no_grad():
        ref = base(x).numpy()
    apply_export_patches()  # parity-verified (0.0 diff), matches exported graph
    sess = ort.InferenceSession(FIXED, providers=["CPUExecutionProvider"])
    out = sess.run(None, {"mix": x.numpy()})[0]

    n = ref.shape[-1]
    edge = SR // 2  # 0.5 s
    zones = {"first_0.5s": (0, edge), "middle": (edge, n - edge),
             "last_0.5s": (n - edge, n)}
    report = {}
    for i, name in enumerate(SOURCES):
        d = np.abs(ref[0, i] - out[0, i])  # [2, T]
        z = {k: {"max": float(d[:, a:b].max()), "mean": float(d[:, a:b].mean())}
             for k, (a, b) in zones.items()}
        # spectrum of the diff (mean of stereo), top-3 freqs
        spec = np.abs(np.fft.rfft(d.mean(0) * np.hanning(n)))
        freqs = np.fft.rfftfreq(n, 1 / SR)
        top = np.argsort(spec)[-3:][::-1]
        z["diff_top_freqs_hz"] = [round(float(freqs[k]), 1) for k in top]
        report[name] = z
        print(f"{name:7s} max(first/mid/last)="
              f"{z['first_0.5s']['max']:.2e}/{z['middle']['max']:.2e}/"
              f"{z['last_0.5s']['max']:.2e} topfreqs={z['diff_top_freqs_hz']}",
              flush=True)
    json.dump(report, open(OUT, "w"), indent=1)
    print(f"wrote {OUT}", flush=True)


if __name__ == "__main__":
    main()
