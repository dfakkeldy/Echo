#!/usr/bin/env python3
"""Validate and report Echo's neural OOV qualification evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

try:
    from Tools.Pronunciation.pronunciation_corpus import (
        _read_external_unique_regular_bytes,
        _strict_json_loads,
        _validate_no_private_data,
        _validate_provenance,
    )
except ModuleNotFoundError:
    from pronunciation_corpus import (  # type: ignore[no-redef]
        _read_external_unique_regular_bytes,
        _strict_json_loads,
        _validate_no_private_data,
        _validate_provenance,
    )


CATEGORIES = (
    "proper-noun",
    "technical",
    "morphology",
    "loanword",
    "adversarial",
)
ALLOWED_PROVENANCE = {"public-domain", "permissive", "synthetic"}
MINIMUM_REVIEWED_CASES = 500
MINIMUM_CASES_PER_CATEGORY = 75
MINIMUM_AUTOMATIC_CASES = 500
MINIMUM_PRECISION = 0.99
MINIMUM_WILSON_95_LOWER_BOUND = 0.98
CONVERSION_VERSION = "mini-bart-arpabet-to-kokoro-v1"
VALIDATION_VERSION = "kokoro-vocab-validation-v1"
SELECTION_VERSION = "neural-oov-complete-selection-v1"
AUTHORIZATION_PURPOSE = "neural-g2p-human-evidence-qualification"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PROOF_STATE_VOCABULARY = {
    "corpus": frozenset({"CONTRACT_VALID"}),
    "human": frozenset({"WAITING_FOR_HUMAN_LABELS", "FAILED", "QUALIFIED"}),
    "performance": frozenset(
        {"NOT_RUN_NO_RUNTIME", "NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
    "device": frozenset(
        {"NOT_RUN_NO_RUNTIME", "NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
    "render": frozenset(
        {"NOT_RUN_NO_RUNTIME", "NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
}
DEFAULT_RUNTIME_PROOF_STATE = "NOT_RUN_NO_RUNTIME"

CANDIDATE_REQUIRED_FIELDS = {
    "caseID",
    "word",
    "category",
    "context",
    "labelStatus",
    "provisionalExpectedIPA",
    "provenance",
}
CANDIDATE_ALLOWED_FIELDS = CANDIDATE_REQUIRED_FIELDS | {"sourceURL", "license"}
TRUSTED_RECEIPT_FIELDS = {
    "receiptID",
    "caseID",
    "category",
    "wordSHA256",
    "evidenceKind",
    "labelA",
    "labelB",
    "adjudicated",
    "reviewerARef",
    "reviewerBRef",
    "adjudicatorRef",
    "rawModelTop1",
    "convertedOutputs",
    "mappedTokenIDs",
    "selectionOutcome",
    "selectedIPA",
    "modelRevision",
    "modelLockSHA256",
    "vocabSHA256",
    "conversionVersion",
    "validationVersion",
    "selectionVersion",
}
AUTHORITY_FIELDS = {
    "schemaVersion",
    "authorityKind",
    "authorizationPurpose",
    "evidenceBundleSHA256",
    "reviewerIndependenceAttested",
    "reviewerReferenceScheme",
}


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_exact_fields(
    row: dict[str, Any],
    *,
    required: set[str],
    allowed: set[str],
    name: str,
) -> None:
    missing = sorted(required - row.keys())
    if missing:
        raise ValueError(f"{name} missing required fields: {', '.join(missing)}")
    unexpected = sorted(row.keys() - allowed)
    if unexpected:
        raise ValueError(f"{name} contains unexpected fields: {', '.join(unexpected)}")


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_candidates(raw_rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    case_ids: set[str] = set()
    category_words: set[tuple[str, str]] = set()
    for index, raw_row in enumerate(raw_rows, start=1):
        if not isinstance(raw_row, dict):
            raise ValueError(f"candidate row {index} must be a JSON object")
        row = dict(raw_row)
        _validate_no_private_data(row, f"candidate row {index}")
        _validate_exact_fields(
            row,
            required=CANDIDATE_REQUIRED_FIELDS,
            allowed=CANDIDATE_ALLOWED_FIELDS,
            name=f"candidate row {index}",
        )
        for field in (
            "caseID",
            "word",
            "category",
            "context",
            "provisionalExpectedIPA",
        ):
            if not _nonempty_string(row[field]):
                raise ValueError(f"candidate row {index} {field} must be nonempty")
        if row["category"] not in CATEGORIES:
            raise ValueError(
                "candidate category must be proper-noun, technical, morphology, "
                "loanword, or adversarial"
            )
        if row["labelStatus"] != "provisional":
            raise ValueError("candidate labelStatus must remain provisional")
        if row["provenance"] not in ALLOWED_PROVENANCE:
            raise ValueError(
                "candidate provenance must be public-domain, permissive, or synthetic"
            )
        _validate_provenance(row, f"candidate row {index}")

        if row["caseID"] in case_ids:
            raise ValueError(f"duplicate caseID {row['caseID']}")
        identity = (row["category"], row["word"].casefold())
        if identity in category_words:
            raise ValueError(
                f"duplicate category/word case {row['category']}/{row['word']}"
            )
        case_ids.add(row["caseID"])
        category_words.add(identity)
        rows.append(row)
    return rows


def validate_trusted_receipts(
    raw_receipts: Iterable[dict[str, Any]],
) -> list[dict[str, Any]]:
    receipts: list[dict[str, Any]] = []
    receipt_ids: set[str] = set()
    case_ids: set[str] = set()
    for index, raw_receipt in enumerate(raw_receipts, start=1):
        if not isinstance(raw_receipt, dict):
            raise ValueError(f"trusted receipt {index} must be a JSON object")
        receipt = dict(raw_receipt)
        _validate_no_private_data(receipt, f"trusted receipt {index}")
        _validate_exact_fields(
            receipt,
            required=TRUSTED_RECEIPT_FIELDS,
            allowed=TRUSTED_RECEIPT_FIELDS,
            name=f"trusted receipt {index}",
        )
        for field in (
            "receiptID",
            "caseID",
            "category",
            "wordSHA256",
            "evidenceKind",
            "labelA",
            "labelB",
            "reviewerARef",
            "reviewerBRef",
            "rawModelTop1",
            "selectionOutcome",
            "modelRevision",
            "modelLockSHA256",
            "vocabSHA256",
            "conversionVersion",
            "validationVersion",
            "selectionVersion",
        ):
            if not _nonempty_string(receipt[field]):
                raise ValueError(f"trusted receipt {index} {field} must be nonempty")
        if receipt["category"] not in CATEGORIES:
            raise ValueError(f"trusted receipt {index} category is invalid")
        if SHA256_PATTERN.fullmatch(receipt["wordSHA256"]) is None:
            raise ValueError(f"trusted receipt {index} wordSHA256 is invalid")
        for field in ("reviewerARef", "reviewerBRef"):
            if SHA256_PATTERN.fullmatch(receipt[field]) is None:
                raise ValueError(f"trusted receipt {index} {field} is invalid")
        if receipt["reviewerARef"] == receipt["reviewerBRef"]:
            raise ValueError(
                f"trusted receipt {index} requires distinct reviewer references"
            )
        if re.fullmatch(r"[0-9a-f]{40}", receipt["modelRevision"]) is None:
            raise ValueError(f"trusted receipt {index} modelRevision is invalid")
        for field in ("modelLockSHA256", "vocabSHA256"):
            if SHA256_PATTERN.fullmatch(receipt[field]) is None:
                raise ValueError(f"trusted receipt {index} {field} is invalid")
        if receipt["evidenceKind"] not in {
            "independent-human",
            "source-verifiable",
        }:
            raise ValueError(
                f"trusted receipt {index} requires independent human evidence"
            )
        if receipt["adjudicated"] is not None and not _nonempty_string(
            receipt["adjudicated"]
        ):
            raise ValueError(f"trusted receipt {index} adjudicated is invalid")
        if (
            receipt["labelA"] != receipt["labelB"]
            and receipt["adjudicated"] is None
        ):
            raise ValueError(
                f"trusted receipt {index} label disagreement requires adjudication"
            )
        if receipt["labelA"] != receipt["labelB"]:
            if (
                not isinstance(receipt["adjudicatorRef"], str)
                or SHA256_PATTERN.fullmatch(receipt["adjudicatorRef"]) is None
                or receipt["adjudicatorRef"]
                in {receipt["reviewerARef"], receipt["reviewerBRef"]}
            ):
                raise ValueError(
                    f"trusted receipt {index} requires a distinct adjudicator reference"
                )
        elif receipt["adjudicatorRef"] is not None:
            raise ValueError(
                f"trusted receipt {index} cannot declare an adjudicator without "
                "reviewer disagreement"
            )
        if (
            receipt["labelA"] == receipt["labelB"]
            and receipt["adjudicated"] not in {None, receipt["labelA"]}
        ):
            raise ValueError(
                f"trusted receipt {index} adjudication contradicts agreeing labels"
            )
        if (
            not isinstance(receipt["convertedOutputs"], list)
            or any(not isinstance(value, str) for value in receipt["convertedOutputs"])
        ):
            raise ValueError(f"trusted receipt {index} convertedOutputs is invalid")
        if (
            not isinstance(receipt["mappedTokenIDs"], list)
            or any(
                not isinstance(value, int) or isinstance(value, bool) or value < 0
                for value in receipt["mappedTokenIDs"]
            )
        ):
            raise ValueError(f"trusted receipt {index} mappedTokenIDs is invalid")
        if receipt["selectionOutcome"] not in {"automatic", "review"}:
            raise ValueError(f"trusted receipt {index} selectionOutcome is invalid")
        if not isinstance(receipt["selectedIPA"], str):
            raise ValueError(f"trusted receipt {index} selectedIPA must be text")
        if receipt["receiptID"] in receipt_ids:
            raise ValueError(f"duplicate receiptID {receipt['receiptID']}")
        if receipt["caseID"] in case_ids:
            raise ValueError(
                f"multiple trusted receipts for caseID {receipt['caseID']}"
            )
        receipt_ids.add(receipt["receiptID"])
        case_ids.add(receipt["caseID"])
        receipts.append(receipt)
    return receipts


def evidence_authority_digest(
    candidates: list[dict[str, Any]], receipts: list[dict[str, Any]]
) -> str:
    return _canonical_sha256(
        {
            "schemaVersion": 1,
            "authorizationPurpose": AUTHORIZATION_PURPOSE,
            "candidateCases": candidates,
            "trustedReceipts": receipts,
        }
    )


def validate_human_evidence_authority(
    raw_authority: Any,
    *,
    candidates: list[dict[str, Any]] | None = None,
    receipts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    if (
        not isinstance(raw_authority, dict)
        or set(raw_authority) != AUTHORITY_FIELDS
        or raw_authority.get("schemaVersion") != 1
        or raw_authority.get("authorityKind")
        != "user-controlled-out-of-repository"
        or raw_authority.get("authorizationPurpose") != AUTHORIZATION_PURPOSE
        or not isinstance(raw_authority.get("evidenceBundleSHA256"), str)
        or SHA256_PATTERN.fullmatch(raw_authority["evidenceBundleSHA256"]) is None
    ):
        raise ValueError("human evidence authority is invalid")
    if (
        raw_authority.get("reviewerIndependenceAttested") is not True
        or raw_authority.get("reviewerReferenceScheme") != "sha256-v1"
    ):
        raise ValueError(
            "human evidence authority lacks reviewer independence attestation"
        )
    if (candidates is None) != (receipts is None):
        raise ValueError("authority binding requires candidates and receipts together")
    if candidates is not None and receipts is not None:
        expected_digest = evidence_authority_digest(candidates, receipts)
        if raw_authority["evidenceBundleSHA256"] != expected_digest:
            raise ValueError(
                "trusted receipts require an exact human evidence authority binding"
            )
    return dict(raw_authority)


def _decode_external_jsonl(content: bytes, name: str) -> list[dict[str, Any]]:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{name} is not valid UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        value = _strict_json_loads(line, f"{name}:{line_number}")
        if not isinstance(value, dict):
            raise ValueError(f"{name}:{line_number} must contain a JSON object")
        rows.append(value)
    return rows


def load_external_evidence(
    trusted_receipts: Path | str | None,
    human_evidence_authority: Path | str | None,
    *,
    candidates: list[dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    if trusted_receipts is None and human_evidence_authority is None:
        return [], None
    if trusted_receipts is None:
        raise ValueError("human evidence authority requires trusted receipts")
    if human_evidence_authority is None:
        raise ValueError("trusted receipts require a human evidence authority")

    receipt_bytes = _read_external_unique_regular_bytes(
        Path(trusted_receipts), name="trusted receipts"
    )
    authority_bytes = _read_external_unique_regular_bytes(
        Path(human_evidence_authority), name="human evidence authority"
    )
    receipts = validate_trusted_receipts(
        _decode_external_jsonl(receipt_bytes, "trusted receipts")
    )
    try:
        authority_text = authority_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("human evidence authority is not valid UTF-8") from error
    authority = _strict_json_loads(authority_text, "human evidence authority")
    validated_authority = validate_human_evidence_authority(
        authority,
        candidates=candidates,
        receipts=receipts if candidates is not None else None,
    )
    return receipts, validated_authority


def wilson_lower_bound(successes: int, trials: int) -> float:
    if trials == 0:
        return 0.0
    if successes < 0 or trials < 0 or successes > trials:
        raise ValueError("Wilson inputs must satisfy 0 <= successes <= trials")
    z = 1.959963984540054
    proportion = successes / trials
    denominator = 1 + (z * z / trials)
    centre = proportion + (z * z / (2 * trials))
    margin = z * math.sqrt(
        proportion * (1 - proportion) / trials + z * z / (4 * trials * trials)
    )
    return (centre - margin) / denominator


def _stable_metadata(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_stable_regular_bytes(path: Path | str, *, name: str) -> bytes:
    candidate = Path(path)
    if candidate.is_symlink():
        raise ValueError(f"{name} cannot be a symlink")
    if not hasattr(os, "O_NOFOLLOW"):
        raise ValueError(f"{name} cannot be read without symlink protection")
    try:
        resolved = candidate.resolve(strict=True)
        path_before = resolved.lstat()
        if not stat.S_ISREG(path_before.st_mode):
            raise ValueError(f"{name} must be a regular file")
        descriptor = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            descriptor_before = os.fstat(source.fileno())
            if _stable_metadata(path_before) != _stable_metadata(descriptor_before):
                raise ValueError(f"{name} changed before it could be read")
            content = source.read()
            descriptor_after = os.fstat(source.fileno())
        path_after = resolved.lstat()
    except ValueError:
        raise
    except OSError as error:
        raise ValueError(f"{name} is unavailable") from error
    expected = _stable_metadata(path_before)
    if (
        _stable_metadata(descriptor_after) != expected
        or _stable_metadata(path_after) != expected
    ):
        raise ValueError(f"{name} changed while it was read")
    return content


def _decode_json_snapshot(content: bytes, *, name: str) -> Any:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{name} is not valid UTF-8") from error
    return _strict_json_loads(text, name)


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        content = path.read_bytes()
    except OSError as error:
        raise ValueError(f"{path} is unavailable") from error
    return _decode_external_jsonl(content, path.name)


def _load_qualification_resources(
    lock_path: Path | str, vocab_path: Path | str
) -> tuple[dict[str, Any], dict[str, int]]:
    lock_bytes = _read_stable_regular_bytes(lock_path, name="model lock")
    vocab_bytes = _read_stable_regular_bytes(vocab_path, name="Kokoro vocabulary")
    lock = _decode_json_snapshot(lock_bytes, name="model lock")
    vocab_document = _decode_json_snapshot(
        vocab_bytes, name="Kokoro vocabulary"
    )
    if (
        not isinstance(lock, dict)
        or lock.get("schema_version") != 1
        or not _nonempty_string(lock.get("model"))
        or not isinstance(lock.get("revision"), str)
        or re.fullmatch(r"[0-9a-f]{40}", lock["revision"]) is None
        or not isinstance(lock.get("artifacts"), list)
    ):
        raise ValueError("model lock is invalid")
    artifact_hashes: dict[str, str] = {}
    for artifact in lock["artifacts"]:
        if (
            not isinstance(artifact, dict)
            or not _nonempty_string(artifact.get("path"))
            or not isinstance(artifact.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(artifact["sha256"]) is None
            or artifact["path"] in artifact_hashes
        ):
            raise ValueError("model lock artifact identity is invalid")
        artifact_hashes[artifact["path"]] = artifact["sha256"]
    vocab = vocab_document.get("vocab") if isinstance(vocab_document, dict) else None
    if (
        not isinstance(vocab_document, dict)
        or set(vocab_document) != {"vocab"}
        or not isinstance(vocab, dict)
        or any(
            not isinstance(symbol, str)
            or len(symbol) != 1
            or not isinstance(token_id, int)
            or isinstance(token_id, bool)
            or token_id < 0
            for symbol, token_id in vocab.items()
        )
    ):
        raise ValueError("Kokoro vocabulary is invalid")
    identity = {
        "model": lock["model"],
        "revision": lock["revision"],
        "lockSHA256": hashlib.sha256(lock_bytes).hexdigest(),
        "artifactSHA256": {
            path: artifact_hashes[path] for path in sorted(artifact_hashes)
        },
        "vocabSHA256": hashlib.sha256(vocab_bytes).hexdigest(),
    }
    return identity, vocab


def _gold_label(receipt: dict[str, Any]) -> str:
    if receipt["labelA"] == receipt["labelB"]:
        return receipt["labelA"]
    assert receipt["adjudicated"] is not None
    return receipt["adjudicated"]


def validate_proof_states(raw_states: Any) -> dict[str, str]:
    if not isinstance(raw_states, dict) or set(raw_states) != set(
        PROOF_STATE_VOCABULARY
    ):
        raise ValueError("proof state schema is invalid")
    for lane, allowed_states in PROOF_STATE_VOCABULARY.items():
        if (
            not isinstance(raw_states[lane], str)
            or raw_states[lane] not in allowed_states
        ):
            raise ValueError(f"{lane} proof state is invalid")
    return {lane: raw_states[lane] for lane in PROOF_STATE_VOCABULARY}


def qualification_status(
    raw_candidates: Iterable[dict[str, Any]],
    raw_receipts: Iterable[dict[str, Any]],
    trusted_authority: dict[str, Any] | None,
    lock_path: Path | str,
    vocab_path: Path | str,
    *,
    performance_proof_state: str = DEFAULT_RUNTIME_PROOF_STATE,
    device_proof_state: str = DEFAULT_RUNTIME_PROOF_STATE,
    render_proof_state: str = DEFAULT_RUNTIME_PROOF_STATE,
) -> dict[str, Any]:
    candidates = validate_candidates(raw_candidates)
    receipts = validate_trusted_receipts(raw_receipts)
    if receipts:
        validate_human_evidence_authority(
            trusted_authority,
            candidates=candidates,
            receipts=receipts,
        )
    elif trusted_authority is not None:
        raise ValueError("human evidence authority cannot bind empty trusted receipts")

    model_identity, vocab = _load_qualification_resources(lock_path, vocab_path)
    expected_receipt_identity = {
        "modelRevision": model_identity["revision"],
        "modelLockSHA256": model_identity["lockSHA256"],
        "vocabSHA256": model_identity["vocabSHA256"],
        "conversionVersion": CONVERSION_VERSION,
        "validationVersion": VALIDATION_VERSION,
        "selectionVersion": SELECTION_VERSION,
    }
    candidates_by_id = {row["caseID"]: row for row in candidates}
    reviewed_categories: Counter[str] = Counter()
    qualifying_categories: Counter[str] = Counter()
    invalid_counts = {
        "duplicate": 0,
        "empty": 0,
        "unmappable": 0,
        "unstable": 0,
        "kokoroIncompatible": 0,
    }
    automatic_count = 0
    correct_count = 0

    for receipt in receipts:
        if any(
            receipt[field] != expected
            for field, expected in expected_receipt_identity.items()
        ):
            raise ValueError(
                f"trusted receipt {receipt['receiptID']} does not match "
                "qualification identities"
            )
        candidate_row = candidates_by_id.get(receipt["caseID"])
        if candidate_row is None:
            raise ValueError(
                f"trusted receipt {receipt['receiptID']} references an unknown caseID"
            )
        expected_word_hash = hashlib.sha256(
            candidate_row["word"].encode("utf-8")
        ).hexdigest()
        if (
            receipt["category"] != candidate_row["category"]
            or receipt["wordSHA256"] != expected_word_hash
        ):
            raise ValueError(
                f"trusted receipt {receipt['receiptID']} does not exactly match its case"
            )
        reviewed_categories[receipt["category"]] += 1

        if receipt["selectionOutcome"] != "automatic":
            continue
        outputs = receipt["convertedOutputs"]
        selected = receipt["selectedIPA"]
        if not selected or not outputs or any(not output for output in outputs):
            invalid_counts["empty"] += 1
            continue
        if len(outputs) < 2 or any(output != outputs[0] for output in outputs[1:]):
            invalid_counts["unstable"] += 1
            continue
        if selected != outputs[0]:
            invalid_counts["unmappable"] += 1
            continue
        unsupported = [character for character in selected if character not in vocab]
        if unsupported:
            invalid_counts["kokoroIncompatible"] += 1
            continue
        expected_token_ids = [vocab[character] for character in selected]
        if receipt["mappedTokenIDs"] != expected_token_ids:
            invalid_counts["unmappable"] += 1
            continue

        automatic_count += 1
        qualifying_categories[receipt["category"]] += 1
        if selected == _gold_label(receipt):
            correct_count += 1

    reviewed_count = len(receipts)
    precision = correct_count / automatic_count if automatic_count else None
    wilson = (
        wilson_lower_bound(correct_count, automatic_count)
        if automatic_count
        else None
    )
    evidence_ready = (
        reviewed_count >= MINIMUM_REVIEWED_CASES
        and all(
            reviewed_categories[category] >= MINIMUM_CASES_PER_CATEGORY
            for category in CATEGORIES
        )
    )
    all_invalid_zero = all(value == 0 for value in invalid_counts.values())
    gates_pass = (
        automatic_count >= MINIMUM_AUTOMATIC_CASES
        and all(
            qualifying_categories[category] >= MINIMUM_CASES_PER_CATEGORY
            for category in CATEGORIES
        )
        and precision is not None
        and precision >= MINIMUM_PRECISION
        and wilson is not None
        and wilson >= MINIMUM_WILSON_95_LOWER_BOUND
        and all_invalid_zero
    )
    if not evidence_ready:
        status = "WAITING_FOR_HUMAN_LABELS"
    elif gates_pass:
        status = "QUALIFIED"
    else:
        status = "FAILED"

    proof_states = validate_proof_states(
        {
            "corpus": "CONTRACT_VALID",
            "human": status,
            "performance": performance_proof_state,
            "device": device_proof_state,
            "render": render_proof_state,
        }
    )

    return {
        "schemaVersion": 1,
        "status": status,
        "proofStates": proof_states,
        "corpusSHA256": _canonical_sha256(candidates),
        "categoryCounts": {
            category: qualifying_categories[category] for category in CATEGORIES
        },
        "reviewedCount": reviewed_count,
        "automaticCount": automatic_count,
        "correctAutomaticCount": correct_count,
        "precision": precision,
        "wilson95LowerBound": wilson,
        "invalidCounts": invalid_counts,
        "modelIdentity": model_identity,
        "conversionVersion": CONVERSION_VERSION,
        "validationVersion": VALIDATION_VERSION,
        "selectionVersion": SELECTION_VERSION,
        "thresholds": {
            "minimumReviewedCases": MINIMUM_REVIEWED_CASES,
            "minimumCasesPerCategory": MINIMUM_CASES_PER_CATEGORY,
            "minimumAutomaticCases": MINIMUM_AUTOMATIC_CASES,
            "minimumPrecision": MINIMUM_PRECISION,
            "minimumWilson95LowerBound": MINIMUM_WILSON_95_LOWER_BOUND,
            "requireZeroInvalidOutputs": True,
            "requireStableRepetition": True,
        },
    }


def render_report(
    receipt: dict[str, Any],
    *,
    performance_proof_state: str | None = None,
    device_proof_state: str | None = None,
    render_proof_state: str | None = None,
) -> str:
    proof_states = validate_proof_states(receipt.get("proofStates"))
    if receipt.get("status") != proof_states["human"]:
        raise ValueError("human proof state does not match qualification status")
    overrides = {
        "performance": performance_proof_state,
        "device": device_proof_state,
        "render": render_proof_state,
    }
    for lane, value in overrides.items():
        if value is not None:
            proof_states[lane] = value
    proof_states = validate_proof_states(proof_states)
    category_lines = "\n".join(
        f"- `{category}`: {receipt['categoryCounts'][category]} qualifying cases"
        for category in CATEGORIES
    )
    precision = (
        "unavailable"
        if receipt["precision"] is None
        else f"{receipt['precision']:.6f}"
    )
    wilson = (
        "unavailable"
        if receipt["wilson95LowerBound"] is None
        else f"{receipt['wilson95LowerBound']:.6f}"
    )
    return f"""# Neural G2P Qualification

