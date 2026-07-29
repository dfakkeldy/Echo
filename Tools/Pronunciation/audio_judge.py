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
ALLOWED_PROVENANCE = {"public-domain", "synthetic"}
ALLOWED_LABEL_STATUS = {"human-labelled", "provisional"}
MEDIA_TYPES = {
    "audio/mpeg": ("mp3", ".mp3"),
    "audio/wav": ("wav", ".wav"),
}
MANIFEST_FIELDS = {"schemaVersion", "corpusIdentity", "clips"}
CLIP_FIELDS = {
    "clipID",
    "provenance",
    "labelStatus",
    "mediaType",
    "durationSeconds",
    "audioSHA256",
    "corpusID",
    "deterministicExpectation",
    "sourceCommit",
    "renderIdentity",
    "estimatedTextInputTokens",
    "estimatedAudioInputTokens",
    "maxTextOutputTokens",
}
MAXIMUM_CLIP_DURATION_SECONDS = 15.0
_DURATION_TOLERANCE_SECONDS = 0.001
MAXIMUM_REQUESTS = 200
MAXIMUM_ESTIMATED_COST_USD = 10.0
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
    "estimationRule": "declared-token-upper-bounds-v1",
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
    corpus_id: str
    deterministic_expectation: str
    source_commit: str
    render_identity: str
    estimated_text_input_tokens: int
    estimated_audio_input_tokens: int
    max_text_output_tokens: int
    _audio_path: Path


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


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError("duplicate JSON key")
        result[key] = value
    return result


def _load_strict_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ManifestError("non-finite JSON number")),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError("manifest is not readable strict JSON") from error


def _require_exact_fields(value: Any, fields: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ManifestError(f"{name} fields do not match the contract")
    return value


def _is_positive_bounded_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value <= 1_000_000


def _probe_audio_duration(path: Path) -> float:
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
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        duration = float(result.stdout.strip())
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise ManifestError("trusted media duration probe failed") from error
    if not math.isfinite(duration) or duration <= 0:
        raise ManifestError("trusted media duration is invalid")
    return duration


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
    if provenance not in ALLOWED_PROVENANCE:
        raise ManifestError("clip provenance is ineligible")
    if label_status not in ALLOWED_LABEL_STATUS:
        raise ManifestError("clip label status is ineligible")
    if media_type not in MEDIA_TYPES:
        raise ManifestError("clip media type is ineligible")
    audio_format, suffix = MEDIA_TYPES[media_type]

    declared_duration = clip["durationSeconds"]
    if (
        not isinstance(declared_duration, (int, float))
        or isinstance(declared_duration, bool)
        or not math.isfinite(declared_duration)
        or declared_duration <= 0
        or declared_duration > MAXIMUM_CLIP_DURATION_SECONDS
    ):
        raise ManifestError("declared clip duration is ineligible")

    audio_hash = clip["audioSHA256"]
    corpus_id = clip["corpusID"]
    expectation = clip["deterministicExpectation"]
    source_commit = clip["sourceCommit"]
    render_identity = clip["renderIdentity"]
    if not isinstance(audio_hash, str) or SHA256_PATTERN.fullmatch(audio_hash) is None:
        raise ManifestError("audio content hash is invalid")
    if not isinstance(corpus_id, str) or IDENTIFIER_PATTERN.fullmatch(corpus_id) is None:
        raise ManifestError("corpus identifier is invalid")
    if not isinstance(expectation, str) or IDENTIFIER_PATTERN.fullmatch(expectation) is None:
        raise ManifestError("deterministic expectation is invalid")
    if (
        not isinstance(source_commit, str)
        or SOURCE_COMMIT_PATTERN.fullmatch(source_commit) is None
    ):
        raise ManifestError("source commit is invalid")
    if (
        not isinstance(render_identity, str)
        or RENDER_IDENTITY_PATTERN.fullmatch(render_identity) is None
    ):
        raise ManifestError("render identity is invalid")

    estimator_values = (
        clip["estimatedTextInputTokens"],
        clip["estimatedAudioInputTokens"],
        clip["maxTextOutputTokens"],
    )
    if not all(_is_positive_bounded_integer(value) for value in estimator_values):
        raise ManifestError("cost-estimator input is invalid")

    audio_path = manifest_directory / f"{clip_id}{suffix}"
    try:
        audio_bytes = audio_path.read_bytes()
    except OSError as error:
        raise ManifestError("admitted audio file is unavailable") from error
    if hashlib.sha256(audio_bytes).hexdigest() != audio_hash:
        raise ManifestError("audio content hash mismatch")
    measured_duration = _probe_audio_duration(audio_path)
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
        corpus_id=corpus_id,
        deterministic_expectation=expectation,
        source_commit=source_commit,
        render_identity=render_identity,
        estimated_text_input_tokens=clip["estimatedTextInputTokens"],
        estimated_audio_input_tokens=clip["estimatedAudioInputTokens"],
        max_text_output_tokens=clip["maxTextOutputTokens"],
        _audio_path=audio_path,
    )


