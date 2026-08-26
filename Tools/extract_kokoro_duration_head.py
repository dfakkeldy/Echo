#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract the Kokoro duration-predictor subgraph as a standalone ONNX model.

Source: onnx-community/Kokoro-82M-v1.0-ONNX, file onnx/model_fp16.onnx,
revision 1939ad2a8e416c0acfeecc08a694d14ef25f2231 (163_234_740 bytes).
The full model exposes only `waveform`; the per-phoneme duration it computes
internally (`/encoder/predictor/ReduceSum_output_0`, shape [1, n_tokens]) is the
StyleTTS2 "duration as sum of 50 bins" tensor. We surface it as the sole output
of an extracted subgraph so Echo can read per-token frame durations at synthesis.

The raw extracted output is FLOAT16 (it is an *internal* tensor of the fp16
model — only the full model's graph I/O is fp32). The ORT Swift package's ObjC
binding cannot read fp16 tensors (`tensorData()` throws "unsupported tensor
element type…", see objectivec/ort_enums.mm), which would silently disable
synthesis word timing on every platform. So after extraction we rename the fp16
tensor and append a Cast→FLOAT node that re-emits it under the original output
name: the graph output stays `/encoder/predictor/ReduceSum_output_0` (matching
`OnnxKokoroEngine.durationOutputName`) but is fp32, which the binding decodes.
Guarded by EchoTests/KokoroDurationHeadTests.

Usage:
  python3 Tools/extract_kokoro_duration_head.py \
    --source "$HOME/Library/Application Support/Narration/Models/kokoro-onnx-v6/model_fp16.onnx" \
    --out EchoCore/Services/Narration/kokoro_dur_head.onnx
"""
import argparse
import os
import sys

import onnx

EXPECTED_SOURCE_BYTES = 163_234_740
DURATION_TENSOR = "/encoder/predictor/ReduceSum_output_0"
INPUTS = ["input_ids", "style", "speed"]


def cast_output_to_fp32(model: onnx.ModelProto) -> onnx.ModelProto:
    """Re-emit the (fp16) duration tensor as a fp32 graph output of the same name.

    Renames the internal tensor to `<name>_fp16` wherever it is referenced, then
    appends `Cast(to=FLOAT)` producing the original name, and retypes the graph
    output. Idempotent: a model whose output is already FLOAT is returned as is.
    """
    graph = model.graph
    (out,) = graph.output
    assert out.name == DURATION_TENSOR, f"unexpected output {out.name}"
    if out.type.tensor_type.elem_type == onnx.TensorProto.FLOAT:
        return model

    fp16_name = DURATION_TENSOR + "_fp16"
    for node in graph.node:
        node.output[:] = [fp16_name if t == DURATION_TENSOR else t for t in node.output]
        node.input[:] = [fp16_name if t == DURATION_TENSOR else t for t in node.input]
    for vi in graph.value_info:
        if vi.name == DURATION_TENSOR:
            vi.name = fp16_name
    graph.node.append(
        onnx.helper.make_node(
            "Cast",
            inputs=[fp16_name],
            outputs=[DURATION_TENSOR],
            to=onnx.TensorProto.FLOAT,
            name="/echo/duration_output_cast_fp32",
        )
    )
    out.type.tensor_type.elem_type = onnx.TensorProto.FLOAT
    onnx.checker.check_model(model)
    return model


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="path to model_fp16.onnx")
    ap.add_argument("--out", required=True, help="output .onnx path")
    args = ap.parse_args()

    size = os.path.getsize(args.source)
    if size != EXPECTED_SOURCE_BYTES:
        print(
            f"refusing: source is {size} bytes, expected {EXPECTED_SOURCE_BYTES} "
            "(wrong/corrupt model)",
            file=sys.stderr,
        )
        return 1

    onnx.utils.extract_model(args.source, args.out, INPUTS, [DURATION_TENSOR])
    onnx.save(cast_output_to_fp32(onnx.load(args.out)), args.out)

    # Verify the extracted model's output signature: sole output, fp32 (the
    # ORT ObjC binding cannot decode fp16 — see module docstring).
    m = onnx.load(args.out)
    outs = [(o.name, o.type.tensor_type.elem_type) for o in m.graph.output]
    if outs != [(DURATION_TENSOR, onnx.TensorProto.FLOAT)]:
        print(f"unexpected outputs (want [(name, FLOAT)]): {outs}", file=sys.stderr)
        return 1
    print(
        f"OK: wrote {args.out} ({os.path.getsize(args.out)} bytes), "
        f"output {outs[0][0]} (fp32)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
