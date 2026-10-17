#!/usr/bin/env python3
"""
Spike 1 (B plan): can HTDemucs be exported to ONNX and match PyTorch output?

- Loads the single HTDemucs sub-model inside the 'htdemucs' bag (segment 7.8s,
  44100 Hz, stereo in -> 4 stems out), eval mode, CPU.
- Fixed-shape dummy chunk: [1, 2, 343980] (= 7.8 * 44100, exactly training_length
  so the forward() padding branch is not taken).
- Torch reference forward (no_grad, timed).
- Tries torch.onnx.export (legacy trace, then dynamo) -> stem-osx/htdemucs_chunk.onnx
- Runs onnxruntime on the same input, reports per-stem max-abs-diff and
  reconstruction SNR in dB: 10*log10(mean(ref^2) / mean((ref-out)^2)).
  Pass bar (inaudible): SNR >= ~50 dB, mirroring tests/mdx_reference.py practice.

Usage:
    stem-osx/.venv/bin/python stem-osx/spike1_export_compare.py [--stage export|compare|all]

Nothing outside this folder is written.
"""

import json
import os
import sys
import time
import traceback

ROOT = os.path.dirname(os.path.abspath(__file__))
ONNX_PATH = os.path.join(ROOT, "htdemucs_chunk.onnx")
RESULT_PATH = os.path.join(ROOT, "spike1_result.json")

SAMPLERATE = 44100
SEGMENT_SEC = 7.8
CHUNK = int(SEGMENT_SEC * SAMPLERATE)  # 343980
SOURCES = ["drums", "bass", "other", "vocals"]


def load_model():
    import torch
    from demucs.pretrained import get_model

    bag = get_model("htdemucs")
    assert type(bag).__name__ == "BagOfModels", type(bag)
    assert len(bag.models) == 1, len(bag.models)
    model = bag.models[0]
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)
    seg = float(model.segment)
    assert abs(seg - SEGMENT_SEC) < 1e-6, seg
    print(f"[load] {type(model).__name__} sources={model.sources} "
          f"segment={model.segment} nfft={model.nfft} "
          f"params={sum(p.numel() for p in model.parameters())}", flush=True)
    return model


def dummy_input():
    import numpy as np
    import torch

    t = np.arange(CHUNK) / SAMPLERATE
    # musical-ish mix: bass + mid + transient-ish click train, stereo decorrelated
    x = (0.30 * np.sin(2 * np.pi * 55 * t)
         + 0.25 * np.sin(2 * np.pi * 220 * t)
         + 0.10 * np.sin(2 * np.pi * 440 * t + 0.5 * np.sin(2 * np.pi * 5 * t)))
    clicks = np.zeros_like(t)
    clicks[::4410] = 0.4  # 10 Hz click train (drum-like transients)
    mono = x + clicks
    stereo = np.stack([mono, mono * 0.9 + 0.05 * np.sin(2 * np.pi * 330 * t)])
    return torch.from_numpy(stereo.astype("float32"))[None]  # [1, 2, T]


def torch_reference(model, x):
    import torch

    t0 = time.time()
    with torch.no_grad():
        out = model(x)
    dt = time.time() - t0
    print(f"[torch] out shape={tuple(out.shape)} in {dt:.1f}s", flush=True)
    assert tuple(out.shape) == (1, 4, 2, CHUNK), tuple(out.shape)
    return out, dt


def apply_export_patches():
    """Remove data-dependent value asserts that block torch.export.

    demucs/hdemucs.py pad1d ends with `assert (out[...] == x0).all()` --
    a guard on tensor *values* that dynamo cannot trace. The replacement is
    numerically identical (same F.pad calls, keeps the static shape assert).
    Applied by rebinding the module global (no file outside stem-osx/ touched).
    """
    import torch
    from torch.nn import functional as F
    import demucs.hdemucs
    import demucs.htdemucs

    def pad1d_no_value_assert(x, paddings, mode="constant", value=0.0):
        length = x.shape[-1]
        padding_left, padding_right = paddings
        if mode == "reflect":
            max_pad = max(padding_left, padding_right)
            if length <= max_pad:
                extra_pad = max_pad - length + 1
                extra_pad_right = min(padding_right, extra_pad)
                extra_pad_left = extra_pad - extra_pad_right
                paddings = (padding_left - extra_pad_left, padding_right - extra_pad_right)
                x = F.pad(x, (extra_pad_left, extra_pad_right))
        out = F.pad(x, paddings, mode, value)
        assert out.shape[-1] == length + padding_left + padding_right
        return out

    demucs.hdemucs.pad1d = pad1d_no_value_assert
    demucs.htdemucs.pad1d = pad1d_no_value_assert
    print("[patch] pad1d value-assert removed (runtime rebind only)", flush=True)

    # _ispec pads *complex* tensors (F.pad has no complex lowering in the
    # ONNX exporter). Identical math on the real view: pad real/imag planes.
    import math
    from demucs.spec import ispectro

    def _ispec_realpad(self, z, length=None, scale=0):
        import torch
        from torch.nn import functional as F

        hl = self.hop_length // (4 ** scale)
        zr = torch.view_as_real(z)  # [..., F, T, 2]
        # orig: F.pad(z,(0,0,0,1)) pads F +1; then F.pad(z,(2,2)) pads T +-2.
        # F.pad tuple runs from the last dim: (C2, T, F) here.
        zr = F.pad(zr, (0, 0, 0, 0, 0, 1))
        zr = F.pad(zr, (0, 0, 2, 2, 0, 0))
        z = torch.view_as_complex(zr.contiguous())
        pad = hl // 2 * 3
        le = hl * int(math.ceil(length / hl)) + 2 * pad
        x = ispectro(z, hl, length=le)
        x = x[..., pad: pad + length]
        return x

    import demucs.htdemucs
    demucs.htdemucs.HTDemucs._ispec = _ispec_realpad
    print("[patch] HTDemucs._ispec complex-pad -> real-pad (runtime rebind only)",
          flush=True)