Qualification status: `{receipt['status']}`

This report is generated from a content-free qualification receipt. Candidate
words, contexts, human labels, and model output strings are intentionally absent.

## Qualification evidence

- Corpus SHA-256: `{receipt['corpusSHA256']}`
- Reviewed cases: {receipt['reviewedCount']}
- Automatic selections: {receipt['automaticCount']}
- Correct automatic selections: {receipt['correctAutomaticCount']}
- Exact automatic precision: {precision}
- 95% Wilson lower bound: {wilson}

{category_lines}

## Invalid outputs

```json
{json.dumps(receipt['invalidCounts'], sort_keys=True, separators=(',', ':'))}
```

## Frozen identities

- Model: `{receipt['modelIdentity']['model']}`
- Revision: `{receipt['modelIdentity']['revision']}`
- Lock SHA-256: `{receipt['modelIdentity']['lockSHA256']}`
- Kokoro vocabulary SHA-256: `{receipt['modelIdentity']['vocabSHA256']}`
- Conversion version: `{receipt['conversionVersion']}`
- Validation version: `{receipt['validationVersion']}`
- Selection version: `{receipt['selectionVersion']}`

## Separate proof states

- Corpus proof: `{proof_states['corpus']}`
- Human proof: `{proof_states['human']}`
- Performance proof: `{proof_states['performance']}`
- Device proof: `{proof_states['device']}`
- Render proof: `{proof_states['render']}`

