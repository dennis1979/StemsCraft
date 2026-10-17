#!/usr/bin/env python3
"""Fix torch-dynamo-exporter ScatterND/int32 issue (low-memory pass).

Same goal as fix_scatternd.py but O(n): single pass to collect, rebuild the
initializer list once instead of repeated .remove(), progress prints.
"""

import gc
import os

import numpy as np
import onnx
from onnx import TensorProto

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "htdemucs_chunk.onnx")
DST = os.path.join(ROOT, "htdemucs_chunk_fixed.onnx")


def main():
    print("[fix] loading ...", flush=True)
    m = onnx.load(SRC)
    print(f"[fix] loaded: {len(m.graph.node)} nodes, "
          f"{len(m.graph.initializer)} initializers", flush=True)

    convert = set()
    for node in m.graph.node:
        if node.op_type == "ScatterND":
            convert.add(node.input[1])
    print(f"[fix] ScatterND indices names: {len(convert)}", flush=True)

    inits = {i.name: i for i in m.graph.initializer}
    n_const = 0
    new_inits = []
    for ini in m.graph.initializer:
        if ini.name in convert and ini.data_type == TensorProto.INT32:
            arr = onnx.numpy_helper.to_array(ini).astype(np.int64)
            new = onnx.numpy_helper.from_array(arr, name=ini.name)
            new.doc_string = ini.doc_string
            new_inits.append(new)
            n_const += 1
        else:
            new_inits.append(ini)
    del inits
    del m.graph.initializer[:]
    m.graph.initializer.extend(new_inits)
    del new_inits
    gc.collect()
    print(f"[fix] const indices int32->int64: {n_const}", flush=True)

    # dynamic (non-initializer) indices -> Cast to int64
    n_dyn = 0
    inits_now = {i.name for i in m.graph.initializer}
    inserts = []  # (position, cast_node)
    for pos, node in enumerate(m.graph.node):
        if node.op_type == "ScatterND" and node.input[1] not in inits_now:
            cast_out = node.input[1] + "__as_int64"
            cast = onnx.helper.make_node(
                "Cast", [node.input[1]], [cast_out],
                to=TensorProto.INT64, name=f"cast_scatternd_{n_dyn}")
            inserts.append((pos, cast))
            node.input[1] = cast_out
            n_dyn += 1
    for shift, (pos, cast) in enumerate(inserts):
        m.graph.node.insert(pos + shift, cast)
    print(f"[fix] dynamic Cast inserted: {n_dyn}", flush=True)

    print("[fix] saving ...", flush=True)
    onnx.save(m, DST)
    print(f"[fix] wrote {DST} ({os.path.getsize(DST) / 1e6:.1f} MB)", flush=True)


if __name__ == "__main__":
    main()
