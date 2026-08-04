#!/usr/bin/env python3
"""Validate and report Echo's neural OOV qualification evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
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
CONVERSION_VERSION = "mini-bart-arpabet-to-kokoro-ipa-v1"
VALIDATION_VERSION = "kokoro-vocab-validation-v1"
SELECTION_VERSION = "neural-oov-complete-selection-v1"
AUTHORIZATION_PURPOSE = "neural-g2p-human-evidence-qualification"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")

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
) -> tuple[list[dict[str, Any]], str | None]:
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
    if (
        not isinstance(authority, dict)
        or set(authority) != AUTHORITY_FIELDS
        or authority.get("schemaVersion") != 1
        or authority.get("authorityKind")
        != "user-controlled-out-of-repository"
        or authority.get("authorizationPurpose") != AUTHORIZATION_PURPOSE
        or not isinstance(authority.get("evidenceBundleSHA256"), str)
        or SHA256_PATTERN.fullmatch(authority["evidenceBundleSHA256"]) is None
    ):
        raise ValueError("human evidence authority is invalid")
    digest = authority["evidenceBundleSHA256"]
    if candidates is not None and digest != evidence_authority_digest(
        candidates, receipts
    ):
        raise ValueError(
            "trusted receipts require an exact human evidence authority binding"
        )
    return receipts, digest


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


def _load_json(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(f"{path} is unavailable or invalid UTF-8") from error
    return _strict_json_loads(text, path.name)


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        content = path.read_bytes()
    except OSError as error:
        raise ValueError(f"{path} is unavailable") from error
    return _decode_external_jsonl(content, path.name)


def _model_identity(lock_path: Path | str, vocab_path: Path | str) -> dict[str, Any]:
    lock_file = Path(lock_path)
    vocab_file = Path(vocab_path)
    lock = _load_json(lock_file)
    vocab_document = _load_json(vocab_file)
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
    if (
        not isinstance(vocab_document, dict)
        or set(vocab_document) != {"vocab"}
        or not isinstance(vocab_document["vocab"], dict)
    ):
        raise ValueError("Kokoro vocabulary is invalid")
    return {
        "model": lock["model"],
        "revision": lock["revision"],
        "lockSHA256": hashlib.sha256(lock_file.read_bytes()).hexdigest(),
        "artifactSHA256": {
            path: artifact_hashes[path] for path in sorted(artifact_hashes)
        },
        "vocabSHA256": hashlib.sha256(vocab_file.read_bytes()).hexdigest(),
    }


def _vocabulary(vocab_path: Path | str) -> dict[str, int]:
    document = _load_json(Path(vocab_path))
    if (
        not isinstance(document, dict)
        or set(document) != {"vocab"}
        or not isinstance(document["vocab"], dict)
        or any(
            not isinstance(symbol, str)
            or len(symbol) != 1
            or not isinstance(token_id, int)
            or isinstance(token_id, bool)
            or token_id < 0
            for symbol, token_id in document["vocab"].items()
        )
    ):
        raise ValueError("Kokoro vocabulary is invalid")
    return document["vocab"]


def _gold_label(receipt: dict[str, Any]) -> str:
    if receipt["labelA"] == receipt["labelB"]:
        return receipt["labelA"]
    assert receipt["adjudicated"] is not None
    return receipt["adjudicated"]


def qualification_status(
    raw_candidates: Iterable[dict[str, Any]],
    raw_receipts: Iterable[dict[str, Any]],
    trusted_authority_digest: str | None,
    lock_path: Path | str,
    vocab_path: Path | str,
) -> dict[str, Any]:
    candidates = validate_candidates(raw_candidates)
    receipts = validate_trusted_receipts(raw_receipts)
    if receipts:
        expected_digest = evidence_authority_digest(candidates, receipts)
        if trusted_authority_digest != expected_digest:
            raise ValueError(
                "trusted receipts require an exact human evidence authority binding"
            )
    elif trusted_authority_digest is not None:
        raise ValueError("human evidence authority cannot bind empty trusted receipts")

    model_identity = _model_identity(lock_path, vocab_path)
    expected_receipt_identity = {
        "modelRevision": model_identity["revision"],
        "modelLockSHA256": model_identity["lockSHA256"],
        "vocabSHA256": model_identity["vocabSHA256"],
        "conversionVersion": CONVERSION_VERSION,
        "validationVersion": VALIDATION_VERSION,
        "selectionVersion": SELECTION_VERSION,
    }
    candidates_by_id = {row["caseID"]: row for row in candidates}
    vocab = _vocabulary(vocab_path)
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

    return {
        "schemaVersion": 1,
        "status": status,
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
    performance_proof_state: str,
    device_proof_state: str,
) -> str:
    if not _nonempty_string(performance_proof_state):
        raise ValueError("performance proof state must be nonempty")
    if not _nonempty_string(device_proof_state):
        raise ValueError("device proof state must be nonempty")
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

- Performance proof: `{performance_proof_state}`
- Device proof: `{device_proof_state}`

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
                "--performance-proof-state", required=True
            )
            command_parser.add_argument("--device-proof-state", required=True)
    arguments = parser.parse_args(argv)

    try:
        candidates = validate_candidates(_load_jsonl(arguments.corpus))
        receipts, authority_digest = load_external_evidence(
            arguments.trusted_receipts,
            arguments.human_evidence_authority,
            candidates=candidates,
        )
        receipt = qualification_status(
            candidates,
            receipts,
            authority_digest,
            arguments.lock,
            arguments.vocab,
        )
        if arguments.command == "report":
            report = render_report(
                receipt,
                performance_proof_state=arguments.performance_proof_state,
                device_proof_state=arguments.device_proof_state,
            )
            arguments.output.write_text(report, encoding="utf-8")
        _print_receipt(receipt)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    except RecursionError:
        parser.error("input nesting is too deep")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