def try_export(model, x, result):
    import torch

    attempts = []
    # 1) legacy trace exporter
    try:
        print("[export] trying legacy torch.onnx.export (dynamo=False) ...", flush=True)
        t0 = time.time()
        torch.onnx.export(
            model, (x,), ONNX_PATH,
            input_names=["mix"], output_names=["stems"],
            opset_version=18, dynamo=False,
        )
        dt = time.time() - t0
        size_mb = os.path.getsize(ONNX_PATH) / 1e6
        print(f"[export] legacy OK in {dt:.1f}s, {size_mb:.1f} MB -> {ONNX_PATH}", flush=True)
        result["export"] = {"method": "legacy-trace", "seconds": round(dt, 1),
                            "size_mb": round(size_mb, 1), "opset": 18}
        return True
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"
        tail = "\n".join(traceback.format_exc().splitlines()[-15:])
        print(f"[export] legacy FAILED: {msg}\n{tail}", flush=True)
        attempts.append({"method": "legacy-trace", "error": msg})
    # 2) dynamo exporter
    try:
        print("[export] trying dynamo torch.onnx.export (dynamo=True) ...", flush=True)
        t0 = time.time()
        torch.onnx.export(
            model, (x,), ONNX_PATH,
            input_names=["mix"], output_names=["stems"], dynamo=True,
        )
        dt = time.time() - t0
        size_mb = os.path.getsize(ONNX_PATH) / 1e6
        print(f"[export] dynamo OK in {dt:.1f}s, {size_mb:.1f} MB -> {ONNX_PATH}", flush=True)
        result["export"] = {"method": "dynamo", "seconds": round(dt, 1),
                            "size_mb": round(size_mb, 1)}
        return True
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {e}"
        tail = "\n".join(traceback.format_exc().splitlines()[-15:])
        print(f"[export] dynamo FAILED: {msg}\n{tail}", flush=True)
        attempts.append({"method": "dynamo", "error": msg})
    result["export"] = {"ok": False, "attempts": attempts}
    return False


def compare_ort(ref, x, result):
    import numpy as np
    import onnxruntime as ort

    onnx_path = os.environ.get("STEMOSX_ONNX", ONNX_PATH)
    print(f"[ort] model={onnx_path}", flush=True)

    print(f"[ort] providers={ort.get_available_providers()}", flush=True)
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    print(f"[ort] inputs={[i.name + str(i.shape) for i in sess.get_inputs()]}", flush=True)
    t0 = time.time()
    out = sess.run(None, {"mix": x.numpy()})[0]
    dt = time.time() - t0
    print(f"[ort] out shape={out.shape} in {dt:.1f}s", flush=True)

    ref_np = ref.numpy()
    assert out.shape == ref_np.shape, (out.shape, ref_np.shape)
    per_stem = {}
    for i, name in enumerate(SOURCES):
        a, b = ref_np[0, i], out[0, i]
        denom = float(np.mean((a - b) ** 2))
        snr = float(10 * np.log10(np.mean(a ** 2) / denom)) if denom > 0 else float("inf")
        per_stem[name] = {"max_abs_diff": float(np.max(np.abs(a - b))),
                          "snr_db": round(snr, 2)}
        print(f"[compare] {name:7s} max_abs={per_stem[name]['max_abs_diff']:.3e} "
              f"SNR={per_stem[name]['snr_db']} dB", flush=True)
    worst = min(v["snr_db"] for v in per_stem.values())
    verdict = "PASS (>=50dB, inaudible)" if worst >= 50 else "CHECK (<50dB)"
    print(f"[compare] worst SNR={worst} dB -> {verdict}", flush=True)
    result["compare"] = {"ort_seconds": round(dt, 1), "per_stem": per_stem,
                         "worst_snr_db": worst, "verdict": verdict}


def main():
    stage = sys.argv[sys.argv.index("--stage") + 1] if "--stage" in sys.argv else "all"
    result = {"chunk": CHUNK, "samplerate": SAMPLERATE, "stage": stage}
    model = load_model()
    x = dummy_input()
    print(f"[input] shape={tuple(x.shape)} dtype={x.dtype}", flush=True)
    ref, t_torch = torch_reference(model, x)
    result["torch_seconds"] = round(t_torch, 1)

    ok = True
    if stage in ("all", "export"):
        apply_export_patches()
        ok = try_export(model, x, result)
    if stage in ("all", "compare"):
        if stage == "compare" and not os.path.isfile(ONNX_PATH):
            raise SystemExit(f"missing {ONNX_PATH}, run --stage export first")
        if ok:
            compare_ort(ref, x, result)

    with open(RESULT_PATH, "w") as f:
        json.dump(result, f, indent=1)
    print(f"[done] wrote {RESULT_PATH}", flush=True)


if __name__ == "__main__":
    main()
