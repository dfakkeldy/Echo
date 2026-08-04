#!/usr/bin/env python3
"""Fetch and verify the immutable mini-bart-g2p artifact set."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
from typing import Callable
import urllib.parse
import urllib.request


CHUNK_SIZE = 1024 * 1024
REVISION_PATTERN = re.compile(r"[0-9a-f]{40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
REPO_ROOT = Path(__file__).resolve().parents[2]


class FetchError(Exception):
    """Base error for a rejected or unverifiable artifact operation."""


class ContractError(FetchError):
    """The lock does not describe an immutable, safe artifact set."""


class DestinationError(FetchError):
    """The caller supplied an unsafe destination."""


class VerificationError(FetchError):
    """An artifact does not match its locked identity."""


@dataclass(frozen=True)
class Artifact:
    path: PurePosixPath
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class ArtifactLock:
    model: str
    revision: str
    license_path: PurePosixPath
    artifacts: tuple[Artifact, ...]


def _safe_relative_path(value: object, field: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ContractError(f"{field} must be a safe relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ContractError(f"{field} must be a safe relative path")
    return path


def _artifact_from_payload(payload: object, revision: str) -> Artifact:
    if not isinstance(payload, dict):
        raise ContractError("each artifact must be an object")

    path = _safe_relative_path(payload.get("path"), "artifact path")
    url = payload.get("url")
    if not isinstance(url, str):
        raise ContractError(f"artifact {path} URL must use HTTPS")
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        raise ContractError(f"artifact {path} URL must use HTTPS without credentials")

    url_parts = PurePosixPath(urllib.parse.unquote(parsed.path)).parts
    if revision not in url_parts:
        raise ContractError(f"artifact {path} URL must contain the pinned revision")
    revision_index = url_parts.index(revision)
    if tuple(url_parts[revision_index + 1 :]) != path.parts:
        raise ContractError(f"artifact {path} URL path must end with the artifact path")

    size = payload.get("size")
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        raise ContractError(f"artifact {path} size must be a non-negative integer")
    digest = payload.get("sha256")
    if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
        raise ContractError(
            f"artifact {path} SHA-256 must be 64 lowercase hex characters"
        )
    return Artifact(path=path, url=url, size=size, sha256=digest)


def load_lock(lock_path: Path | str) -> ArtifactLock:
    path = Path(lock_path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"could not read lock {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ContractError("lock schema_version must be 1")

    model = payload.get("model")
    if not isinstance(model, str) or not model:
        raise ContractError("lock model must be a non-empty string")
    revision = payload.get("revision")
    if not isinstance(revision, str) or REVISION_PATTERN.fullmatch(revision) is None:
        raise ContractError(
            "lock revision must be an immutable 40-character lowercase Git SHA"
        )
    license_path = _safe_relative_path(payload.get("license_path"), "license_path")

    raw_artifacts = payload.get("artifacts")
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        raise ContractError("lock artifacts must be a non-empty array")
    artifacts = tuple(_artifact_from_payload(item, revision) for item in raw_artifacts)
    paths = [artifact.path for artifact in artifacts]
    if len(paths) != len(set(paths)):
        raise ContractError("lock artifact paths must be unique")
    if license_path not in paths:
        raise ContractError("license_path must identify a locked artifact")
    return ArtifactLock(
        model=model,
        revision=revision,
        license_path=license_path,
        artifacts=artifacts,
    )


def _absolute_lexical(path: Path | str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    return Path(os.path.abspath(candidate))


def _validate_destination(destination: Path | str) -> Path:
    destination_path = _absolute_lexical(destination)
    if destination_path == Path(destination_path.anchor):
        raise DestinationError("destination must not be the filesystem root")
    if destination_path.is_symlink():
        raise DestinationError(f"destination must not be a symlink: {destination_path}")

    for ancestor in (destination_path, *destination_path.parents):
        git_marker = ancestor / ".git"
        if (git_marker.exists() or git_marker.is_symlink()) and ancestor != REPO_ROOT:
            raise DestinationError(
                f"destination is inside an unrelated Git repository or worktree: {ancestor}"
            )
    return destination_path


def _artifact_path(destination: Path, artifact: Artifact) -> Path:
    current = destination
    for part in artifact.path.parts:
        current = current / part
        if current.is_symlink():
            raise DestinationError(f"artifact path must not contain a symlink: {current}")
    return current


def _digest_file(path: Path) -> tuple[int, str]:
    size = 0
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(CHUNK_SIZE):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def _verify_file(path: Path, artifact: Artifact) -> None:
    if path.is_symlink():
        raise VerificationError(f"artifact must not be a symlink: {artifact.path}")
    if not path.is_file():
        raise VerificationError(f"artifact is missing: {artifact.path}")
    size, digest = _digest_file(path)
    if size != artifact.size:
        raise VerificationError(
            f"size mismatch for {artifact.path}: expected {artifact.size}, found {size}"
        )
    if digest != artifact.sha256:
        raise VerificationError(
            f"SHA-256 mismatch for {artifact.path}: expected {artifact.sha256}, found {digest}"
        )


def check(lock_path: Path | str, destination: Path | str) -> int:
    lock = load_lock(lock_path)
    destination_path = _validate_destination(destination)
    for artifact in lock.artifacts:
        _verify_file(_artifact_path(destination_path, artifact), artifact)
    return len(lock.artifacts)


def _download(
    artifact: Artifact,
    destination: Path,
    opener: Callable = urllib.request.urlopen,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".part",
            dir=destination.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            digest = hashlib.sha256()
            size = 0
            request = urllib.request.Request(
                artifact.url,
                headers={"User-Agent": "Echo reproducible model fetch/1"},
            )
            with opener(request) as response:
                while chunk := response.read(CHUNK_SIZE):
                    temporary.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                    if size > artifact.size:
                        raise VerificationError(
                            f"size mismatch for {artifact.path}: expected {artifact.size}, found more"
                        )
            temporary.flush()
            os.fsync(temporary.fileno())

        if size != artifact.size:
            raise VerificationError(
                f"size mismatch for {artifact.path}: expected {artifact.size}, found {size}"
            )
        actual_digest = digest.hexdigest()
        if actual_digest != artifact.sha256:
            raise VerificationError(
                f"SHA-256 mismatch for {artifact.path}: expected {artifact.sha256}, "
                f"found {actual_digest}"
            )
        if destination.is_symlink():
            raise DestinationError(f"artifact destination must not be a symlink: {destination}")
        os.replace(temporary_path, destination)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def fetch(
    lock_path: Path | str,
    destination: Path | str,
    opener: Callable = urllib.request.urlopen,
) -> int:
    lock = load_lock(lock_path)
    destination_path = _validate_destination(destination)
    destination_path.mkdir(parents=True, exist_ok=True)
    for artifact in lock.artifacts:
        artifact_path = _artifact_path(destination_path, artifact)
        _download(artifact, artifact_path, opener=opener)
    return check(lock_path, destination_path)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("fetch", "check"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--lock", type=Path, required=True)
        subparser.add_argument("--destination", type=Path, required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = _parser().parse_args(arguments)
    try:
        if args.command == "fetch":
            count = fetch(args.lock, args.destination)
            print(f"fetched and verified {count} artifacts at {args.destination}")
        else:
            count = check(args.lock, args.destination)
            print(f"verified {count} artifacts at {args.destination}")
    except (FetchError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