def admit_manifest(manifest_path: str | Path) -> list[AdmittedClip]:
    """Validate and admit only measured short public-domain/synthetic clips."""
    path = Path(manifest_path)
    manifest = _require_exact_fields(
        _load_strict_json(path),
        MANIFEST_FIELDS,
        "manifest",
    )
    if manifest["schemaVersion"] != 1:
        raise ManifestError("unsupported manifest schema")
    corpus_identity = manifest["corpusIdentity"]
    if (
        not isinstance(corpus_identity, str)
        or RENDER_IDENTITY_PATTERN.fullmatch(corpus_identity) is None
    ):
        raise ManifestError("corpus identity is invalid")
    rows = manifest["clips"]
    if not isinstance(rows, list):
        raise ManifestError("manifest clips must be an array")
    seen_clip_ids: set[str] = set()
    return [
        _admit_clip(
            row,
            manifest_directory=path.parent,
            seen_clip_ids=seen_clip_ids,
        )
        for row in rows
    ]


def encode_audio(clip: AdmittedClip) -> dict[str, str]:
    """Return direct base64 audio input without exposing a source path."""
    try:
        data = clip._audio_path.read_bytes()
    except OSError as error:
        raise ManifestError("admitted audio file is unavailable") from error
    if hashlib.sha256(data).hexdigest() != clip.audio_sha256:
        raise ManifestError("audio content changed after admission")
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

    try:
        decoded = json.loads(
            payload,
            object_pairs_hook=strict_result,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                ResponseValidationError("non-finite result number")),
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ResponseValidationError("result is not one JSON object") from error
    if not isinstance(decoded, dict):
        raise ResponseValidationError("result is not one JSON object")
    fields = set(decoded)
    if (
        not VERDICT_REQUIRED_FIELDS.issubset(fields)
        or not fields.issubset(VERDICT_REQUIRED_FIELDS | VERDICT_OPTIONAL_FIELDS)
    ):
        raise ResponseValidationError("result fields do not match the contract")
    if decoded["clipID"] != expected_clip_id or not validate_clip_id(decoded["clipID"]):
        raise ResponseValidationError("result clipID does not match")
    if decoded["verdict"] not in VERDICTS:
        raise ResponseValidationError("result verdict is invalid")
    confidence = decoded["confidence"]
    if (
        not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(confidence)
        or not 0.0 <= confidence <= 1.0
    ):
        raise ResponseValidationError("result confidence is invalid")
    if decoded["category"] not in CATEGORIES:
        raise ResponseValidationError("result category is invalid")
    for name, limit in (("heard", 160), ("note", 400)):
        if name in decoded and (
            not isinstance(decoded[name], str) or len(decoded[name]) > limit
        ):
            raise ResponseValidationError(f"result {name} is invalid")
    return decoded


