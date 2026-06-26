#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract the Kokoro duration-predictor subgraph as a standalone ONNX model.

Source: onnx-community/Kokoro-82M-v1.0-ONNX, file onnx/model_fp16.onnx,
revision 1939ad2a8e416c0acfeecc08a694d14ef25f2231 (163_234_740 bytes).
The full model exposes only `waveform`; the per-phoneme duration it computes
internally (`/encoder/predictor/ReduceSum_output_0`, shape [1, n_tokens]) is the
StyleTTS2 "duration as sum of 50 bins" tensor. We surface it as the sole output
of an extracted subgraph so Echo can read per-token frame durations at synthesis.

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

    # Verify the extracted model's output signature.
    m = onnx.load(args.out)
    outs = [o.name for o in m.graph.output]
    if outs != [DURATION_TENSOR]:
        print(f"unexpected outputs: {outs}", file=sys.stderr)
        return 1
    print(
        f"OK: wrote {args.out} ({os.path.getsize(args.out)} bytes), output {outs[0]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
