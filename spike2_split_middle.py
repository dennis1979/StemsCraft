#!/usr/bin/env python3
# Portions derived from facebookresearch/demucs, MIT License,
# Copyright (c) Meta Platforms, Inc. and affiliates. See THIRD_PARTY_NOTICES.md.
"""
Spike 2 (B plan, split approach): export only the real-valued middle of HTDemucs.

Spike 1 showed direct full-model ONNX export is blocked:
  - legacy exporter: "STFT does not currently support complex types"
  - dynamo translation: chokes on complex ops (aten.pad on complex STFT output)
  - even a toy stft->istft roundtrip exports to an ONNX graph that
    onnxruntime refuses to load (ScatterND int32 indices).

So the split is: STFT / iSTFT live natively in Swift (Accelerate vDSP),
and only the real-valued neural core becomes an ONNX model:

  Swift side:  mix --STFT--> z --view_as_real--> mag --norm--> [middle.onnx]
               --view_as_complex--> zout --iSTFT--> wave_freq --+--> stems
               mix --norm--> xt --------------------------------^  (+ time branch)

This script validates the boundary in torch (no Swift yet):
  1. pristine full-model reference on a fixed 7.8 s chunk [1,2,343980].
  2. boundary tensors via the model's own _spec/_magnitude + norm stats.
  3. DemucsMiddle (copied encoder/transformer/decoder + denorm, all real ops)
     run in torch + pristine tail (_mask/_ispec) == full reference?
  4. export DemucsMiddle via dynamo, load in onnxruntime, SNR vs torch middle.
     Pass bar: ORT loads AND worst-stem-equivalent SNR >= 50 dB.

Writes only stem-osx/spike2_split_middle.onnx and stem-osx/spike2_result.json.
"""

import json
import os
import sys
import time
import traceback

ROOT = os.path.dirname(os.path.abspath(__file__))
ONNX_PATH = os.path.join(ROOT, "spike2_split_middle.onnx")
RESULT_PATH = os.path.join(ROOT, "spike2_result.json")

SAMPLERATE = 44100
CHUNK = int(7.8 * SAMPLERATE)  # 343980 == training_length, no pad branch


def load_base():
    from demucs.pretrained import get_model

    bag = get_model("htdemucs")
    base = bag.models[0]
    base.eval()
    for p in base.parameters():
        p.requires_grad_(False)
    print(f"[load] {type(base).__name__} cac={base.cac} "
          f"nfft={base.nfft} hop={base.hop_length} "
          f"params={sum(p.numel() for p in base.parameters())}", flush=True)
    assert base.cac is True, "split math below assumes complex-as-channels"
    return base


