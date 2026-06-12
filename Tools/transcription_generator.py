#!/usr/bin/env python3
"""Generate .transcript.json sidecar files from audio using faster-whisper.

The output JSON matches the TranscriptionSegment Codable schema consumed by
the Echo Audiobooks iOS and macOS apps:
  [{"text": "...", "startTime": 1.0, "endTime": 2.5}, ...]

Prerequisites:
  pip install -r Tools/requirements.txt
  brew install ffmpeg

Usage:
  # Single file
  python Tools/transcription_generator.py --audio_path track.mp3

  # Entire directory (skips files that already have a .transcript.json)
  python Tools/transcription_generator.py --dir "path/to/audiobook/"
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

AUDIO_EXTENSIONS = {".mp3", ".m4b", ".m4a", ".wav", ".flac"}

# English stop words filtered out during word frequency computation.
STOP_WORDS: set[str] = {
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
    "any", "are", "aren", "as", "at", "be", "because", "been", "before", "being",
    "below", "between", "both", "but", "by", "can", "could", "couldn", "did",
    "didn", "do", "does", "doesn", "doing", "don", "down", "during", "each",
    "few", "for", "from", "further", "had", "hadn", "has", "hasn", "have",
    "haven", "having", "he", "her", "here", "hers", "herself", "him",
    "himself", "his", "how", "i", "if", "in", "into", "is", "isn", "it",
    "its", "itself", "just", "ll", "m", "ma", "me", "might", "mightn",
    "more", "most", "mustn", "my", "myself", "needn", "no", "nor", "not",
    "now", "o", "of", "off", "on", "once", "only", "or", "other", "our",
    "ours", "ourselves", "out", "over", "own", "re", "s", "same", "shan",
    "she", "should", "shouldn", "so", "some", "such", "t", "than", "that",
    "the", "their", "theirs", "them", "themselves", "then", "there", "these",
    "they", "this", "those", "through", "to", "too", "under", "until", "up",
    "ve", "very", "was", "wasn", "we", "were", "weren", "what", "when",
    "where", "which", "while", "who", "whom", "why", "will", "with", "won",
    "would", "wouldn", "y", "you", "your", "yours", "yourself", "yourselves",
}


def check_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        print(
            "Error: ffmpeg not found on PATH. Install it with: brew install ffmpeg",
            file=sys.stderr,
        )
        sys.exit(2)


def find_audio_files(directory: str, skip_existing: bool) -> list[Path]:
    dir_path = Path(directory)
    if not dir_path.is_dir():
        print(f"Error: not a directory: {directory}", file=sys.stderr)
        sys.exit(1)

    files: list[Path] = []
    for entry in sorted(dir_path.iterdir()):
        if entry.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        if entry.name.startswith("."):
            continue
        sidecar = entry.parent / f"{entry.stem}.transcript.json"
        if skip_existing and sidecar.exists():
            continue
        files.append(entry)
    return files


def compute_word_frequencies(segments: list[dict], max_words: int = 50) -> list[dict]:
    """Compute word frequencies from transcription segments with stop-word filtering.

    Returns a list of {"word": str, "count": int} dicts sorted by count descending,
    matching the WordFrequency Codable schema consumed by the iOS/macOS apps.
    """
    counts: dict[str, int] = {}
    for segment in segments:
        for raw in segment["text"].lower().split():
            word = raw.strip(".,!?;:\"'()[]{}<>-—–…")
            if not word or len(word) < 2 or word in STOP_WORDS:
                continue
            if not any(c.isalpha() for c in word):
                continue
            counts[word] = counts.get(word, 0) + 1

    sorted_words = sorted(counts.items(), key=lambda item: item[1], reverse=True)
    return [{"word": w, "count": c} for w, c in sorted_words[:max_words]]


def transcribe_file(
    audio_path: str,
    output_path: str,
    model: "WhisperModel",
    language: str,
) -> None:
    print(f"Transcribing: {audio_path}")
    segments, info = model.transcribe(
        audio_path,
        language=language,
        beam_size=5,
    )

    results: list[dict] = []
    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue
        results.append({
            "text": text,
            "startTime": round(segment.start, 3),
            "endTime": round(segment.end, 3),
        })

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    print(f"  -> {len(results)} segments to: {output_path}")

    # Write word frequencies sidecar.
    frequencies = compute_word_frequencies(results)
    freq_path = str(Path(output_path).parent / f"{Path(output_path).stem}.word_frequencies.json")
    with open(freq_path, "w", encoding="utf-8") as f:
        json.dump(frequencies, f, indent=2, ensure_ascii=False)
    print(f"  -> {len(frequencies)} word frequencies to: {freq_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcribe audio to .transcript.json sidecars for Echo Audiobooks."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--audio_path", help="Path to a single audio file."
    )
    mode.add_argument(
        "--dir", help="Directory of audio files to transcribe (recursively skipped for now)."
    )
    parser.add_argument(
        "--output_path",
        default=None,
        help="Output JSON path (single file mode only).",
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
    parser.add_argument(
        "--device",
        default="auto",
        choices=["cpu", "cuda", "auto"],
        help="Device for inference: 'cpu', 'cuda', or 'auto' (default: auto — auto-detects best available)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-transcribe files that already have a .transcript.json sidecar.",
    )
    args = parser.parse_args()

    check_ffmpeg()

    from faster_whisper import WhisperModel

    # Resolve device and compute_type.
    device = args.device
    if device == "auto":
        try:
            import torch
            if torch.cuda.is_available():
                device = "cuda"
            else:
                device = "cpu"
        except ImportError:
            device = "cpu"

    # Use float16 on GPU for better throughput; int8 on CPU for memory efficiency.
    compute_type = "float16" if device == "cuda" else "int8"

    print(f"Loading Whisper model '{args.model_size}' on {device} ({compute_type})...")
    model = WhisperModel(args.model_size, device=device, compute_type=compute_type)

    if args.audio_path:
        if not os.path.isfile(args.audio_path):
            print(f"Error: file not found: {args.audio_path}", file=sys.stderr)
            sys.exit(1)
        output = args.output_path or str(
            Path(args.audio_path).parent / f"{Path(args.audio_path).stem}.transcript.json"
        )
        transcribe_file(args.audio_path, output, model, args.language)
    else:
        files = find_audio_files(args.dir, skip_existing=not args.force)
        if not files:
            print("No audio files to transcribe (all have sidecars, or directory is empty).")
            sys.exit(0)
        print(f"Found {len(files)} file(s) to transcribe.\n")
        for i, file_path in enumerate(files, 1):
            output = str(file_path.parent / f"{file_path.stem}.transcript.json")
            print(f"[{i}/{len(files)}]", end=" ")
            transcribe_file(str(file_path), output, model, args.language)
            print()
        print(f"Done — {len(files)} file(s) transcribed.")


if __name__ == "__main__":
    main()
