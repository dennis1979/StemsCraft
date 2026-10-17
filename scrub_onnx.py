"""Mask local file paths inside an ONNX model file.

PyTorch's exporter writes Python stack traces, which contain the absolute paths of the
machine that exported the model, into the .onnx file. This script replaces each
"/Users/..." path with a string of the same length, so all protobuf length fields stay
valid. The graph and weights are unchanged, and the external .onnx.data file is not touched.

Usage (inside the project venv):
    python scrub_onnx.py spike2_split_middle.onnx
"""
import os
import re
import sys
import tempfile

import onnx

PATH_RE = re.compile(rb"/Users/[^\s\"'\x00]*")


def _mask(match):
    text = match.group(0)
    return b"/" + b"_" * (len(text) - 1)


def scrub(path):
    with open(path, "rb") as f:
        raw = f.read()
    cleaned, count = PATH_RE.subn(_mask, raw)
    if count == 0:
        print(f"[scrub] {path}: no local paths found, nothing to do")
        return
    if len(cleaned) != len(raw):
        raise SystemExit("length changed, refusing to write")

    # The masked file must still parse, with the same number of nodes.
    before = onnx.load_model_from_string(raw)
    after = onnx.load_model_from_string(cleaned)
    if len(before.graph.node) != len(after.graph.node):
        raise SystemExit("node count changed, refusing to write")

    folder = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=folder, suffix=".tmp")
    with os.fdopen(fd, "wb") as f:
        f.write(cleaned)
    os.replace(tmp, path)

    with open(path, "rb") as f:
        left = len(PATH_RE.findall(f.read()))
    if left:
        raise SystemExit(f"{left} local path(s) still present")
    print(f"[scrub] {path}: masked {count} local path(s), {len(after.graph.node)} nodes unchanged")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    scrub(sys.argv[1])