class DemucsMiddle(__import__("torch").nn.Module):
    """Real-valued core: normalized mag + normalized wave -> denormed estimates.

    Inputs:
      x     [B, Cm, F, T]  normalized magnitude (complex-as-channels, real)
      xt    [B, 2, L]      normalized waveform
      mean, std   [B, 1, 1, 1]  mag norm stats (Swift recomputes these)
      meant, stdt [B, 1, 1]     wave norm stats
    Outputs:
      spec  [B, S, Cq, F, T] real (== _mask input; Swift does view_as_complex)
      wave  [B, S, 2, L]     time-branch waveform, denormalized
    Body is a line-by-line copy of HTDemucs.forward between norm and _mask.
    """

    def __init__(self, base):
        import torch

        super().__init__()
        self.b = base
        self.S = len(base.sources)
        self._torch = torch

    def forward(self, x, xt, mean, std, meant, stdt):
        torch = self._torch
        from einops import rearrange

        B, C, Fq, T = x.shape
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(self.b.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(self.b.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = self.b.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and self.b.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = self.b.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + self.b.freq_emb_scale * emb
            saved.append(x)
        if self.b.crosstransformer:
            if self.b.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = self.b.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = self.b.channel_upsampler_t(xt)
            x, xt = self.b.crosstransformer(x, xt)
            if self.b.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = self.b.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = self.b.channel_downsampler_t(xt)
        for idx, decode in enumerate(self.b.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = self.b.depth - len(self.b.tdecoder)
            if idx >= offset:
                tdec = self.b.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    assert pre.shape[2] == 1, pre.shape
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        assert len(saved) == 0 and len(lengths_t) == 0 and len(saved_t) == 0
        S = self.S
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        L = xt.shape[-1]
        xt = xt.view(B, S, -1, L)
        xt = xt * stdt[:, None] + meant[:, None]
        return x, xt


def boundary_tensors(base, mix):
    """Reproduce forward()'s head: complex spec + normalized real inputs."""
    torch = __import__("torch")
    with torch.no_grad():
        z = base._spec(mix)
        mag = base._magnitude(z).to(mix.device)
        mean = mag.mean(dim=(1, 2, 3), keepdim=True)
        std = mag.std(dim=(1, 2, 3), keepdim=True)
        x = (mag - mean) / (1e-5 + std)
        meant = mix.mean(dim=(1, 2), keepdim=True)
        stdt = mix.std(dim=(1, 2), keepdim=True)
        xt = (mix - meant) / (1e-5 + stdt)
    print(f"[bounds] z={tuple(z.shape)} {z.dtype} x={tuple(x.shape)} "
          f"xt={tuple(xt.shape)}", flush=True)
    return z, x, xt, mean, std, meant, stdt


def dummy_mix():
    import numpy as np
    import torch

    t = __import__("numpy").arange(CHUNK) / SAMPLERATE
    x = (0.30 * np.sin(2 * np.pi * 55 * t)
         + 0.25 * np.sin(2 * np.pi * 220 * t)
         + 0.10 * np.sin(2 * np.pi * 440 * t + 0.5 * np.sin(2 * np.pi * 5 * t)))
    clicks = np.zeros_like(t)
    clicks[::4410] = 0.4
    mono = x + clicks
    stereo = np.stack([mono, mono * 0.9 + 0.05 * np.sin(2 * np.pi * 330 * t)])
    return torch.from_numpy(stereo.astype("float32"))[None]


def main():
    import numpy as np
    import torch

    result = {"chunk": CHUNK, "samplerate": SAMPLERATE}
    base = load_base()
    mix = dummy_mix()

    with torch.no_grad():
        t0 = time.time()
        ref = base(mix)
        result["torch_full_seconds"] = round(time.time() - t0, 1)
    print(f"[torch-full] {tuple(ref.shape)} in {result['torch_full_seconds']}s",
          flush=True)

    z, x, xt, mean, std, meant, stdt = boundary_tensors(base, mix)
    result["shapes"] = {"z": list(z.shape), "x": list(x.shape),
                        "xt": list(xt.shape)}
    result["stft_params"] = {
        "nfft": base.nfft, "hop": base.hop_length,
        "window": "hann_periodic", "normalized": True, "center": True,
        "pad_mode": "reflect",
        "note": "_spec pads reflect (hl//2*3 each side), drops top freq bin, "
                "trims 2 frames each side; _ispec inverts it",
    }

    mid = DemucsMiddle(base).eval()
    with torch.no_grad():
        spec, wave = mid(x, xt, mean, std, meant, stdt)
    print(f"[middle-torch] spec={tuple(spec.shape)} wave={tuple(wave.shape)}",
          flush=True)

    # tail in torch: _mask + _ispec + add time branch (== forward's tail)
    with torch.no_grad():
        zout = base._mask(z, spec)
        wf = base._ispec(zout, int(7.8 * SAMPLERATE))
        recon = wave + wf
    split_err = (ref - recon).abs().max().item()
    print(f"[split-check] full-vs-split max abs diff = {split_err:.3e}",
          flush=True)
    result["split_max_abs_diff"] = split_err
    if split_err > 1e-5:
        result["verdict"] = "FAIL: split boundary not exact, fix wrapper"
        json.dump(result, open(RESULT_PATH, "w"), indent=1)
        raise SystemExit("split boundary mismatch")

    # export middle only (all real ops expected)
    try:
        print("[export] dynamo export of DemucsMiddle ...", flush=True)
        t0 = time.time()
        torch.onnx.export(mid, (x, xt, mean, std, meant, stdt), ONNX_PATH,
                          input_names=["x", "xt", "mean", "std", "meant", "stdt"],
                          output_names=["spec", "wave"], dynamo=True)
        dt = time.time() - t0
        size_mb = os.path.getsize(ONNX_PATH) / 1e6
        print(f"[export] OK in {dt:.1f}s, {size_mb:.1f} MB", flush=True)
        result["export"] = {"ok": True, "seconds": round(dt, 1),
                            "size_mb": round(size_mb, 1)}
    except Exception as e:  # noqa: BLE001
        msg = f"{type(e).__name__}: {str(e)[:500]}"
        print(f"[export] FAILED: {msg}", flush=True)
        traceback.print_exc(limit=8)
        result["export"] = {"ok": False, "error": msg}
        json.dump(result, open(RESULT_PATH, "w"), indent=1)
        raise SystemExit("middle export failed")

    # remove the Python stack traces / local paths the exporter wrote into the model
    from scrub_onnx import scrub
    scrub(ONNX_PATH)

    # onnxruntime: load + numeric compare
    import onnxruntime as ort

    try:
        sess = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
    except Exception as e:  # noqa: BLE001
        result["ort"] = {"load_ok": False, "error": f"{type(e).__name__}: {e}"}
        json.dump(result, open(RESULT_PATH, "w"), indent=1)
        raise SystemExit(f"ORT load failed: {e}")
    feeds = {"x": x.numpy(), "xt": xt.numpy(), "mean": mean.numpy(),
             "std": std.numpy(), "meant": meant.numpy(), "stdt": stdt.numpy()}
    t0 = time.time()
    spec_o, wave_o = sess.run(None, feeds)
    result["ort_seconds"] = round(time.time() - t0, 1)
    snrs = {}
    for name, a, b in (("spec", spec.detach().numpy(), spec_o),
                       ("wave", wave.detach().numpy(), wave_o)):
        denom = float(np.mean((a - b) ** 2))
        snr = float(10 * np.log10(np.mean(a ** 2) / denom)) if denom > 0 else float("inf")
        snrs[name] = {"max_abs_diff": float(np.max(np.abs(a - b))),
                      "snr_db": round(snr, 2)}
        print(f"[compare] {name} max_abs={snrs[name]['max_abs_diff']:.3e} "
              f"SNR={snrs[name]['snr_db']} dB", flush=True)
    worst = min(v["snr_db"] for v in snrs.values())
    result["ort"] = {"load_ok": True, "outputs": snrs, "worst_snr_db": worst}
    result["verdict"] = ("PASS: middle exports, ORT loads, inaudible diff"
                         if worst >= 50 else "CHECK: SNR below 50 dB")
    print(f"[done] worst SNR={worst} dB -> {result['verdict']}", flush=True)
    json.dump(result, open(RESULT_PATH, "w"), indent=1)


if __name__ == "__main__":
    main()
