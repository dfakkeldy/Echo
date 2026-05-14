#!/usr/bin/env python3
"""Generate .transcript.json sidecar files from audio using faster-whisper.

The output JSON matches the TranscriptionSegment Codable schema consumed by
the Orbit Audiobooks iOS and macOS apps:
  [{"text": "...", "startTime": 1.0, "endTime": 2.5}, ...]

Prerequisites:
  pip install -r Tools/requirements.txt
  brew install ffmpeg
"""

import argparse
import json
import os
import shutil
import sys
import uuid
from pathlib import Path


def check_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        print(
            "Error: ffmpeg not found on PATH. Install it with: brew install ffmpeg",
            file=sys.stderr,
        )
        sys.exit(2)


def resolve_output_path(audio_path: str, output_path: str | None) -> str:
    if output_path:
        return output_path
    p = Path(audio_path)
    return str(p.parent / f"{p.stem}.transcript.json")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcribe audio to a .transcript.json sidecar for Orbit Audiobooks."
    )
    parser.add_argument(
        "--audio_path", required=True, help="Path to the audio file (.mp3, .m4b, .m4a, etc.)"
    )
    parser.add_argument(
        "--output_path",
        default=None,
        help="Output JSON path. Defaults to <audio_stem>.transcript.json alongside the input.",
    )
    parser.add_argument(
        "--model_size",
        default="base",
        choices=["tiny", "base", "small", "medium", "large-v3"],
        help="Whisper model size (default: base)",
    )
    parser.add_argument(
        "--language",
        default="en",
        help="Language code for transcription (default: en)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.audio_path):
        print(f"Error: audio file not found: {args.audio_path}", file=sys.stderr)
        sys.exit(1)

    check_ffmpeg()

    output_path = resolve_output_path(args.audio_path, args.output_path)

    from faster_whisper import WhisperModel

    print(f"Loading Whisper model '{args.model_size}'... (first run downloads ~150MB to cache)")
    model = WhisperModel(args.model_size, device="cpu", compute_type="int8")

    print(f"Transcribing: {args.audio_path}")
    segments, info = model.transcribe(
        args.audio_path,
        language=args.language,
        beam_size=5,
    )
    print(f"Detected language: {info.language} (probability: {info.language_probability:.2f})")

    results: list[dict] = []
    for segment in segments:
        results.append({
            "text": segment.text.strip(),
            "startTime": round(segment.start, 3),
            "endTime": round(segment.end, 3),
        })

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    print(f"Wrote {len(results)} segments to: {output_path}")


if __name__ == "__main__":
    main()
