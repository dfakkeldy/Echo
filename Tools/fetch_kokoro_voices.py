#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetch the English Kokoro voice style packs Echo narrates with.

The on-device ONNX Kokoro engine feeds a per-voice `style [1,256]` tensor to the
model. Each voice is a flat little-endian Float32 blob of shape [510, 256]
(510 = Kokoro's MAX_PHONEME_LENGTH). The onnx-community ONNX export ships these
verbatim as `voices/<id>.bin` — byte-identical to what Echo loads as
`<id>.f32` (verified: af_heart.bin sha256 == af_heart.f32 sha256 ==
d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b). So
"conversion" is just download + rename + write the `.rows` sidecar — no PyTorch.

We ship ONLY the English voices (American `a*` + British `b*`). Echo's G2P
(MisakiSwift English) emits English IPA; the other-language Kokoro voices
(Spanish/French/Hindi/Italian/Japanese/Portuguese/Chinese) are trained on other
languages' phonemes and would be mis-pronounced — adding them needs per-language
G2P, a separate feature.

Usage:
    python3 Tools/fetch_kokoro_voices.py            # fetch missing/incorrect packs
    python3 Tools/fetch_kokoro_voices.py --force    # re-fetch all

Idempotent: a voice whose `.f32` already exists at the right size is skipped
unless --force. Verifies every download is exactly 510*256*4 bytes and that
af_heart matches its recorded sha256.
"""
from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path

REPO = "onnx-community/Kokoro-82M-v1.0-ONNX"
BASE = f"https://huggingface.co/{REPO}/resolve/main/voices"
ROWS = 510
EMBED_DIM = 256
EXPECT_BYTES = ROWS * EMBED_DIM * 4  # 522240
AF_HEART_SHA = "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"

# English voices only. Source: hexgrad/Kokoro-82M VOICES.md (American + British).
AMERICAN_FEMALE = [
    "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
    "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
]
AMERICAN_MALE = [
    "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
    "am_onyx", "am_puck", "am_santa",
]
BRITISH_FEMALE = ["bf_alice", "bf_emma", "bf_isabella", "bf_lily"]
BRITISH_MALE = ["bm_daniel", "bm_fable", "bm_george", "bm_lewis"]
VOICES = AMERICAN_FEMALE + AMERICAN_MALE + BRITISH_FEMALE + BRITISH_MALE  # 28

RESOURCES = Path(__file__).resolve().parent.parent / "EchoCore" / "Resources"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(voice: str, force: bool) -> str:
    f32 = RESOURCES / f"{voice}.f32"
    rows = RESOURCES / f"{voice}.rows"
    if not force and f32.exists() and f32.stat().st_size == EXPECT_BYTES and rows.exists():
        return "skip (present)"
    url = f"{BASE}/{voice}.bin"
    with urllib.request.urlopen(url, timeout=120) as resp:
        data = resp.read()
    if len(data) != EXPECT_BYTES:
        raise SystemExit(
            f"FAIL {voice}: got {len(data)} bytes, expected {EXPECT_BYTES} "
            f"(shape would not be [{ROWS},{EMBED_DIM}])"
        )
    if voice == "af_heart" and sha256(data) != AF_HEART_SHA:
        raise SystemExit(f"FAIL af_heart sha mismatch: {sha256(data)} != {AF_HEART_SHA}")
    f32.write_bytes(data)
    rows.write_text(f"{ROWS}\n")
    return f"ok ({len(data)} bytes)"


def main() -> int:
    force = "--force" in sys.argv
    RESOURCES.mkdir(parents=True, exist_ok=True)
    print(f"Fetching {len(VOICES)} English Kokoro voices into {RESOURCES}")
    failures = []
    for v in VOICES:
        try:
            status = fetch(v, force)
            print(f"  {v:<14} {status}")
        except Exception as exc:  # noqa: BLE001 - surface any voice's failure, keep going
            print(f"  {v:<14} ERROR: {exc}")
            failures.append(v)
    total_mb = sum((RESOURCES / f"{v}.f32").stat().st_size for v in VOICES if (RESOURCES / f"{v}.f32").exists()) / 1e6
    print(f"\nDone. {len(VOICES) - len(failures)}/{len(VOICES)} voices present, ~{total_mb:.1f} MB total.")
    if failures:
        print(f"FAILURES: {failures}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
