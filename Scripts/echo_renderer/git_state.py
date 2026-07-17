"""Fail-closed attestation for approved renderer-source worktrees."""

from __future__ import annotations

import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path


_GIT = "/usr/bin/git"
_COMMIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")


@dataclass(frozen=True)
class ApprovedWorktree:
    root: Path
    approved_sha: str

    @classmethod
    def attest(cls, root: Path, approved_sha: str) -> "ApprovedWorktree":
        """Attest a clean canonical worktree at the exact approved SHA."""
        if _COMMIT_SHA_PATTERN.fullmatch(approved_sha) is None:
            raise ValueError("approved SHA must be 40 lowercase hexadecimal characters")
        _attest(root, approved_sha)
        return cls(root=root, approved_sha=approved_sha)

    def reattest(self) -> None:
        """Repeat exact-HEAD and clean-state checks after intervening work."""
        _attest(self.root, self.approved_sha)


def _attest(root: Path, approved_sha: str) -> None:
    try:
        metadata = root.lstat()
        resolved_root = root.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"cannot inspect worktree root: {root}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"expected a non-link worktree directory: {root}")
    if root != resolved_root:
        raise ValueError(f"worktree root is not canonical: {root}")

    expected_head = approved_sha.encode("ascii") + b"\n"
    if _run_git(root, "rev-parse", "HEAD") != expected_head:
        raise ValueError("worktree HEAD does not match the approved SHA")
    if _run_git(
        root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
    ) != b"":
        raise ValueError("worktree has tracked or untracked changes")


def _run_git(root: Path, *arguments: str) -> bytes:
    try:
        completed = subprocess.run(
            [_GIT, *arguments],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise ValueError("cannot invoke git for worktree attestation") from error
    if completed.returncode != 0:
        raise ValueError("git rejected the worktree attestation request")
    return completed.stdout