def estimated_request_cost_usd(clip: AdmittedClip) -> float:
    """Return a conservative prospective text/audio-input and text-output cost."""
    rates = PRICING_CONFIG["usdPerMillionTokens"]
    return (
        clip.estimated_text_input_tokens * rates["textInput"]
        + clip.estimated_audio_input_tokens * rates["audioInput"]
        + clip.max_text_output_tokens * rates["textOutput"]
    ) / 1_000_000


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
    prompt = (
        "Judge only the pronunciation in this short public-domain or synthetic "
        "audio clip. Compare it with deterministic candidate "
        f"{clip.deterministic_expectation}. Return exactly one JSON object with "
        "clipID, verdict, confidence, category, and optional heard/note. "
        f"The clipID must be {clip.clip_id}. Do not include markdown or prose."
    )
    return {
        "model": MODEL_ID,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
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
        "max_completion_tokens": clip.max_text_output_tokens,
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
        decoded = json.loads(response_body)
        message = decoded["choices"][0]["message"]
        return {
            "model": decoded.get("model"),
            "content": message.get("content"),
            "refusal": message.get("refusal"),
            "usage": decoded.get("usage") or {},
        }
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
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


def _sanitized_usage(value: Any) -> dict[str, Any]:
    """Keep only documented finite token counts from an API usage object."""

    def valid_count(count: Any) -> bool:
        return (
            isinstance(count, (int, float))
            and not isinstance(count, bool)
            and math.isfinite(count)
            and count >= 0
        )

    if not isinstance(value, dict):
        return {}
    result = {
        key: value[key]
        for key in USAGE_NUMERIC_FIELDS
        if key in value and valid_count(value[key])
    }
    for outer_key, allowed_inner_keys in USAGE_DETAIL_FIELDS.items():
        details = value.get(outer_key)
        if not isinstance(details, dict):
            continue
        sanitized_details = {
            key: details[key]
            for key in allowed_inner_keys
            if key in details and valid_count(details[key])
        }
        if sanitized_details:
            result[outer_key] = sanitized_details
    return result


def _validated_returned_model_id(value: Any) -> str | None:
    if isinstance(value, str) and IDENTIFIER_PATTERN.fullmatch(value) is not None:
        return value
    return None


def _atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _run_directory(run_id: str, output_root: str | Path | None) -> Path:
    if RUN_ID_PATTERN.fullmatch(run_id) is None:
        raise LedgerError("run identifier is invalid")
    return Path(output_root or DEFAULT_OUTPUT_ROOT) / run_id


def _load_ledger_events(ledger_path: Path) -> list[dict[str, Any]]:
    if not ledger_path.exists():
        return []
    events: list[dict[str, Any]] = []
    try:
        for line in ledger_path.read_text(encoding="utf-8").splitlines():
            decoded = json.loads(line, object_pairs_hook=_strict_object)
            if not isinstance(decoded, dict):
                raise LedgerError("attempt ledger event is invalid")
            events.append(decoded)
    except (OSError, UnicodeError, json.JSONDecodeError, ManifestError) as error:
        raise LedgerError("attempt ledger is invalid") from error
    return events


def _derive_attempt_states(
    events: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    states: dict[str, dict[str, Any]] = {}
    for sequence, event in enumerate(events, start=1):
        clip_id = event.get("clipID")
        state = event.get("state")
        attempt_count = event.get("attemptCount")
        if (
            not validate_clip_id(clip_id)
            or state
            not in {
                "proposal_emitted",
                "rerender_pending",
                "resolved",
                "morning_review",
            }
            or not isinstance(attempt_count, int)
            or isinstance(attempt_count, bool)
            or not 0 <= attempt_count <= 2
        ):
            raise LedgerError("attempt ledger event is invalid")
        states[clip_id] = {
            "clipID": clip_id,
            "state": state,
            "attemptCount": attempt_count,
            "touchedFamilyGraduation": False,
            "phase3Graduation": False,
            "lastEventSequence": sequence,
        }
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
    )


def _append_ledger_event_locked(
    run_directory: Path,
    events: list[dict[str, Any]],
    event: dict[str, Any],
) -> dict[str, Any]:
    ledger_path = run_directory / "attempt-ledger.jsonl"
    with ledger_path.open("a", encoding="utf-8") as ledger:
        ledger.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
        ledger.flush()
        os.fsync(ledger.fileno())
    events.append(event)
    states = _derive_attempt_states(events)
    _write_attempt_snapshot(run_directory, states)
    return states[event["clipID"]]


def _with_ledger_lock(
    run_directory: Path,
    operation: Callable[[list[dict[str, Any]]], dict[str, Any]],
) -> dict[str, Any]:
    run_directory.mkdir(parents=True, exist_ok=True)
    lock_path = run_directory / ".attempt-ledger.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
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
) -> dict[str, Any]:
    if not validate_clip_id(clip_id) or category not in CATEGORIES:
        raise LedgerError("proposal evidence is invalid")
    run_directory = _run_directory(run_id, output_root)

    def operation(events: list[dict[str, Any]]) -> dict[str, Any]:
        states = _derive_attempt_states(events)
        if clip_id in states:
            return states[clip_id]
        return _append_ledger_event_locked(
            run_directory,
            events,
            {
                "schemaVersion": 1,
                "eventType": "proposal_emitted",
                "clipID": clip_id,
                "state": "proposal_emitted",
                "attemptCount": 0,
                "proposalCategory": category,
                "productionMutationAuthorized": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            },
        )

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
            {
                "schemaVersion": 1,
                "eventType": "attempt_recorded",
                "clipID": clip_id,
                "state": "rerender_pending",
                "attemptCount": current["attemptCount"] + 1,
                "sourceCommit": source_commit,
                **receipts,
                "productionMutationPerformedByJudge": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            },
        )

    return _with_ledger_lock(run_directory, operation)


