#!/usr/bin/env python3
"""Development-only pronunciation audio evaluation with strict privacy gates."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping


CLIP_ID_PATTERN = (
    r"^clip_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SOURCE_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
RENDER_IDENTITY_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
RETURNED_MODEL_PATTERN = re.compile(
    r"^gpt-audio-1\.5(?:-[0-9]{4}-[0-9]{2}-[0-9]{2})?$"
)
ALLOWED_PROVENANCE = {"public-domain", "synthetic"}
ALLOWED_LABEL_STATUS = {"human-labelled", "provisional"}
ALLOWED_EXPECTATIONS = {"pronunciation_acceptability"}
MEDIA_TYPES = {
    "audio/mpeg": ("mp3", ".mp3"),
    "audio/wav": ("wav", ".wav"),
}
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROVENANCE_AUTHORITY_PURPOSE = "openai-pronunciation-audio-evaluation"
PROVENANCE_AUTHORITY_FIELDS = {
    "schemaVersion",
    "authorizationPurpose",
    "clips",
}
PROVENANCE_AUTHORITY_CLIP_FIELDS = {
    "clipID",
    "audioSHA256",
    "durationSeconds",
    "provenance",
}
MEDIA_PROBE_CONTRACT = {
    "mp3": {
        "containers": {"mp3"},
        "codecs": {"mp3"},
    },
    "wav": {
        "containers": {"wav"},
        "codecs": {
            "pcm_alaw",
            "pcm_f32le",
            "pcm_f64le",
            "pcm_mulaw",
            "pcm_s16le",
            "pcm_s24le",
            "pcm_s32le",
            "pcm_u8",
        },
    },
}
MANIFEST_FIELDS = {"schemaVersion", "corpusIdentity", "clips"}
CLIP_FIELDS = {
    "clipID",
    "provenance",
    "labelStatus",
    "mediaType",
    "durationSeconds",
    "audioSHA256",
    "deterministicExpectation",
    "sourceCommit",
    "renderIdentity",
}
MAXIMUM_CLIP_DURATION_SECONDS = 15.0
_DURATION_TOLERANCE_SECONDS = 0.001
MAXIMUM_REQUESTS = 200
MAXIMUM_ESTIMATED_COST_USD = 10.0
FIXED_MAX_TEXT_OUTPUT_TOKENS = 180
MINIMUM_AUDIO_TOKENS_PER_SECOND = 1_000
MODEL_ID = "gpt-audio-1.5"
CONFIDENCE_REVIEW_THRESHOLD = 0.80
DEFAULT_OUTPUT_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Echo"
    / "PronunciationAudioJudge"
)
RUN_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
VERDICTS = {"pass", "fail", "uncertain"}
CATEGORIES = {
    "correct",
    "wrong_word",
    "wrong_sense",
    "stress",
    "vowel",
    "consonant",
    "timing",
    "artifact",
    "inaudible",
    "other",
}
VERDICT_REQUIRED_FIELDS = {"clipID", "verdict", "confidence", "category"}
VERDICT_OPTIONAL_FIELDS = {"heard", "note"}
USAGE_NUMERIC_FIELDS = {
    "prompt_tokens",
    "completion_tokens",
    "total_tokens",
}
USAGE_DETAIL_FIELDS = {
    "prompt_tokens_details": {
        "audio_tokens",
        "cached_tokens",
    },
    "completion_tokens_details": {
        "accepted_prediction_tokens",
        "audio_tokens",
        "reasoning_tokens",
        "rejected_prediction_tokens",
    },
}
MAXIMUM_REPORTED_USAGE_TOKENS = 10_000_000
PRICING_CONFIG = {
    "version": "gpt-audio-1.5-pricing-2026-07-29",
    "checkDate": "2026-07-29",
    "source": "https://developers.openai.com/api/docs/models/gpt-audio-1.5",
    "supportingSources": [
        "https://developers.openai.com/api/docs/models/all",
        "https://developers.openai.com/api/docs/guides/audio",
        "https://platform.openai.com/docs/api-reference/chat",
    ],
    "usdPerMillionTokens": {
        "textInput": 2.50,
        "textOutput": 10.00,
        "audioInput": 32.00,
        "audioOutput": 64.00,
    },
    "estimationRule": "exact-request-bytes-and-probed-audio-v2",
    "estimationInputs": {
        "textInput": (
            "one token per UTF-8 byte of the exact minified request with "
            "the audio data value removed"
        ),
        "audioInput": (
            "the greater of decoded payload bytes and 1000 tokens per "
            "probed second"
        ),
        "textOutput": FIXED_MAX_TEXT_OUTPUT_TOKENS,
    },
}


class ManifestError(ValueError):
    """Raised when public/synthetic audio admission fails closed."""


class ResponseValidationError(ValueError):
    """Raised when a model result is not one exact validated JSON object."""


class TransientTransportError(RuntimeError):
    """Raised for an eligible transport failure that permits one retry."""


class PermanentTransportError(RuntimeError):
    """Raised for a transport failure that must not be retried."""


class LedgerError(ValueError):
    """Raised when the reviewed two-attempt workflow would be violated."""


@dataclass(frozen=True)
class AdmittedClip:
    clip_id: str
    provenance: str
    label_status: str
    audio_format: str
    media_type: str
    duration_seconds: float
    audio_sha256: str
    deterministic_expectation: str
    source_commit: str
    render_identity: str
    _audio_path: Path


@dataclass(frozen=True)
class AdmittedManifest:
    clips: tuple[AdmittedClip, ...]
    manifest_bytes: bytes
    corpus_identity: str
    manifest_content_sha256: str
    provenance_authority_sha256: str


def generate_clip_id() -> str:
    """Return an opaque identifier independent of clip content and metadata."""
    return f"clip_{uuid.uuid4()}"


def validate_clip_id(value: Any) -> bool:
    """Return whether value is a canonical lowercase RFC 4122 UUIDv4 clip ID."""
    if not isinstance(value, str) or re.fullmatch(CLIP_ID_PATTERN, value) is None:
        return False
    parsed = uuid.UUID(value.removeprefix("clip_"))
    return (
        parsed.version == 4
        and parsed.variant == uuid.RFC_4122
        and value == f"clip_{parsed}"
    )


def _has_exact_json_type(value: Any, expected_type: type[Any]) -> bool:
    """Reject JSON booleans where integers and other exact scalars are required."""
    return type(value) is expected_type


def _is_exact_string_choice(value: Any, choices: set[str]) -> bool:
    return _has_exact_json_type(value, str) and value in choices


def _is_exact_bounded_number(
    value: Any,
    *,
    minimum: int | float,
    maximum: int | float,
    include_minimum: bool,
) -> bool:
    if _has_exact_json_type(value, int):
        pass
    elif _has_exact_json_type(value, float):
        if not math.isfinite(value):
            return False
    else:
        return False
    if include_minimum:
        return minimum <= value <= maximum
    return minimum < value <= maximum


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError("duplicate JSON key")
        result[key] = value
    return result


def _load_strict_json_bytes(content: bytes) -> Any:
    try:
        return json.loads(
            content.decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ManifestError("non-finite JSON number")),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ManifestError("manifest is not readable strict JSON") from error


def _external_regular_file(path: Path, *, name: str) -> Path:
    if not path.is_absolute():
        raise ManifestError(f"{name} must be an absolute external file")
    if path.is_symlink():
        raise ManifestError(f"{name} cannot be a symlink")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ManifestError(f"{name} is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ManifestError(f"{name} must be a regular file")
    if metadata.st_nlink != 1:
        raise ManifestError(f"{name} cannot be a hardlink")
    if resolved == REPOSITORY_ROOT or resolved.is_relative_to(REPOSITORY_ROOT):
        raise ManifestError(f"{name} must be outside the repository")
    return resolved


def _require_unique_regular_descriptor(
    descriptor: int,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    name: str,
) -> None:
    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise error_type(f"{name} is invalid") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise error_type(f"{name} is not a regular file")
    if metadata.st_nlink != 1:
        raise error_type(f"{name} cannot be a hardlink")


def _validate_existing_mutable_file(
    path: Path,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    name: str,
) -> None:
    if path.is_symlink():
        raise error_type(f"{name} cannot be a symlink")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        raise error_type(f"{name} is invalid") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise error_type(f"{name} is not a regular file")
    if metadata.st_nlink != 1:
        raise error_type(f"{name} cannot be a hardlink")


def _validate_existing_mutable_file_at(
    directory_descriptor: int,
    filename: str,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    name: str,
) -> bool:
    try:
        metadata = os.stat(
            filename,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return False
    except OSError as error:
        raise error_type(f"{name} is invalid") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise error_type(f"{name} is not a regular file")
    if metadata.st_nlink != 1:
        raise error_type(f"{name} cannot be a hardlink")
    return True


def _run_directory_identity(run_directory: Path) -> tuple[int, int]:
    try:
        metadata = run_directory.lstat()
    except OSError as error:
        raise LedgerError("judge-owned run directory is invalid") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise LedgerError("judge-owned run directory is invalid")
    return (metadata.st_dev, metadata.st_ino)


def _require_run_directory_identity(
    run_directory: Path,
    expected_identity: tuple[int, int],
) -> None:
    if _run_directory_identity(run_directory) != expected_identity:
        raise LedgerError("judge-owned run directory identity changed")


def _open_run_directory_descriptor(
    run_directory: Path,
    expected_identity: tuple[int, int],
) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        descriptor = os.open(run_directory, flags)
    except OSError as error:
        raise LedgerError("judge-owned run directory is invalid") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or (metadata.st_dev, metadata.st_ino) != expected_identity
        ):
            raise LedgerError("judge-owned run directory identity changed")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _read_unique_regular_bytes(
    path: Path,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    name: str,
) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            _require_unique_regular_descriptor(
                source.fileno(),
                error_type=error_type,
                name=name,
            )
            value = source.read()
            _require_unique_regular_descriptor(
                source.fileno(),
                error_type=error_type,
                name=name,
            )
            return value
    except error_type:
        raise
    except OSError as error:
        raise error_type(f"{name} is invalid") from error


def _read_unique_regular_bytes_at(
    directory_descriptor: int,
    filename: str,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    name: str,
) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW
    try:
        descriptor = os.open(
            filename,
            flags,
            dir_fd=directory_descriptor,
        )
        with os.fdopen(descriptor, "rb") as source:
            _require_unique_regular_descriptor(
                source.fileno(),
                error_type=error_type,
                name=name,
            )
            value = source.read()
            _require_unique_regular_descriptor(
                source.fileno(),
                error_type=error_type,
                name=name,
            )
            return value
    except error_type:
        raise
    except OSError as error:
        raise error_type(f"{name} is invalid") from error


def _load_provenance_authority(
    authority_path: Path,
) -> tuple[dict[str, dict[str, Any]], str]:
    path = _external_regular_file(authority_path, name="provenance authority")
    try:
        raw_bytes = _read_unique_regular_bytes(
            path,
            error_type=ManifestError,
            name="provenance authority",
        )
        value = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ManifestError("provenance authority is invalid")),
        )
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
        ManifestError,
    ) as error:
        raise ManifestError("provenance authority is invalid") from error
    if (
        not _has_exact_json_type(value, dict)
        or set(value) != PROVENANCE_AUTHORITY_FIELDS
    ):
        raise ManifestError("provenance authority fields are invalid")
    if (
        not _has_exact_json_type(value["schemaVersion"], int)
        or value["schemaVersion"] != 1
        or not _has_exact_json_type(value["authorizationPurpose"], str)
        or value["authorizationPurpose"] != PROVENANCE_AUTHORITY_PURPOSE
        or not _has_exact_json_type(value["clips"], list)
        or not value["clips"]
    ):
        raise ManifestError("provenance authority is invalid")
    bindings: dict[str, dict[str, Any]] = {}
    for row in value["clips"]:
        if (
            not _has_exact_json_type(row, dict)
            or set(row) != PROVENANCE_AUTHORITY_CLIP_FIELDS
            or not validate_clip_id(row.get("clipID"))
            or row["clipID"] in bindings
            or not _is_exact_string_choice(
                row.get("provenance"),
                ALLOWED_PROVENANCE,
            )
            or not _has_exact_json_type(row.get("audioSHA256"), str)
            or SHA256_PATTERN.fullmatch(row["audioSHA256"]) is None
        ):
            raise ManifestError("provenance authority clip binding is invalid")
        duration = row.get("durationSeconds")
        if not _is_exact_bounded_number(
            duration,
            minimum=0,
            maximum=MAXIMUM_CLIP_DURATION_SECONDS,
            include_minimum=False,
        ):
            raise ManifestError("provenance authority clip binding is invalid")
        bindings[row["clipID"]] = row
    return bindings, hashlib.sha256(raw_bytes).hexdigest()


def _require_exact_fields(value: Any, fields: set[str], name: str) -> dict[str, Any]:
    if not _has_exact_json_type(value, dict) or set(value) != fields:
        raise ManifestError(f"{name} fields do not match the contract")
    return value


def _probe_audio(path: Path, expected_format: str) -> float:
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        raise ManifestError("trusted media probe is unavailable")
    try:
        result = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration,format_name:stream=codec_type,codec_name",
                "-of",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        decoded = json.loads(result.stdout)
        format_record = decoded["format"]
        streams = decoded["streams"]
        duration = float(format_record["duration"])
        containers = set(format_record["format_name"].split(","))
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
    ) as error:
        raise ManifestError("trusted media probe failed") from error
    if not math.isfinite(duration) or duration <= 0:
        raise ManifestError("trusted media duration is invalid")
    contract = MEDIA_PROBE_CONTRACT[expected_format]
    if (
        not containers.intersection(contract["containers"])
        or not isinstance(streams, list)
        or len(streams) != 1
        or streams[0].get("codec_type") != "audio"
        or streams[0].get("codec_name") not in contract["codecs"]
    ):
        raise ManifestError("media container or codec does not match its declaration")
    return duration


def _verified_audio_bytes(clip: AdmittedClip) -> bytes:
    """Rehash and reprobe the exact bytes immediately before request creation."""
    try:
        before_probe = clip._audio_path.read_bytes()
    except OSError as error:
        raise ManifestError("admitted audio file is unavailable") from error
    if hashlib.sha256(before_probe).hexdigest() != clip.audio_sha256:
        raise ManifestError("audio content changed after admission")
    measured_duration = _probe_audio(clip._audio_path, clip.audio_format)
    try:
        after_probe = clip._audio_path.read_bytes()
    except OSError as error:
        raise ManifestError("admitted audio file is unavailable") from error
    if after_probe != before_probe:
        raise ManifestError("audio content changed while it was being verified")
    if measured_duration > MAXIMUM_CLIP_DURATION_SECONDS:
        raise ManifestError("measured clip duration exceeds the limit")
    if abs(measured_duration - clip.duration_seconds) > _DURATION_TOLERANCE_SECONDS:
        raise ManifestError("audio duration changed after admission")
    return after_probe


def _admit_clip(
    row: Any,
    *,
    manifest_directory: Path,
    seen_clip_ids: set[str],
) -> AdmittedClip:
    clip = _require_exact_fields(row, CLIP_FIELDS, "clip")
    clip_id = clip["clipID"]
    if not validate_clip_id(clip_id) or clip_id in seen_clip_ids:
        raise ManifestError("clipID is invalid or duplicated")
    seen_clip_ids.add(clip_id)

    provenance = clip["provenance"]
    label_status = clip["labelStatus"]
    media_type = clip["mediaType"]
    if not _is_exact_string_choice(provenance, ALLOWED_PROVENANCE):
        raise ManifestError("clip provenance is ineligible")
    if not _is_exact_string_choice(label_status, ALLOWED_LABEL_STATUS):
        raise ManifestError("clip label status is ineligible")
    if not _is_exact_string_choice(media_type, set(MEDIA_TYPES)):
        raise ManifestError("clip media type is ineligible")
    audio_format, suffix = MEDIA_TYPES[media_type]

    declared_duration = clip["durationSeconds"]
    if not _is_exact_bounded_number(
        declared_duration,
        minimum=0,
        maximum=MAXIMUM_CLIP_DURATION_SECONDS,
        include_minimum=False,
    ):
        raise ManifestError("declared clip duration is ineligible")

    audio_hash = clip["audioSHA256"]
    expectation = clip["deterministicExpectation"]
    source_commit = clip["sourceCommit"]
    render_identity = clip["renderIdentity"]
    if (
        not _has_exact_json_type(audio_hash, str)
        or SHA256_PATTERN.fullmatch(audio_hash) is None
    ):
        raise ManifestError("audio content hash is invalid")
    if not _is_exact_string_choice(expectation, ALLOWED_EXPECTATIONS):
        raise ManifestError("deterministic expectation is invalid")
    if (
        not _has_exact_json_type(source_commit, str)
        or SOURCE_COMMIT_PATTERN.fullmatch(source_commit) is None
    ):
        raise ManifestError("source commit is invalid")
    if (
        not _has_exact_json_type(render_identity, str)
        or RENDER_IDENTITY_PATTERN.fullmatch(render_identity) is None
    ):
        raise ManifestError("render identity is invalid")

    audio_path = manifest_directory / f"{clip_id}{suffix}"
    try:
        audio_bytes = audio_path.read_bytes()
    except OSError as error:
        raise ManifestError("admitted audio file is unavailable") from error
    if hashlib.sha256(audio_bytes).hexdigest() != audio_hash:
        raise ManifestError("audio content hash mismatch")
    measured_duration = _probe_audio(audio_path, audio_format)
    if measured_duration > MAXIMUM_CLIP_DURATION_SECONDS:
        raise ManifestError("measured clip duration exceeds the limit")
    if abs(measured_duration - float(declared_duration)) > _DURATION_TOLERANCE_SECONDS:
        raise ManifestError("declared and measured durations differ")

    return AdmittedClip(
        clip_id=clip_id,
        provenance=provenance,
        label_status=label_status,
        audio_format=audio_format,
        media_type=media_type,
        duration_seconds=measured_duration,
        audio_sha256=audio_hash,
        deterministic_expectation=expectation,
        source_commit=source_commit,
        render_identity=render_identity,
        _audio_path=audio_path,
    )


def _admit_manifest_with_authority(
    manifest_path: str | Path,
    provenance_authority_path: str | Path | None,
) -> AdmittedManifest:
    path = Path(manifest_path)
    authority_path = (
        Path(provenance_authority_path)
        if provenance_authority_path is not None
        else path.parent / "provenance-authority.json"
    )
    authority, authority_sha256 = _load_provenance_authority(authority_path)
    try:
        manifest_bytes = path.read_bytes()
    except OSError as error:
        raise ManifestError("manifest is not readable strict JSON") from error
    manifest = _require_exact_fields(
        _load_strict_json_bytes(manifest_bytes),
        MANIFEST_FIELDS,
        "manifest",
    )
    if (
        not _has_exact_json_type(manifest["schemaVersion"], int)
        or manifest["schemaVersion"] != 1
    ):
        raise ManifestError("unsupported manifest schema")
    corpus_identity = manifest["corpusIdentity"]
    if (
        not _has_exact_json_type(corpus_identity, str)
        or RENDER_IDENTITY_PATTERN.fullmatch(corpus_identity) is None
    ):
        raise ManifestError("corpus identity is invalid")
    rows = manifest["clips"]
    if not _has_exact_json_type(rows, list) or not rows:
        raise ManifestError("manifest clips must be a non-empty array")
    seen_clip_ids: set[str] = set()
    clips = tuple(
        _admit_clip(
            row,
            manifest_directory=path.parent,
            seen_clip_ids=seen_clip_ids,
        )
        for row in rows
    )
    if set(authority) != {clip.clip_id for clip in clips}:
        raise ManifestError("provenance authority does not match admitted clips")
    for clip in clips:
        binding = authority[clip.clip_id]
        if (
            binding["audioSHA256"] != clip.audio_sha256
            or binding["provenance"] != clip.provenance
            or abs(float(binding["durationSeconds"]) - clip.duration_seconds)
            > _DURATION_TOLERANCE_SECONDS
        ):
            raise ManifestError("provenance authority does not match admitted clip")
    return AdmittedManifest(
        clips=clips,
        manifest_bytes=manifest_bytes,
        corpus_identity=corpus_identity,
        manifest_content_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        provenance_authority_sha256=authority_sha256,
    )


def admit_manifest(
    manifest_path: str | Path,
    *,
    provenance_authority_path: str | Path | None = None,
) -> list[AdmittedClip]:
    """Admit clips only when a separate external authority binds provenance."""
    admission = _admit_manifest_with_authority(
        manifest_path,
        provenance_authority_path,
    )
    return list(admission.clips)


def encode_audio(clip: AdmittedClip) -> dict[str, str]:
    """Return direct base64 audio input without exposing a source path."""
    data = _verified_audio_bytes(clip)
    return {
        "format": clip.audio_format,
        "mediaType": clip.media_type,
        "data": base64.b64encode(data).decode("ascii"),
    }


def parse_verdict(payload: str, *, expected_clip_id: str) -> dict[str, Any]:
    """Strictly decode one duplicate-free result with a closed schema."""

    def strict_result(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ResponseValidationError("duplicate result key")
            result[key] = value
        return result

    if not _has_exact_json_type(payload, str):
        raise ResponseValidationError("result is not one JSON object")
    try:
        decoded = json.loads(
            payload,
            object_pairs_hook=strict_result,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ResponseValidationError("non-finite result number")),
        )
    except (json.JSONDecodeError, UnicodeError, ValueError) as error:
        raise ResponseValidationError("result is not one JSON object") from error
    if not isinstance(decoded, dict):
        raise ResponseValidationError("result is not one JSON object")
    fields = set(decoded)
    if (
        not VERDICT_REQUIRED_FIELDS.issubset(fields)
        or not fields.issubset(VERDICT_REQUIRED_FIELDS | VERDICT_OPTIONAL_FIELDS)
    ):
        raise ResponseValidationError("result fields do not match the contract")
    clip_id = decoded["clipID"]
    if (
        not _has_exact_json_type(clip_id, str)
        or clip_id != expected_clip_id
        or not validate_clip_id(clip_id)
    ):
        raise ResponseValidationError("result clipID does not match")
    if not _is_exact_string_choice(decoded["verdict"], VERDICTS):
        raise ResponseValidationError("result verdict is invalid")
    confidence = decoded["confidence"]
    if not _is_exact_bounded_number(
        confidence,
        minimum=0,
        maximum=1,
        include_minimum=True,
    ):
        raise ResponseValidationError("result confidence is invalid")
    if not _is_exact_string_choice(decoded["category"], CATEGORIES):
        raise ResponseValidationError("result category is invalid")
    for name, limit in (("heard", 160), ("note", 400)):
        if name in decoded and (
            not _has_exact_json_type(decoded[name], str)
            or len(decoded[name]) > limit
        ):
            raise ResponseValidationError(f"result {name} is invalid")
    return decoded


def _request_prompt(clip_id: str) -> str:
    return (
        "Judge only the pronunciation in this short public-domain or synthetic "
        "audio clip under the closed pronunciation-acceptability contract. "
        "Return exactly one JSON object with clipID, verdict, confidence, and "
        "category. verdict must be exactly one of: pass, fail, uncertain. "
        "category must be exactly one of: correct, wrong_word, wrong_sense, "
        "stress, vowel, consonant, timing, artifact, inaudible, other. "
        f"The clipID must be {clip_id}. Do not include markdown or prose."
    )


def _request_estimate(clip: AdmittedClip, body: dict[str, Any]) -> dict[str, Any]:
    """Derive conservative tokens from exact request bytes and probed audio."""
    try:
        stripped_body = json.loads(
            json.dumps(body),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ManifestError("request body is invalid")),
        )
        if (
            not _has_exact_json_type(stripped_body, dict)
            or set(stripped_body)
            != {
                "model",
                "messages",
                "modalities",
                "max_completion_tokens",
            }
            or not _has_exact_json_type(stripped_body["model"], str)
            or stripped_body["model"] != MODEL_ID
            or stripped_body["modalities"] != ["text"]
            or not _has_exact_json_type(
                stripped_body["max_completion_tokens"],
                int,
            )
            or (
                stripped_body["max_completion_tokens"]
                != FIXED_MAX_TEXT_OUTPUT_TOKENS
            )
        ):
            raise ManifestError("request body is invalid")
        messages = stripped_body["messages"]
        if (
            not _has_exact_json_type(messages, list)
            or len(messages) != 1
        ):
            raise ManifestError("request body is invalid")
        message = messages[0]
        if (
            not _has_exact_json_type(message, dict)
            or set(message) != {"role", "content"}
            or not _has_exact_json_type(message["role"], str)
            or message["role"] != "user"
        ):
            raise ManifestError("request body is invalid")
        content = message["content"]
        if (
            not _has_exact_json_type(content, list)
            or len(content) != 2
        ):
            raise ManifestError("request body is invalid")
        text_item, audio_item = content
        if (
            not _has_exact_json_type(text_item, dict)
            or set(text_item) != {"type", "text"}
            or not _has_exact_json_type(text_item["type"], str)
            or text_item["type"] != "text"
            or not _has_exact_json_type(text_item["text"], str)
            or text_item["text"] != _request_prompt(clip.clip_id)
            or not _has_exact_json_type(audio_item, dict)
            or set(audio_item) != {"type", "input_audio"}
            or not _has_exact_json_type(audio_item["type"], str)
            or audio_item["type"] != "input_audio"
        ):
            raise ManifestError("request body is invalid")
        input_audio = audio_item["input_audio"]
        if (
            not _has_exact_json_type(input_audio, dict)
            or set(input_audio) != {"data", "format"}
            or not _has_exact_json_type(input_audio["data"], str)
            or not _has_exact_json_type(input_audio["format"], str)
            or input_audio["format"] != clip.audio_format
            or input_audio["format"] not in {"wav", "mp3"}
        ):
            raise ManifestError("request body is invalid")
        encoded_audio = input_audio.pop("data")
        serialized_text_request = json.dumps(
            stripped_body,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (
        TypeError,
        ValueError,
        KeyError,
        IndexError,
        ManifestError,
    ) as error:
        raise ManifestError("request body is invalid") from error
    try:
        audio_bytes = base64.b64decode(encoded_audio, validate=True)
    except (ValueError, TypeError) as error:
        raise ManifestError("request audio payload is invalid") from error
    text_input_tokens = len(serialized_text_request)
    audio_input_tokens = max(
        len(audio_bytes),
        math.ceil(clip.duration_seconds * MINIMUM_AUDIO_TOKENS_PER_SECOND),
    )
    components = {
        "textInputTokens": text_input_tokens,
        "audioInputTokens": audio_input_tokens,
        "textOutputTokens": FIXED_MAX_TEXT_OUTPUT_TOKENS,
    }
    rates = PRICING_CONFIG["usdPerMillionTokens"]
    components["estimatedCostUSD"] = (
        text_input_tokens * rates["textInput"]
        + audio_input_tokens * rates["audioInput"]
        + FIXED_MAX_TEXT_OUTPUT_TOKENS * rates["textOutput"]
    ) / 1_000_000
    return components


def estimated_request_cost_usd(clip: AdmittedClip) -> float:
    """Return the versioned conservative estimate for the actual request."""
    return _request_estimate(clip, build_request_body(clip))["estimatedCostUSD"]


def enforce_prospective_cap(
    *,
    request_count: int,
    estimated_cost_usd: float,
    next_request_estimate_usd: float,
) -> None:
    """Refuse request 201 and any request whose estimate would exceed USD 10."""
    if request_count >= MAXIMUM_REQUESTS:
        raise ManifestError("request cap reached")
    if estimated_cost_usd + next_request_estimate_usd > MAXIMUM_ESTIMATED_COST_USD:
        raise ManifestError("estimated cost cap would be exceeded")


def build_request_body(clip: AdmittedClip) -> dict[str, Any]:
    """Build one Chat Completions audio-input/text-output request."""
    audio = encode_audio(clip)
    return {
        "model": MODEL_ID,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": _request_prompt(clip.clip_id)},
                    {
                        "type": "input_audio",
                        "input_audio": {
                            "data": audio["data"],
                            "format": audio["format"],
                        },
                    },
                ],
            }
        ],
        "modalities": ["text"],
        "max_completion_tokens": FIXED_MAX_TEXT_OUTPUT_TOKENS,
    }


def _post_chat_completion(body: dict[str, Any], api_key: str) -> dict[str, Any]:
    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            response_body = response.read()
    except urllib.error.HTTPError as error:
        if error.code in {408, 409, 429} or 500 <= error.code <= 599:
            raise TransientTransportError() from None
        raise PermanentTransportError() from None
    except (urllib.error.URLError, TimeoutError):
        raise TransientTransportError() from None
    try:
        decoded = json.loads(
            response_body,
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ValueError("non-finite API number")),
        )
        if not _has_exact_json_type(decoded, dict):
            raise ValueError("API root is not an object")
        choices = decoded.get("choices")
        if not _has_exact_json_type(choices, list) or not choices:
            raise ValueError("API choices are invalid")
        choice = choices[0]
        if not _has_exact_json_type(choice, dict):
            raise ValueError("API choice is invalid")
        message = choice.get("message")
        if not _has_exact_json_type(message, dict):
            raise ValueError("API message is invalid")
        if (
            "content" not in message
            or (
                message["content"] is not None
                and not _has_exact_json_type(message["content"], str)
            )
            or "refusal" not in message
            or (
                message["refusal"] is not None
                and not _has_exact_json_type(message["refusal"], str)
            )
            or not _has_exact_json_type(decoded.get("model"), str)
            or not _usage_is_valid(decoded.get("usage"))
        ):
            raise ValueError("API response envelope is invalid")
        return {
            "model": decoded["model"],
            "content": message["content"],
            "refusal": message["refusal"],
            "usage": decoded["usage"],
        }
    except (
        json.JSONDecodeError,
        ValueError,
        KeyError,
        IndexError,
        TypeError,
    ):
        raise PermanentTransportError() from None


def _morning_reasons(
    verdict: dict[str, Any] | None,
    *,
    failure: str | None = None,
) -> list[str]:
    reasons: list[str] = []
    if failure is not None:
        reasons.append(failure)
    if verdict is not None:
        if verdict["confidence"] < CONFIDENCE_REVIEW_THRESHOLD:
            reasons.append("low_confidence")
        if verdict["verdict"] == "uncertain":
            reasons.append("uncertain")
        if verdict["verdict"] == "fail":
            reasons.append("deterministic_disagreement")
    return reasons


def _is_valid_usage_count(value: Any) -> bool:
    return (
        _has_exact_json_type(value, int)
        and 0 <= value <= MAXIMUM_REPORTED_USAGE_TOKENS
    )


def _usage_is_valid(value: Any) -> bool:
    """Validate exact bounded counts and relationships in one usage object."""
    if not _has_exact_json_type(value, dict):
        return False
    for key in USAGE_NUMERIC_FIELDS:
        if key in value and not _is_valid_usage_count(value[key]):
            return False
    prompt_count = value.get("prompt_tokens")
    completion_count = value.get("completion_tokens")
    total_count = value.get("total_tokens")
    if total_count is not None:
        if prompt_count is not None and total_count < prompt_count:
            return False
        if completion_count is not None and total_count < completion_count:
            return False
        if (
            prompt_count is not None
            and completion_count is not None
            and total_count != prompt_count + completion_count
        ):
            return False
    detail_parents = {
        "prompt_tokens_details": prompt_count,
        "completion_tokens_details": completion_count,
    }
    for outer_key, allowed_inner_keys in USAGE_DETAIL_FIELDS.items():
        if outer_key not in value:
            continue
        details = value[outer_key]
        if not _has_exact_json_type(details, dict):
            return False
        parent_count = detail_parents[outer_key]
        for key in allowed_inner_keys:
            if key not in details:
                continue
            count = details[key]
            if (
                not _is_valid_usage_count(count)
                or (parent_count is not None and count > parent_count)
            ):
                return False
    return True


def _sanitized_usage(value: Any) -> dict[str, Any]:
    """Keep only documented counts from one fully validated usage object."""
    if not _usage_is_valid(value):
        return {}
    result = {
        key: value[key]
        for key in USAGE_NUMERIC_FIELDS
        if key in value
    }
    for outer_key, allowed_inner_keys in USAGE_DETAIL_FIELDS.items():
        details = value.get(outer_key)
        if not _has_exact_json_type(details, dict):
            continue
        sanitized_details = {
            key: details[key]
            for key in allowed_inner_keys
            if key in details
        }
        if sanitized_details:
            result[outer_key] = sanitized_details
    return result


def _validated_returned_model_id(value: Any) -> str | None:
    if (
        _has_exact_json_type(value, str)
        and RETURNED_MODEL_PATTERN.fullmatch(value) is not None
    ):
        return value
    return None


def _response_envelope_is_valid(value: Any) -> bool:
    if not _has_exact_json_type(value, dict):
        return False
    if not {"model", "content", "refusal", "usage"}.issubset(value):
        return False
    content = value["content"]
    refusal = value["refusal"]
    return (
        _has_exact_json_type(value["model"], str)
        and (content is None or _has_exact_json_type(content, str))
        and (refusal is None or _has_exact_json_type(refusal, str))
        and _usage_is_valid(value["usage"])
    )


def _atomic_write_json(
    path: Path,
    value: Any,
    *,
    error_type: type[ManifestError] | type[LedgerError] = ManifestError,
    artifact_name: str = "run artifact",
) -> None:
    _validate_existing_mutable_file(
        path,
        error_type=error_type,
        name=artifact_name,
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    serialized = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=error_type,
                name="temporary run artifact",
            )
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=error_type,
                name="temporary run artifact",
            )
        _validate_existing_mutable_file(
            path,
            error_type=error_type,
            name=artifact_name,
        )
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _atomic_write_json_at(
    directory_descriptor: int,
    run_directory: Path,
    expected_run_identity: tuple[int, int],
    filename: str,
    value: Any,
    *,
    artifact_name: str,
) -> None:
    _require_run_directory_identity(
        run_directory,
        expected_run_identity,
    )
    _validate_existing_mutable_file_at(
        directory_descriptor,
        filename,
        error_type=LedgerError,
        name=artifact_name,
    )
    temporary = f".{filename}.{uuid.uuid4().hex}.tmp"
    serialized = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        descriptor = os.open(
            temporary,
            flags,
            0o600,
            dir_fd=directory_descriptor,
        )
        with os.fdopen(descriptor, "wb") as output:
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=LedgerError,
                name="temporary run artifact",
            )
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=LedgerError,
                name="temporary run artifact",
            )
        _require_run_directory_identity(
            run_directory,
            expected_run_identity,
        )
        _validate_existing_mutable_file_at(
            directory_descriptor,
            filename,
            error_type=LedgerError,
            name=artifact_name,
        )
        os.replace(
            temporary,
            filename,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        os.fsync(directory_descriptor)
    except Exception as error:
        try:
            os.unlink(temporary, dir_fd=directory_descriptor)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        if isinstance(error, LedgerError):
            raise
        if isinstance(error, OSError):
            raise LedgerError(f"{artifact_name} is invalid") from error
        raise


def _exclusive_write_json(path: Path, value: Any) -> None:
    """Durably create a JSON artifact without permitting replacement."""
    serialized = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
    except FileExistsError as error:
        raise ManifestError("run identifier is already claimed") from error
    try:
        with os.fdopen(descriptor, "wb") as output:
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=ManifestError,
                name="run claim",
            )
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=ManifestError,
                name="run claim",
            )
    except Exception:
        path.unlink(missing_ok=True)
        raise


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _claim_run(run_id: str, output_root: str | Path | None) -> Path:
    """Atomically claim a never-reusable run directory."""
    root = _validated_run_root(
        output_root,
        error_type=ManifestError,
        require_exists=False,
    )
    root.mkdir(parents=True, exist_ok=True)
    root = _validated_run_root(
        root,
        error_type=ManifestError,
        require_exists=True,
    )
    run_directory = root / run_id
    try:
        run_directory.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ManifestError("run identifier is already claimed") from error
    try:
        _fsync_directory(root)
        _exclusive_write_json(
            run_directory / "run-claim.json",
            {
                "schemaVersion": 1,
                "runID": run_id,
                "state": "claimed",
            },
        )
        _fsync_directory(run_directory)
    except Exception:
        try:
            run_directory.rmdir()
        except OSError:
            pass
        raise
    return run_directory


def _reserve_request(
    *,
    run_directory: Path,
    request_number: int,
    clip_id: str,
    estimate: dict[str, Any],
) -> None:
    """Append and fsync the paid-attempt reservation before transport."""
    event = {
        "schemaVersion": 1,
        "eventType": "request_reserved",
        "requestNumber": request_number,
        "clipID": clip_id,
        "estimatedCostUSD": round(estimate["estimatedCostUSD"], 8),
        "pricingVersion": PRICING_CONFIG["version"],
        "estimate": {
            "textInputTokens": estimate["textInputTokens"],
            "audioInputTokens": estimate["audioInputTokens"],
            "textOutputTokens": estimate["textOutputTokens"],
        },
    }
    path = run_directory / "request-reservations.jsonl"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "a", encoding="utf-8") as output:
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=ManifestError,
                name="request reservation",
            )
            output.write(
                json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
            )
            output.flush()
            os.fsync(output.fileno())
            _require_unique_regular_descriptor(
                output.fileno(),
                error_type=ManifestError,
                name="request reservation",
            )
    except ManifestError:
        raise
    except OSError as error:
        raise ManifestError("request reservation is invalid") from error
    _fsync_directory(run_directory)


def _validated_run_root(
    output_root: str | Path | None,
    *,
    error_type: type[ManifestError] | type[LedgerError],
    require_exists: bool,
) -> Path:
    root = Path(output_root or DEFAULT_OUTPUT_ROOT)
    if not root.is_absolute():
        raise error_type("run root must be an absolute path")
    if root.is_symlink():
        raise error_type("run root cannot be a symlink")
    try:
        resolved = root.resolve(strict=require_exists)
    except OSError as error:
        raise error_type("run root is unavailable") from error
    if resolved == REPOSITORY_ROOT or resolved.is_relative_to(REPOSITORY_ROOT):
        raise error_type("run root must be outside the repository")
    if require_exists and (not root.exists() or not root.is_dir()):
        raise error_type("run root is unavailable")
    if root.exists() and not root.is_dir():
        raise error_type("run root must be a directory")
    return resolved


def _validate_run_claim_bytes(content: bytes, run_id: str) -> None:
    try:
        claim = json.loads(
            content.decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                LedgerError("judge-owned run claim is invalid")),
        )
    except (
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
        ManifestError,
    ) as error:
        raise LedgerError("judge-owned run claim is invalid") from error
    if (
        not isinstance(claim, dict)
        or set(claim) != {"schemaVersion", "runID", "state"}
        or not _has_exact_json_type(claim.get("schemaVersion"), int)
        or claim["schemaVersion"] != 1
        or not _has_exact_json_type(claim.get("runID"), str)
        or claim["runID"] != run_id
        or not _has_exact_json_type(claim.get("state"), str)
        or claim["state"] != "claimed"
    ):
        raise LedgerError("judge-owned run claim is invalid")


def _run_directory_path(
    run_id: str,
    output_root: str | Path | None,
) -> Path:
    if (
        not _has_exact_json_type(run_id, str)
        or RUN_ID_PATTERN.fullmatch(run_id) is None
    ):
        raise LedgerError("run identifier is invalid")
    root = _validated_run_root(
        output_root,
        error_type=LedgerError,
        require_exists=True,
    )
    run_directory = root / run_id
    if (
        not run_directory.is_dir()
        or run_directory.is_symlink()
    ):
        raise LedgerError("judge-owned run claim is unavailable")
    return run_directory


def _run_directory(run_id: str, output_root: str | Path | None) -> Path:
    run_directory = _run_directory_path(run_id, output_root)
    claim_path = run_directory / "run-claim.json"
    _validate_run_claim_bytes(
        _read_unique_regular_bytes(
            claim_path,
            error_type=LedgerError,
            name="judge-owned run claim",
        ),
        run_id,
    )
    return run_directory


def _decode_ledger_events(content: bytes) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        raw_ledger = content.decode("utf-8")
        for line in raw_ledger.splitlines():
            decoded = json.loads(line, object_pairs_hook=_strict_object)
            if not isinstance(decoded, dict):
                raise LedgerError("attempt ledger event is invalid")
            events.append(decoded)
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
        ManifestError,
    ) as error:
        raise LedgerError("attempt ledger is invalid") from error
    return events


def _load_ledger_events(ledger_path: Path) -> list[dict[str, Any]]:
    if not ledger_path.exists():
        return []
    return _decode_ledger_events(
        _read_unique_regular_bytes(
            ledger_path,
            error_type=LedgerError,
            name="attempt ledger",
        )
    )


def _load_ledger_events_at(
    directory_descriptor: int,
) -> list[dict[str, Any]]:
    if not _validate_existing_mutable_file_at(
        directory_descriptor,
        "attempt-ledger.jsonl",
        error_type=LedgerError,
        name="attempt ledger",
    ):
        return []
    return _decode_ledger_events(
        _read_unique_regular_bytes_at(
            directory_descriptor,
            "attempt-ledger.jsonl",
            error_type=LedgerError,
            name="attempt ledger",
        )
    )


def _derive_attempt_states(
    events: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    proposal_fields = {
        "schemaVersion",
        "eventType",
        "clipID",
        "state",
        "attemptCount",
        "proposalCategory",
        "productionMutationAuthorized",
        "touchedFamilyGraduation",
        "phase3Graduation",
    }
    attempt_fields = {
        "schemaVersion",
        "eventType",
        "clipID",
        "state",
        "attemptCount",
        "sourceCommit",
        "redTestReceipt",
        "greenTestReceipt",
        "negativeGuardReceipt",
        "implementationReviewReceipt",
        "productionMutationPerformedByJudge",
        "touchedFamilyGraduation",
        "phase3Graduation",
    }
    rerender_fields = {
        "schemaVersion",
        "eventType",
        "clipID",
        "state",
        "attemptCount",
        "renderContentSHA256",
        "audioRetestReceipt",
        "familyRegressionReceipt",
        "outcome",
        "productionMutationPerformedByJudge",
        "touchedFamilyGraduation",
        "phase3Graduation",
    }
    states: dict[str, dict[str, Any]] = {}
    used_receipts: set[str] = set()
    for sequence, event in enumerate(events, start=1):
        clip_id = event.get("clipID")
        state = event.get("state")
        attempt_count = event.get("attemptCount")
        if (
            not _has_exact_json_type(event.get("schemaVersion"), int)
            or event["schemaVersion"] != 1
            or not validate_clip_id(clip_id)
            or not _has_exact_json_type(attempt_count, int)
            or not 0 <= attempt_count <= 2
        ):
            raise LedgerError("attempt ledger event is invalid")
        previous = states.get(clip_id)
        event_type = event.get("eventType")
        if event_type == "proposal_emitted":
            if (
                set(event) != proposal_fields
                or previous is not None
                or state != "proposal_emitted"
                or attempt_count != 0
                or not _is_exact_string_choice(
                    event.get("proposalCategory"),
                    CATEGORIES,
                )
                or event.get("productionMutationAuthorized") is not False
            ):
                raise LedgerError("attempt ledger transition is invalid")
        elif event_type == "attempt_recorded":
            receipt_names = (
                "redTestReceipt",
                "greenTestReceipt",
                "negativeGuardReceipt",
                "implementationReviewReceipt",
            )
            receipts = [event.get(name) for name in receipt_names]
            if (
                set(event) != attempt_fields
                or previous is None
                or previous["state"] != "proposal_emitted"
                or previous["attemptCount"] >= 2
                or state != "rerender_pending"
                or attempt_count != previous["attemptCount"] + 1
                or not _has_exact_json_type(
                    event.get("sourceCommit"),
                    str,
                )
                or SOURCE_COMMIT_PATTERN.fullmatch(
                    event["sourceCommit"]
                )
                is None
                or not all(_valid_receipt_hash(value) for value in receipts)
                or len(set(receipts)) != len(receipts)
                or used_receipts.intersection(receipts)
                or event.get("productionMutationPerformedByJudge") is not False
            ):
                raise LedgerError("attempt ledger transition is invalid")
            used_receipts.update(receipts)
        elif event_type == "rerender_recorded":
            evidence = [
                event.get("renderContentSHA256"),
                event.get("audioRetestReceipt"),
                event.get("familyRegressionReceipt"),
            ]
            outcome = event.get("outcome")
            expected_state = (
                "resolved"
                if outcome == "pass"
                else "morning_review"
                if previous is not None and previous["attemptCount"] == 2
                else "proposal_emitted"
            )
            if (
                set(event) != rerender_fields
                or previous is None
                or previous["state"] != "rerender_pending"
                or attempt_count != previous["attemptCount"]
                or not _is_exact_string_choice(outcome, {"pass", "fail"})
                or state != expected_state
                or not all(_valid_receipt_hash(value) for value in evidence)
                or len(set(evidence)) != len(evidence)
                or used_receipts.intersection(evidence[1:])
                or event.get("productionMutationPerformedByJudge") is not False
            ):
                raise LedgerError("attempt ledger transition is invalid")
            used_receipts.update(evidence[1:])
        else:
            raise LedgerError("attempt ledger event is invalid")
        if (
            event.get("touchedFamilyGraduation") is not False
            or event.get("phase3Graduation") is not False
        ):
            raise LedgerError("attempt ledger proof boundary is invalid")
        states[clip_id] = {
            "clipID": clip_id,
            "state": state,
            "attemptCount": attempt_count,
            "touchedFamilyGraduation": False,
            "phase3Graduation": False,
            "lastEventSequence": sequence,
        }
        unresolved = [
            value
            for value in states.values()
            if value["state"] in {"proposal_emitted", "rerender_pending"}
        ]
        if len(unresolved) > 1:
            raise LedgerError("only one unresolved proposal is permitted")
    return states


def _write_attempt_snapshot(
    run_directory: Path,
    states: dict[str, dict[str, Any]],
) -> None:
    _atomic_write_json(
        run_directory / "attempt-state.json",
        {
            "schemaVersion": 1,
            "clips": {key: states[key] for key in sorted(states)},
        },
        error_type=LedgerError,
        artifact_name="attempt state",
    )


def _write_attempt_snapshot_at(
    directory_descriptor: int,
    run_directory: Path,
    expected_run_identity: tuple[int, int],
    states: dict[str, dict[str, Any]],
) -> None:
    _atomic_write_json_at(
        directory_descriptor,
        run_directory,
        expected_run_identity,
        "attempt-state.json",
        {
            "schemaVersion": 1,
            "clips": {key: states[key] for key in sorted(states)},
        },
        artifact_name="attempt state",
    )


def _append_ledger_event_locked(
    run_directory: Path,
    events: list[dict[str, Any]],
    event: dict[str, Any],
) -> dict[str, Any]:
    ledger_path = run_directory / "attempt-ledger.jsonl"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(ledger_path, flags, 0o600)
        with os.fdopen(descriptor, "a", encoding="utf-8") as ledger:
            _require_unique_regular_descriptor(
                ledger.fileno(),
                error_type=LedgerError,
                name="attempt ledger",
            )
            ledger.write(
                json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
            )
            ledger.flush()
            os.fsync(ledger.fileno())
            _require_unique_regular_descriptor(
                ledger.fileno(),
                error_type=LedgerError,
                name="attempt ledger",
            )
    except LedgerError:
        raise
    except OSError as error:
        raise LedgerError("attempt ledger is invalid") from error
    events.append(event)
    states = _derive_attempt_states(events)
    _write_attempt_snapshot(run_directory, states)
    return states[event["clipID"]]


def _recover_committed_event_locked(
    run_directory: Path,
    events: list[dict[str, Any]],
    states: dict[str, dict[str, Any]],
    expected_event: dict[str, Any],
    *,
    publish_morning_queue: bool = False,
) -> dict[str, Any] | None:
    if not events:
        return None
    committed = events[-1]
    if (
        committed.get("eventType") != expected_event["eventType"]
        or committed.get("clipID") != expected_event["clipID"]
    ):
        return None
    if committed != expected_event:
        raise LedgerError("committed transition has a conflicting replay")
    queue_plan: tuple[list[dict[str, Any]], list[dict[str, Any]]] | None = None
    if publish_morning_queue:
        current_queue = _load_morning_queue(run_directory)
        queue_plan = (
            current_queue,
            _plan_morning_queue(events, current_queue),
        )
    _write_attempt_snapshot(run_directory, states)
    result = states[expected_event["clipID"]]
    if queue_plan is not None:
        _publish_morning_queue_plan(
            run_directory,
            current_queue=queue_plan[0],
            planned_queue=queue_plan[1],
        )
    return result


def _with_ledger_lock(
    run_directory: Path,
    operation: Callable[[list[dict[str, Any]]], Any],
) -> Any:
    lock_path = run_directory / ".attempt-ledger.lock"
    for artifact_path, artifact_name in (
        (lock_path, "attempt ledger lock"),
        (run_directory / "attempt-ledger.jsonl", "attempt ledger"),
        (run_directory / "attempt-state.json", "attempt state"),
        (run_directory / "morning-queue.json", "morning queue"),
    ):
        _validate_existing_mutable_file(
            artifact_path,
            error_type=LedgerError,
            name=artifact_name,
        )
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
        _require_unique_regular_descriptor(
            descriptor,
            error_type=LedgerError,
            name="attempt ledger lock",
        )
    except LedgerError:
        raise
    except OSError as error:
        raise LedgerError("attempt ledger lock is invalid") from error
    with os.fdopen(descriptor, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            events = _load_ledger_events(run_directory / "attempt-ledger.jsonl")
            return operation(events)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def _emit_proposal(
    *,
    run_id: str,
    clip_id: str,
    category: str,
    output_root: str | Path | None,
) -> bool:
    if not validate_clip_id(clip_id) or category not in CATEGORIES:
        raise LedgerError("proposal evidence is invalid")
    run_directory = _run_directory(run_id, output_root)
    event = {
        "schemaVersion": 1,
        "eventType": "proposal_emitted",
        "clipID": clip_id,
        "state": "proposal_emitted",
        "attemptCount": 0,
        "proposalCategory": category,
        "productionMutationAuthorized": False,
        "touchedFamilyGraduation": False,
        "phase3Graduation": False,
    }

    def operation(events: list[dict[str, Any]]) -> bool:
        states = _derive_attempt_states(events)
        recovered = _recover_committed_event_locked(
            run_directory,
            events,
            states,
            event,
        )
        if recovered is not None:
            return True
        if clip_id in states:
            return states[clip_id]["state"] in {
                "proposal_emitted",
                "rerender_pending",
            }
        if any(
            state["state"] in {"proposal_emitted", "rerender_pending"}
            for state in states.values()
        ):
            return False
        _append_ledger_event_locked(
            run_directory,
            events,
            event,
        )
        return True

    return _with_ledger_lock(run_directory, operation)


def read_attempt_state(
    *,
    run_id: str,
    clip_id: str,
    output_root: str | Path | None = None,
) -> dict[str, Any]:
    if not validate_clip_id(clip_id):
        raise LedgerError("clip identifier is invalid")
    run_directory = _run_directory(run_id, output_root)

    def operation(events: list[dict[str, Any]]) -> dict[str, Any]:
        state = _derive_attempt_states(events).get(clip_id)
        if state is None:
            raise LedgerError("clip has no attempt state")
        return state

    return _with_ledger_lock(run_directory, operation)


def _valid_receipt_hash(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def record_attempt(
    *,
    run_id: str,
    clip_id: str,
    source_commit: str | None,
    red_test_receipt: str,
    green_test_receipt: str,
    negative_guard_receipt: str,
    implementation_review_receipt: str,
    output_root: str | Path | None = None,
) -> dict[str, Any]:
    """Record one externally completed reviewed change, never perform the change."""
    if not validate_clip_id(clip_id):
        raise LedgerError("clip identifier is invalid")
    if (
        not isinstance(source_commit, str)
        or SOURCE_COMMIT_PATTERN.fullmatch(source_commit) is None
    ):
        raise LedgerError("source commit is required")
    receipts = {
        "redTestReceipt": red_test_receipt,
        "greenTestReceipt": green_test_receipt,
        "negativeGuardReceipt": negative_guard_receipt,
        "implementationReviewReceipt": implementation_review_receipt,
    }
    if not all(_valid_receipt_hash(value) for value in receipts.values()):
        raise LedgerError("all reviewed workflow receipts are required")
    if len(set(receipts.values())) != len(receipts):
        raise LedgerError("reviewed workflow receipts must be distinct")
    run_directory = _run_directory(run_id, output_root)

    def operation(events: list[dict[str, Any]]) -> dict[str, Any]:
        states = _derive_attempt_states(events)

        def event_for(attempt_count: int) -> dict[str, Any]:
            return {
                "schemaVersion": 1,
                "eventType": "attempt_recorded",
                "clipID": clip_id,
                "state": "rerender_pending",
                "attemptCount": attempt_count,
                "sourceCommit": source_commit,
                **receipts,
                "productionMutationPerformedByJudge": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            }

        if (
            events
            and events[-1].get("eventType") == "attempt_recorded"
            and events[-1].get("clipID") == clip_id
        ):
            recovered = _recover_committed_event_locked(
                run_directory,
                events,
                states,
                event_for(events[-1]["attemptCount"]),
            )
            if recovered is None:
                raise LedgerError("committed transition replay is invalid")
            return recovered
        current = states.get(clip_id)
        if (
            current is None
            or current["state"] != "proposal_emitted"
            or current["attemptCount"] >= 2
        ):
            raise LedgerError("clip is not ready for a reviewed attempt")
        used_receipts = {
            value
            for event in events
            for key, value in event.items()
            if key.endswith("Receipt") and isinstance(value, str)
        }
        if used_receipts.intersection(receipts.values()):
            raise LedgerError("reviewed workflow receipt was already used")
        return _append_ledger_event_locked(
            run_directory,
            events,
            event_for(current["attemptCount"] + 1),
        )

    return _with_ledger_lock(run_directory, operation)


def _terminal_morning_queue_entry(
    ledger_event: dict[str, Any],
    ledger_event_sequence: int,
) -> dict[str, Any]:
    ledger_event_sha256 = hashlib.sha256(
        json.dumps(
            ledger_event,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return {
        "clipID": ledger_event["clipID"],
        "queueCategory": "morning_review",
        "reasons": ["repeated_regression_failure"],
        "ledgerEventSequence": ledger_event_sequence,
        "ledgerEventSHA256": ledger_event_sha256,
    }


def _required_terminal_queue_entries(
    events: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    return [
        _terminal_morning_queue_entry(event, sequence)
        for sequence, event in enumerate(events, start=1)
        if event.get("eventType") == "rerender_recorded"
        and event.get("state") == "morning_review"
    ]


def _decode_morning_queue(content: bytes) -> list[dict[str, Any]]:
    try:
        queue = json.loads(
            content.decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                LedgerError("morning queue is invalid")),
        )
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
        ManifestError,
    ) as error:
        raise LedgerError("morning queue is invalid") from error
    if not isinstance(queue, list) or not all(
        isinstance(item, dict) for item in queue
    ):
        raise LedgerError("morning queue is invalid")
    return queue


def _load_morning_queue(run_directory: Path) -> list[dict[str, Any]]:
    queue_path = run_directory / "morning-queue.json"
    _validate_existing_mutable_file(
        queue_path,
        error_type=LedgerError,
        name="morning queue",
    )
    if not queue_path.exists():
        return []
    return _decode_morning_queue(
        _read_unique_regular_bytes(
            queue_path,
            error_type=LedgerError,
            name="morning queue",
        )
    )


def _load_morning_queue_at(
    directory_descriptor: int,
) -> list[dict[str, Any]]:
    if not _validate_existing_mutable_file_at(
        directory_descriptor,
        "morning-queue.json",
        error_type=LedgerError,
        name="morning queue",
    ):
        return []
    return _decode_morning_queue(
        _read_unique_regular_bytes_at(
            directory_descriptor,
            "morning-queue.json",
            error_type=LedgerError,
            name="morning queue",
        )
    )


def _plan_morning_queue(
    events: list[dict[str, Any]],
    current_queue: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    evaluation_fields = {"clipID", "queueCategory", "reasons"}
    ledger_fields = evaluation_fields | {
        "ledgerEventSequence",
        "ledgerEventSHA256",
    }
    evaluation_categories = {"provisional_review", "morning_review"}
    evaluation_reasons = {
        "transport_failure",
        "model_refusal",
        "malformed_output",
        "low_confidence",
        "uncertain",
        "deterministic_disagreement",
        "proposal_blocked_by_existing",
    }
    required = _required_terminal_queue_entries(events)
    required_by_sequence = {
        entry["ledgerEventSequence"]: entry for entry in required
    }
    required_by_hash = {
        entry["ledgerEventSHA256"]: entry for entry in required
    }
    if len(required_by_sequence) != len(required) or len(required_by_hash) != len(
        required
    ):
        raise LedgerError("morning queue authority is ambiguous")

    planned: list[dict[str, Any]] = []
    included_ledger_identities: set[tuple[int, str]] = set()
    for item in current_queue:
        if set(item) == evaluation_fields:
            reasons = item.get("reasons")
            if (
                not validate_clip_id(item.get("clipID"))
                or not _is_exact_string_choice(
                    item.get("queueCategory"),
                    evaluation_categories,
                )
                or not _has_exact_json_type(reasons, list)
                or not reasons
                or not all(
                    _has_exact_json_type(reason, str)
                    for reason in reasons
                )
                or len(set(reasons)) != len(reasons)
                or not all(reason in evaluation_reasons for reason in reasons)
            ):
                raise LedgerError("morning queue evaluation row is invalid")
            planned.append(item)
            continue
        if set(item) != ledger_fields:
            raise LedgerError("morning queue ledger row is invalid")
        sequence = item.get("ledgerEventSequence")
        event_hash = item.get("ledgerEventSHA256")
        if (
            not _has_exact_json_type(sequence, int)
            or not _has_exact_json_type(event_hash, str)
            or SHA256_PATTERN.fullmatch(event_hash) is None
        ):
            raise LedgerError("morning queue ledger identity is invalid")
        sequence_match = required_by_sequence.get(sequence)
        hash_match = required_by_hash.get(event_hash)
        if (
            sequence_match is None
            or hash_match is None
            or sequence_match is not hash_match
            or item != sequence_match
        ):
            raise LedgerError("morning queue conflicts with attempt ledger")
        identity = (sequence, event_hash)
        if identity not in included_ledger_identities:
            planned.append(sequence_match)
            included_ledger_identities.add(identity)

    for entry in required:
        identity = (
            entry["ledgerEventSequence"],
            entry["ledgerEventSHA256"],
        )
        if identity not in included_ledger_identities:
            planned.append(entry)
            included_ledger_identities.add(identity)
    return planned


def _publish_morning_queue_plan(
    run_directory: Path,
    *,
    current_queue: list[dict[str, Any]],
    planned_queue: list[dict[str, Any]],
) -> None:
    if planned_queue == current_queue:
        return
    _atomic_write_json(
        run_directory / "morning-queue.json",
        planned_queue,
        error_type=LedgerError,
        artifact_name="morning queue",
    )


def _publish_morning_queue_plan_at(
    directory_descriptor: int,
    run_directory: Path,
    expected_run_identity: tuple[int, int],
    *,
    current_queue: list[dict[str, Any]],
    planned_queue: list[dict[str, Any]],
) -> None:
    if planned_queue == current_queue:
        return
    _atomic_write_json_at(
        directory_descriptor,
        run_directory,
        expected_run_identity,
        "morning-queue.json",
        planned_queue,
        artifact_name="morning queue",
    )


def record_rerender(
    *,
    run_id: str,
    clip_id: str,
    render_content_sha256: str,
    audio_retest_receipt: str,
    family_regression_receipt: str,
    outcome: str,
    output_root: str | Path | None = None,
) -> dict[str, Any]:
    """Record external rerender/retest/regression evidence and advance the state."""
    if not validate_clip_id(clip_id):
        raise LedgerError("clip identifier is invalid")
    if not all(
        _valid_receipt_hash(value)
        for value in (
            render_content_sha256,
            audio_retest_receipt,
            family_regression_receipt,
        )
    ):
        raise LedgerError("rerender evidence is invalid")
    if outcome not in {"pass", "fail"}:
        raise LedgerError("rerender outcome is invalid")
    run_directory = _run_directory(run_id, output_root)

    def operation(events: list[dict[str, Any]]) -> dict[str, Any]:
        states = _derive_attempt_states(events)

        def event_for(
            attempt_count: int,
            state: str,
        ) -> dict[str, Any]:
            return {
                "schemaVersion": 1,
                "eventType": "rerender_recorded",
                "clipID": clip_id,
                "state": state,
                "attemptCount": attempt_count,
                "renderContentSHA256": render_content_sha256,
                "audioRetestReceipt": audio_retest_receipt,
                "familyRegressionReceipt": family_regression_receipt,
                "outcome": outcome,
                "productionMutationPerformedByJudge": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            }

        if (
            events
            and events[-1].get("eventType") == "rerender_recorded"
            and events[-1].get("clipID") == clip_id
        ):
            expected_event = event_for(
                events[-1]["attemptCount"],
                events[-1]["state"],
            )
            recovered = _recover_committed_event_locked(
                run_directory,
                events,
                states,
                expected_event,
                publish_morning_queue=(
                    events[-1]["state"] == "morning_review"
                ),
            )
            if recovered is None:
                raise LedgerError("committed transition replay is invalid")
            return recovered
        current = states.get(clip_id)
        if current is None or current["state"] != "rerender_pending":
            raise LedgerError("clip is not waiting for a rerender result")
        if outcome == "pass":
            state = "resolved"
        elif current["attemptCount"] >= 2:
            state = "morning_review"
        else:
            state = "proposal_emitted"
        event = event_for(current["attemptCount"], state)
        result = _append_ledger_event_locked(
            run_directory,
            events,
            event,
        )
        if state == "morning_review":
            current_queue = _load_morning_queue(run_directory)
            _publish_morning_queue_plan(
                run_directory,
                current_queue=current_queue,
                planned_queue=_plan_morning_queue(events, current_queue),
            )
        return result

    return _with_ledger_lock(run_directory, operation)


def _with_recovery_ledger_lock(
    run_directory: Path,
    directory_descriptor: int,
    expected_run_identity: tuple[int, int],
    run_id: str,
    operation: Callable[
        [
            list[dict[str, Any]],
            dict[str, dict[str, Any]],
            list[dict[str, Any]],
            list[dict[str, Any]],
        ],
        Any,
    ],
) -> Any:
    _require_run_directory_identity(
        run_directory,
        expected_run_identity,
    )
    for filename, artifact_name in (
        ("attempt-ledger.jsonl", "attempt ledger"),
        ("attempt-state.json", "attempt state"),
        ("morning-queue.json", "morning queue"),
    ):
        _validate_existing_mutable_file_at(
            directory_descriptor,
            filename,
            error_type=LedgerError,
            name=artifact_name,
        )
    if not _validate_existing_mutable_file_at(
        directory_descriptor,
        ".attempt-ledger.lock",
        error_type=LedgerError,
        name="attempt ledger lock",
    ):
        raise LedgerError("attempt ledger lock is unavailable")
    flags = os.O_RDWR | os.O_NOFOLLOW
    descriptor: int | None = None
    try:
        descriptor = os.open(
            ".attempt-ledger.lock",
            flags,
            dir_fd=directory_descriptor,
        )
        _require_unique_regular_descriptor(
            descriptor,
            error_type=LedgerError,
            name="attempt ledger lock",
        )
    except LedgerError:
        if descriptor is not None:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        raise LedgerError("attempt ledger lock is invalid") from error
    try:
        with os.fdopen(descriptor, "a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                _require_unique_regular_descriptor(
                    lock.fileno(),
                    error_type=LedgerError,
                    name="attempt ledger lock",
                )
                _require_run_directory_identity(
                    run_directory,
                    expected_run_identity,
                )
                _validate_run_claim_bytes(
                    _read_unique_regular_bytes_at(
                        directory_descriptor,
                        "run-claim.json",
                        error_type=LedgerError,
                        name="judge-owned run claim",
                    ),
                    run_id,
                )
                events = _load_ledger_events_at(directory_descriptor)
                if not events:
                    raise LedgerError("attempt ledger is empty")
                states = _derive_attempt_states(events)
                current_queue = _load_morning_queue_at(directory_descriptor)
                planned_queue = _plan_morning_queue(events, current_queue)
                return operation(
                    events,
                    states,
                    current_queue,
                    planned_queue,
                )
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    except LedgerError:
        raise
    except OSError as error:
        raise LedgerError("attempt ledger lock is invalid") from error


def recover_run(
    *,
    run_id: str,
    output_root: str | Path | None = None,
) -> dict[str, Any]:
    """Republish ledger-derived local artifacts without evaluating audio."""
    run_directory = _run_directory_path(run_id, output_root)
    run_identity = _run_directory_identity(run_directory)
    directory_descriptor = _open_run_directory_descriptor(
        run_directory,
        run_identity,
    )
    try:
        _validate_run_claim_bytes(
            _read_unique_regular_bytes_at(
                directory_descriptor,
                "run-claim.json",
                error_type=LedgerError,
                name="judge-owned run claim",
            ),
            run_id,
        )
        preflight_events = _load_ledger_events_at(directory_descriptor)
        if not preflight_events:
            raise LedgerError("attempt ledger is empty")
        _derive_attempt_states(preflight_events)
        preflight_queue = _load_morning_queue_at(directory_descriptor)
        _plan_morning_queue(preflight_events, preflight_queue)

        def operation(
            events: list[dict[str, Any]],
            states: dict[str, dict[str, Any]],
            current_queue: list[dict[str, Any]],
            planned_queue: list[dict[str, Any]],
        ) -> dict[str, Any]:
            terminal_queue_entries = _required_terminal_queue_entries(events)
            _write_attempt_snapshot_at(
                directory_descriptor,
                run_directory,
                run_identity,
                states,
            )
            _publish_morning_queue_plan_at(
                directory_descriptor,
                run_directory,
                run_identity,
                current_queue=current_queue,
                planned_queue=planned_queue,
            )
            return {
                "schemaVersion": 1,
                "runID": run_id,
                "status": "RECOVERED",
                "ledgerEventCount": len(events),
                "clipStateCount": len(states),
                "attemptStatePublished": True,
                "morningQueueEntryCount": len(terminal_queue_entries),
                "requestCount": 0,
                "transportAttemptCount": 0,
            }

        return _with_recovery_ledger_lock(
            run_directory,
            directory_descriptor,
            run_identity,
            run_id,
            operation,
        )
    finally:
        os.close(directory_descriptor)


def _result_proof_boundaries(label_status: str) -> dict[str, Any]:
    provisional = label_status == "provisional"
    return {
        "evidenceCategory":
            "provisional_evidence" if provisional else "machine_evidence",
        "accuracyContribution": False,
        "humanLabelContribution": False,
        "humanListeningContribution": False,
        "qualificationContribution": False,
        "touchedFamilyGraduation": False,
        "phase3Graduation": False,
    }


def run_evaluation(
    *,
    manifest_path: str | Path,
    provenance_authority_path: str | Path | None = None,
    run_id: str,
    dry_run: bool,
    output_root: str | Path | None = None,
    environment: Mapping[str, str] | None = None,
    transport: Callable[[dict[str, Any], str], dict[str, Any]] = _post_chat_completion,
) -> dict[str, Any]:
    """Admit, cap, optionally evaluate, and persist a redacted run receipt."""
    if (
        not _has_exact_json_type(run_id, str)
        or RUN_ID_PATTERN.fullmatch(run_id) is None
    ):
        raise ManifestError("run identifier is invalid")
    admission = _admit_manifest_with_authority(
        manifest_path,
        provenance_authority_path,
    )
    clips = admission.clips
    baseline_estimates = [
        _request_estimate(clip, build_request_body(clip))
        for clip in clips
    ]
    prospective_corpus_cost = 0.0
    for request_count, estimate in enumerate(baseline_estimates):
        enforce_prospective_cap(
            request_count=request_count,
            estimated_cost_usd=prospective_corpus_cost,
            next_request_estimate_usd=estimate["estimatedCostUSD"],
        )
        prospective_corpus_cost += estimate["estimatedCostUSD"]

    run_directory = _claim_run(run_id, output_root)
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "runID": run_id,
        "status": "DRY_RUN_COMPLETE" if dry_run else "WAITING_FOR_USER",
        "apiEvaluationStatus": "NOT_RUN_DRY_RUN" if dry_run else None,
        "requestedModelID": MODEL_ID,
        "returnedModelIDs": [],
        "admittedClipCount": len(clips),
        "requestCount": 0,
        "transportAttemptCount": 0,
        "estimatedCostUSD": round(prospective_corpus_cost, 8),
        "prospectiveCorpusCostUSD": round(prospective_corpus_cost, 8),
        "pricing": PRICING_CONFIG,
        "corpusIdentity": admission.corpus_identity,
        "manifestContentSHA256": admission.manifest_content_sha256,
        "provenanceAuthoritySHA256":
            admission.provenance_authority_sha256,
        "results": [],
        "morningQueue": [],
        "proofBoundaries": {
            "machineEvidenceIsHumanLabel": False,
            "machineEvidenceIsHumanListening": False,
            "machineEvidenceContributesAccuracy": False,
            "authorizesPhase3": False,
        },
    }
    _atomic_write_json(run_directory / "receipt.json", receipt)
    if dry_run:
        return receipt

    current_environment = environment if environment is not None else os.environ
    api_key = current_environment.get("OPENAI_API_KEY")
    if not api_key:
        return receipt

    receipt["status"] = "RUNNING"
    actual_request_estimate = 0.0
    receipt["estimatedCostUSD"] = 0.0
    _atomic_write_json(run_directory / "receipt.json", receipt)
    for clip_index, clip in enumerate(clips):
        remaining_clip_count = len(clips) - clip_index - 1
        remaining_baseline_estimate = sum(
            estimate["estimatedCostUSD"]
            for estimate in baseline_estimates[clip_index + 1:]
        )
        response: dict[str, Any] | None = None
        retry_attempted = False
        retry_blocked_by_cap = False
        failure: str | None = None
        clip_estimated_cost = 0.0
        for attempt in range(2):
            body = build_request_body(clip)
            estimate = _request_estimate(clip, body)
            next_estimated_cost = estimate["estimatedCostUSD"]
            if attempt == 1:
                try:
                    # Reserve one baseline request for every admitted clip that
                    # has not yet run. The hard caps win over an optional retry.
                    enforce_prospective_cap(
                        request_count=(
                            receipt["requestCount"] + remaining_clip_count
                        ),
                        estimated_cost_usd=(
                            actual_request_estimate + remaining_baseline_estimate
                        ),
                        next_request_estimate_usd=next_estimated_cost,
                    )
                except ManifestError:
                    retry_blocked_by_cap = True
                    failure = "transport_failure"
                    break
                retry_attempted = True
            enforce_prospective_cap(
                request_count=receipt["requestCount"],
                estimated_cost_usd=actual_request_estimate,
                next_request_estimate_usd=next_estimated_cost,
            )
            request_number = receipt["requestCount"] + 1
            _reserve_request(
                run_directory=run_directory,
                request_number=request_number,
                clip_id=clip.clip_id,
                estimate=estimate,
            )
            receipt["requestCount"] = request_number
            receipt["transportAttemptCount"] = request_number
            actual_request_estimate += next_estimated_cost
            clip_estimated_cost += next_estimated_cost
            receipt["estimatedCostUSD"] = round(actual_request_estimate, 8)
            _atomic_write_json(run_directory / "receipt.json", receipt)
            try:
                response = transport(body, api_key)
                break
            except TransientTransportError:
                if attempt == 0:
                    continue
                failure = "transport_failure"
            except PermanentTransportError:
                failure = "transport_failure"
            break

        verdict: dict[str, Any] | None = None
        validation_outcome = "not_validated"
        if failure is None and response is None:
            failure = "malformed_output"
        if failure is None and response is not None:
            if not _response_envelope_is_valid(response):
                failure = "malformed_output"
            returned_model = (
                _validated_returned_model_id(response["model"])
                if failure is None
                else None
            )
            if returned_model is None:
                failure = "malformed_output"
            else:
                receipt["returnedModelIDs"].append(returned_model)
            if failure is None and response.get("refusal") is not None:
                failure = "model_refusal"
            elif (
                failure is None
                and not _has_exact_json_type(response.get("content"), str)
            ):
                failure = "malformed_output"
            elif failure is None:
                try:
                    verdict = parse_verdict(
                        response["content"],
                        expected_clip_id=clip.clip_id,
                    )
                    validation_outcome = (
                        "validated_after_retry" if retry_attempted else "validated"
                    )
                except ResponseValidationError:
                    failure = "malformed_output"

        reasons = _morning_reasons(verdict, failure=failure)
        response_model = (
            response.get("model")
            if _has_exact_json_type(response, dict)
            else None
        )
        response_usage = (
            response.get("usage")
            if _has_exact_json_type(response, dict)
            else None
        )
        result = {
            "clipID": clip.clip_id,
            "audioSHA256": clip.audio_sha256,
            "sourceCommit": clip.source_commit,
            "renderIdentity": clip.render_identity,
            "requestedModelID": MODEL_ID,
            "returnedModelID": _validated_returned_model_id(response_model),
            "estimatedCostUSD": round(clip_estimated_cost, 8),
            "usage": _sanitized_usage(response_usage),
            "retryOutcome": (
                "retry_blocked_by_cap"
                if retry_blocked_by_cap
                else "retried_once"
                if retry_attempted
                else "not_retried"
            ),
            "validationOutcome": validation_outcome,
            "verdict": (
                {
                    key: verdict[key]
                    for key in ("clipID", "verdict", "confidence", "category")
                }
                if verdict is not None
                else None
            ),
            **_result_proof_boundaries(clip.label_status),
        }
        receipt["results"].append(result)
        if verdict is not None and verdict["verdict"] == "fail":
            proposal_emitted = _emit_proposal(
                run_id=run_id,
                clip_id=clip.clip_id,
                category=verdict["category"],
                output_root=output_root,
            )
            if not proposal_emitted:
                reasons.append("proposal_blocked_by_existing")
        if reasons:
            receipt["morningQueue"].append(
                {
                    "clipID": clip.clip_id,
                    "queueCategory":
                        "provisional_review"
                        if clip.label_status == "provisional"
                        else "morning_review",
                    "reasons": reasons,
                }
            )
        _atomic_write_json(run_directory / "morning-queue.json", receipt["morningQueue"])
        _atomic_write_json(run_directory / "receipt.json", receipt)

    receipt["estimatedCostUSD"] = round(actual_request_estimate, 8)
    receipt["returnedModelIDs"] = sorted(set(receipt["returnedModelIDs"]))
    receipt["status"] = "COMPLETED"
    receipt["apiEvaluationStatus"] = (
        "needs_review" if receipt["morningQueue"] else "passed"
    )
    _atomic_write_json(run_directory / "morning-queue.json", receipt["morningQueue"])
    _atomic_write_json(run_directory / "receipt.json", receipt)
    return receipt


def _build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evaluate only admitted public-domain/synthetic pronunciation audio."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    evaluate = subparsers.add_parser("evaluate")
    evaluate.add_argument("--manifest", required=True, type=Path)
    evaluate.add_argument("--provenance-authority", required=True, type=Path)
    evaluate.add_argument("--run-id", required=True)
    evaluate.add_argument("--dry-run", action="store_true")
    evaluate.add_argument("--output-root", type=Path)

    attempt = subparsers.add_parser("record-attempt")
    attempt.add_argument("--run-id", required=True)
    attempt.add_argument("--clip-id", required=True)
    attempt.add_argument("--source-commit", required=True)
    attempt.add_argument("--red-test-receipt", required=True)
    attempt.add_argument("--green-test-receipt", required=True)
    attempt.add_argument("--negative-guard-receipt", required=True)
    attempt.add_argument("--implementation-review-receipt", required=True)
    attempt.add_argument("--output-root", type=Path)

    rerender = subparsers.add_parser("record-rerender")
    rerender.add_argument("--run-id", required=True)
    rerender.add_argument("--clip-id", required=True)
    rerender.add_argument("--render-content-sha256", required=True)
    rerender.add_argument("--audio-retest-receipt", required=True)
    rerender.add_argument("--family-regression-receipt", required=True)
    rerender.add_argument("--outcome", choices=("pass", "fail"), required=True)
    rerender.add_argument("--output-root", type=Path)

    recover = subparsers.add_parser("recover")
    recover.add_argument("--run-id", required=True)
    recover.add_argument("--output-root", type=Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_argument_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "evaluate":
            result = run_evaluation(
                manifest_path=options.manifest,
                provenance_authority_path=options.provenance_authority,
                run_id=options.run_id,
                dry_run=options.dry_run,
                output_root=options.output_root,
            )
        elif options.command == "record-attempt":
            result = record_attempt(
                run_id=options.run_id,
                clip_id=options.clip_id,
                source_commit=options.source_commit,
                red_test_receipt=options.red_test_receipt,
                green_test_receipt=options.green_test_receipt,
                negative_guard_receipt=options.negative_guard_receipt,
                implementation_review_receipt=options.implementation_review_receipt,
                output_root=options.output_root,
            )
        elif options.command == "record-rerender":
            result = record_rerender(
                run_id=options.run_id,
                clip_id=options.clip_id,
                render_content_sha256=options.render_content_sha256,
                audio_retest_receipt=options.audio_retest_receipt,
                family_regression_receipt=options.family_regression_receipt,
                outcome=options.outcome,
                output_root=options.output_root,
            )
        else:
            result = recover_run(
                run_id=options.run_id,
                output_root=options.output_root,
            )
    except (ManifestError, ResponseValidationError, LedgerError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
