#!/usr/bin/env python3
"""Fix torch-dynamo-exporter ScatterND/int32 issue in spike1's ONNX graph.

The dynamo exporter emits ScatterND `indices` as int32 (constant initializers
and one graph-computed value). ONNX spec requires int64 -> onnxruntime refuses
to load the model (INVALID_GRAPH). Fix: rewrite int32 indices initializers to
int64 (same values) and insert a Cast node for the dynamic case.

Reads stem-osx/htdemucs_chunk.onnx, writes stem-osx/htdemucs_chunk_fixed.onnx.
"""

import os
import sys

import numpy as np
import onnx
from onnx import TensorProto

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "htdemucs_chunk.onnx")
DST = os.path.join(ROOT, "htdemucs_chunk_fixed.onnx")


def main():
    m = onnx.load(SRC)
    inits = {i.name: i for i in m.graph.initializer}
    n_const = n_dyn = 0
    for node in m.graph.node:
        if node.op_type != "ScatterND":
            continue
        idx_name = node.input[1]
        ini = inits.get(idx_name)
        if ini is not None:
            if ini.data_type == TensorProto.INT32:
                arr = onnx.numpy_helper.to_array(ini).astype(np.int64)
                new = onnx.numpy_helper.from_array(arr, name=ini.name)
                # keep original metadata (doc_string etc. where present)
                new.doc_string = ini.doc_string
                m.graph.initializer.remove(ini)
                m.graph.initializer.append(new)
                inits[idx_name] = new
                n_const += 1
        else:
            cast_out = idx_name + "__as_int64"
            cast = onnx.helper.make_node(
                "Cast", [idx_name], [cast_out],
                to=TensorProto.INT64,
                name=f"cast_scatternd_{n_dyn}",
            )
            # insert right before the ScatterND node
            for i, nd in enumerate(m.graph.node):
                if nd is node:
                    m.graph.node.insert(i, cast)
                    break
            node.input[1] = cast_out
            n_dyn += 1
    onnx.save(m, DST)
    print(f"[fix] const indices int32->int64: {n_const}, dynamic Cast inserted: {n_dyn}")
    print(f"[fix] wrote {DST} ({os.path.getsize(DST) / 1e6:.1f} MB)")

    # verify: reload + try ORT
    m2 = onnx.load(DST)
    onnx.checker.check_model(m2)
    print("[fix] onnx checker: OK")
    import onnxruntime as ort

    sess = ort.InferenceSession(DST, providers=["CPUExecutionProvider"])
    print(f"[fix] ORT load: OK, inputs={[i.name for i in sess.get_inputs()]}")


if __name__ == "__main__":
    sys.exit(main())