def _append_repeated_failure_to_morning_queue(
    run_directory: Path,
    clip_id: str,
) -> None:
    queue_path = run_directory / "morning-queue.json"
    try:
        queue = json.loads(queue_path.read_text(encoding="utf-8")) if queue_path.exists() else []
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LedgerError("morning queue is invalid") from error
    if not isinstance(queue, list):
        raise LedgerError("morning queue is invalid")
    queue.append(
        {
            "clipID": clip_id,
            "queueCategory": "morning_review",
            "reasons": ["repeated_regression_failure"],
        }
    )
    _atomic_write_json(queue_path, queue)


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
        current = _derive_attempt_states(events).get(clip_id)
        if current is None or current["state"] != "rerender_pending":
            raise LedgerError("clip is not waiting for a rerender result")
        if outcome == "pass":
            state = "resolved"
        elif current["attemptCount"] >= 2:
            state = "morning_review"
        else:
            state = "proposal_emitted"
        result = _append_ledger_event_locked(
            run_directory,
            events,
            {
                "schemaVersion": 1,
                "eventType": "rerender_recorded",
                "clipID": clip_id,
                "state": state,
                "attemptCount": current["attemptCount"],
                "renderContentSHA256": render_content_sha256,
                "audioRetestReceipt": audio_retest_receipt,
                "familyRegressionReceipt": family_regression_receipt,
                "outcome": outcome,
                "productionMutationPerformedByJudge": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            },
        )
        if state == "morning_review":
            _append_repeated_failure_to_morning_queue(run_directory, clip_id)
        return result

    return _with_ledger_lock(run_directory, operation)


def _result_proof_boundaries(label_status: str) -> dict[str, Any]:
    provisional = label_status == "provisional"
    return {
        "evidenceCategory":
            "provisional_evidence" if provisional else "machine_evidence",
        "accuracyContribution": False if provisional else True,
        "humanLabelContribution": False,
        "humanListeningContribution": False,
        "qualificationContribution": False,
        "touchedFamilyGraduation": False,
        "phase3Graduation": False,
    }


