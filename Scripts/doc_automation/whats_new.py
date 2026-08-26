"""CLI: draft the nightly TestFlight 'What to Test' from the commit delta.

Fail-safe by design: on an empty delta or ANY error, the existing output file
is left untouched and the process exits 0 — a nightly build must never break or
ship machine garbage.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from doc_automation.changes import RawCommit, categorize
from doc_automation.render_testflight import render, DEFAULT_MAX_CHARS

UNIT_SEP = "\x1f"    # between subject and body
RECORD_SEP = "\x1e"  # between commits


def _git(args: list[str]) -> str:
    result = subprocess.run(["git", *args], check=True, capture_output=True, text=True)
    return result.stdout


def default_base(head: str = "HEAD") -> str:
    return _git(["merge-base", "origin/weekly", head]).strip()


def get_commits(base: str, head: str) -> list[RawCommit]:
    fmt = f"%s{UNIT_SEP}%b{RECORD_SEP}"
    out = _git(["log", "--no-merges", f"--format={fmt}", f"{base}..{head}"])
    commits: list[RawCommit] = []
    for record in out.split(RECORD_SEP):
        record = record.strip("\n")
        if not record.strip():
            continue
        subject, _, body = record.partition(UNIT_SEP)
        commits.append(RawCommit(subject=subject.strip(), body=body))
    return commits


def generate(base: str, head: str, template_text: str, max_chars: int = DEFAULT_MAX_CHARS) -> str:
    changes = categorize(get_commits(base, head))
    if changes.is_empty():
        raise ValueError("no user-facing changes in range")
    return render(changes, template_text, max_chars)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Draft the nightly TestFlight 'What to Test'.")
    parser.add_argument("--base", help="Base ref (default: merge-base origin/weekly HEAD)")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--template", required=True, help="Path to the frame template (contains {{CHANGES}})")
    parser.add_argument("--out", default="-", help="Output path, or '-' for stdout")
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    args = parser.parse_args(argv)

    try:
        base = args.base or default_base(args.head)
        template_text = Path(args.template).read_text()
        result = generate(base, args.head, template_text, args.max_chars)
    except Exception as error:  # fail-safe: never break the build
        print(f"whats_new: leaving existing file untouched ({error})", file=sys.stderr)
        return 0

    if args.out == "-":
        sys.stdout.write(result)
    else:
        Path(args.out).write_text(result)
        print(f"whats_new: wrote {args.out} ({len(result)} chars)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