These states are not inferred from corpus validation or human-label qualification.
"""


def _print_receipt(receipt: dict[str, Any]) -> None:
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "qualification-status", "report"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--corpus", type=Path, required=True)
        command_parser.add_argument("--lock", type=Path, required=True)
        command_parser.add_argument("--vocab", type=Path, required=True)
        command_parser.add_argument("--trusted-receipts", type=Path)
        command_parser.add_argument("--human-evidence-authority", type=Path)
        if command == "report":
            command_parser.add_argument("--output", type=Path, required=True)
            command_parser.add_argument(
                "--performance-proof-state",
                choices=sorted(PROOF_STATE_VOCABULARY["performance"]),
                required=True,
            )
            command_parser.add_argument(
                "--device-proof-state",
                choices=sorted(PROOF_STATE_VOCABULARY["device"]),
                required=True,
            )
            command_parser.add_argument(
                "--render-proof-state",
                choices=sorted(PROOF_STATE_VOCABULARY["render"]),
                required=True,
            )
    arguments = parser.parse_args(argv)

    try:
        candidates = validate_candidates(_load_jsonl(arguments.corpus))
        receipts, authority = load_external_evidence(
            arguments.trusted_receipts,
            arguments.human_evidence_authority,
            candidates=candidates,
        )
        receipt = qualification_status(
            candidates,
            receipts,
            authority,
            arguments.lock,
            arguments.vocab,
            performance_proof_state=(
                arguments.performance_proof_state
                if arguments.command == "report"
                else DEFAULT_RUNTIME_PROOF_STATE
            ),
            device_proof_state=(
                arguments.device_proof_state
                if arguments.command == "report"
                else DEFAULT_RUNTIME_PROOF_STATE
            ),
            render_proof_state=(
                arguments.render_proof_state
                if arguments.command == "report"
                else DEFAULT_RUNTIME_PROOF_STATE
            ),
        )
        if arguments.command == "report":
            report = render_report(receipt)
            arguments.output.write_text(report, encoding="utf-8")
        _print_receipt(receipt)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    except RecursionError:
        parser.error("input nesting is too deep")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