def run_evaluation(
    *,
    manifest_path: str | Path,
    run_id: str,
    dry_run: bool,
    output_root: str | Path | None = None,
    environment: Mapping[str, str] | None = None,
    transport: Callable[[dict[str, Any], str], dict[str, Any]] = _post_chat_completion,
) -> dict[str, Any]:
    """Admit, cap, optionally evaluate, and persist a redacted run receipt."""
    if RUN_ID_PATTERN.fullmatch(run_id) is None:
        raise ManifestError("run identifier is invalid")
    manifest_file = Path(manifest_path)
    clips = admit_manifest(manifest_file)
    manifest = _load_strict_json(manifest_file)
    manifest_hash = hashlib.sha256(manifest_file.read_bytes()).hexdigest()
    baseline_estimates = [estimated_request_cost_usd(clip) for clip in clips]
    estimated_cost = 0.0
    for request_count, next_estimate in enumerate(baseline_estimates):
        enforce_prospective_cap(
            request_count=request_count,
            estimated_cost_usd=estimated_cost,
            next_request_estimate_usd=next_estimate,
        )
        estimated_cost += next_estimate

    run_directory = Path(output_root or DEFAULT_OUTPUT_ROOT) / run_id
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
        "estimatedCostUSD": round(estimated_cost, 8),
        "pricing": PRICING_CONFIG,
        "corpusIdentity": manifest["corpusIdentity"],
        "manifestContentSHA256": manifest_hash,
        "results": [],
        "morningQueue": [],
        "proofBoundaries": {
            "machineEvidenceIsHumanLabel": False,
            "machineEvidenceIsHumanListening": False,
            "authorizesPhase3": False,
        },
    }
    if dry_run:
        _atomic_write_json(run_directory / "receipt.json", receipt)
        return receipt

    current_environment = environment if environment is not None else os.environ
    api_key = current_environment.get("OPENAI_API_KEY")
    if not api_key:
        _atomic_write_json(run_directory / "receipt.json", receipt)
        return receipt

    receipt["status"] = "COMPLETED"
    receipt["apiEvaluationStatus"] = "passed"
    actual_request_estimate = 0.0
    for clip_index, clip in enumerate(clips):
        next_estimate = baseline_estimates[clip_index]
        remaining_clip_count = len(clips) - clip_index - 1
        remaining_baseline_estimate = sum(baseline_estimates[clip_index + 1:])
        body = build_request_body(clip)
        response: dict[str, Any] | None = None
        retry_attempted = False
        retry_blocked_by_cap = False
        failure: str | None = None
        clip_request_count = 0
        for attempt in range(2):
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
                        next_request_estimate_usd=next_estimate,
                    )
                except ManifestError:
                    retry_blocked_by_cap = True
                    failure = "transport_failure"
                    break
                retry_attempted = True
            enforce_prospective_cap(
                request_count=receipt["requestCount"],
                estimated_cost_usd=actual_request_estimate,
                next_request_estimate_usd=next_estimate,
            )
            receipt["requestCount"] += 1
            receipt["transportAttemptCount"] += 1
            actual_request_estimate += next_estimate
            clip_request_count += 1
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
        if failure is None and response is not None:
            returned_model = _validated_returned_model_id(response.get("model"))
            if returned_model is not None:
                receipt["returnedModelIDs"].append(returned_model)
            if response.get("refusal"):
                failure = "model_refusal"
            elif not isinstance(response.get("content"), str):
                failure = "malformed_output"
            else:
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
        result = {
            "clipID": clip.clip_id,
            "corpusID": clip.corpus_id,
            "audioSHA256": clip.audio_sha256,
            "sourceCommit": clip.source_commit,
            "renderIdentity": clip.render_identity,
            "requestedModelID": MODEL_ID,
            "returnedModelID": (
                _validated_returned_model_id(response.get("model"))
                if response
                else None
            ),
            "estimatedCostUSD": round(next_estimate * clip_request_count, 8),
            "usage": _sanitized_usage(response.get("usage")) if response else {},
            "retryOutcome": (
                "retry_blocked_by_cap"
                if retry_blocked_by_cap
                else "retried_once"
                if retry_attempted
                else "not_retried"
            ),
            "validationOutcome": validation_outcome,
            "verdict": verdict,
            **_result_proof_boundaries(clip.label_status),
        }
        receipt["results"].append(result)
        if verdict is not None and verdict["verdict"] == "fail":
            _emit_proposal(
                run_id=run_id,
                clip_id=clip.clip_id,
                category=verdict["category"],
                output_root=output_root,
            )
        if reasons:
            receipt["apiEvaluationStatus"] = "needs_review"
            receipt["morningQueue"].append(
                {
                    "clipID": clip.clip_id,
                    "corpusID": clip.corpus_id,
                    "queueCategory":
                        "provisional_review"
                        if clip.label_status == "provisional"
                        else "morning_review",
                    "reasons": reasons,
                }
            )

    receipt["estimatedCostUSD"] = round(actual_request_estimate, 8)
    receipt["returnedModelIDs"] = sorted(set(receipt["returnedModelIDs"]))
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
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_argument_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "evaluate":
            result = run_evaluation(
                manifest_path=options.manifest,
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
        else:
            result = record_rerender(
                run_id=options.run_id,
                clip_id=options.clip_id,
                render_content_sha256=options.render_content_sha256,
                audio_retest_receipt=options.audio_retest_receipt,
                family_regression_receipt=options.family_regression_receipt,
                outcome=options.outcome,
                output_root=options.output_root,
            )
    except (ManifestError, ResponseValidationError, LedgerError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
