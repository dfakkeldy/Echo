#!/usr/bin/env python3
"""Validate Echo's public/synthetic pronunciation evaluation corpus contracts."""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Iterable
from urllib.parse import urlsplit


CONTEXTUAL_FAMILIES = {
    "content": {"content.material", "content.satisfied"},
    "read": {"read.present", "read.past"},
    "live": {"live.adjective", "live.verb", "lives.noun", "lives.verb"},
    "record": {"record.noun", "record.verb"},
}

TARGET_CANDIDATES = {
    "content": {"content": {"content.material", "content.satisfied"}},
    "read": {"read": {"read.present", "read.past"}},
    "live": {
        "live": {"live.adjective", "live.verb"},
        "lives": {"lives.noun", "lives.verb"},
    },
    "record": {"record": {"record.noun", "record.verb"}},
}

REQUIRED_NAMED_SHAPES = {
    "capitalization",
    "direct-grammatical-cue",
    "heading-fragment",
    "long-distance-cue",
    "malformed-fragment",
    "misleading-adjacent-cue",
    "override-markup",
    "punctuation-adjacency",
    "quotation-dialogue",
}

ALLOWED_PROVENANCE = {"public-domain", "permissive", "synthetic"}
HUMAN_EVIDENCE_FIELDS = {
    "labelA",
    "labelB",
    "adjudicated",
    "labelEvidenceKind",
    "labelEvidenceID",
}
HUMAN_EVIDENCE_KINDS = {"independent-human", "source-verifiable"}
PRIVATE_KEYS = {"bookTitle", "author", "userID", "localPath"}
MINIMUM_FAMILY_CASES = 200
MINIMUM_SENSE_CASES = 50

CONTEXTUAL_REQUIRED_FIELDS = {
    "caseID",
    "familyID",
    "targetWord",
    "precedingSentence",
    "targetSentence",
    "followingSentence",
    "labelStatus",
    "provenance",
}
CONTEXTUAL_ALLOWED_FIELDS = (
    CONTEXTUAL_REQUIRED_FIELDS
    | HUMAN_EVIDENCE_FIELDS
    | {"sourceURL", "license"}
)
TRUSTED_RECEIPT_FIELDS = {
    "receiptID",
    "caseID",
    "evidenceKind",
    "labelA",
    "labelB",
    "adjudicated",
}


@dataclass(frozen=True)
class ContextualCase:
    case_id: str
    family_id: str
    target_word: str
    preceding_sentence: str | None
    target_sentence: str
    following_sentence: str | None
    label_status: str
    label_a: str | None
    label_b: str | None
    adjudicated: str | None
    label_evidence_kind: str | None
    label_evidence_id: str | None
    provenance: str


@dataclass(frozen=True)
class TrustedLabelReceipt:
    receipt_id: str
    case_id: str
    evidence_kind: str
    label_a: str
    label_b: str
    adjudicated: str | None


@dataclass(frozen=True)
class QualificationResult:
    status: str
    family_counts: dict[str, int]
    sense_counts: dict[str, int]
    missing_family_counts: dict[str, int]
    missing_sense_counts: dict[str, int]

    def as_summary(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "minimumCasesPerFamily": MINIMUM_FAMILY_CASES,
            "minimumCasesPerSense": MINIMUM_SENSE_CASES,
            "familyCounts": self.family_counts,
            "senseCounts": self.sense_counts,
            "missingFamilyCounts": self.missing_family_counts,
            "missingSenseCounts": self.missing_sense_counts,
        }


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _contains_absolute_local_path(value: str) -> bool:
    for match in re.finditer(r"(?<![:/\w])/(?!/)\S*", value):
        fragment = match.group().rstrip(".,;:!?)}]>\"'")
        if (
            value[max(0, match.start() - 2) : match.start()] == "]("
            and fragment.endswith("/")
        ):
            continue
        if PurePosixPath(fragment).is_absolute():
            return True

    windows_pattern = re.compile(
        r"(?<!\w)(?:[A-Za-z]:[\\/]|\\\\|\\(?!\\))\S+"
    )
    for match in windows_pattern.finditer(value):
        fragment = match.group().rstrip(".,;:!?)}]>\"'")
        windows_path = PureWindowsPath(fragment)
        if windows_path.is_absolute() or bool(windows_path.root):
            return True
    return False


def _validate_no_private_data(value: Any, location: str = "record") -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in PRIVATE_KEYS:
                raise ValueError(f"{location} contains prohibited private field {key}")
            _validate_no_private_data(nested, f"{location}.{key}")
        return
    if isinstance(value, list):
        for index, nested in enumerate(value):
            _validate_no_private_data(nested, f"{location}[{index}]")
        return
    if not isinstance(value, str):
        return

    candidate = value.strip()
    if re.search(r"file://", candidate, flags=re.IGNORECASE):
        raise ValueError(f"{location} contains a prohibited file:// URL")
    if _contains_absolute_local_path(candidate):
        raise ValueError(f"{location} contains prohibited absolute paths")


def _validate_fields(
    record: dict[str, Any],
    *,
    required: set[str],
    allowed: set[str],
    record_name: str,
) -> None:
    missing = sorted(required - record.keys())
    if missing:
        raise ValueError(
            f"{record_name} missing required fields: {', '.join(missing)}"
        )
    unexpected = sorted(record.keys() - allowed)
    if unexpected:
        raise ValueError(
            f"{record_name} contains unexpected fields: {', '.join(unexpected)}"
        )


def _validate_provenance(record: dict[str, Any], record_name: str) -> None:
    provenance = record.get("provenance")
    if provenance not in ALLOWED_PROVENANCE:
        raise ValueError(
            f"{record_name} provenance must be public-domain, permissive, or synthetic"
        )
    if provenance == "synthetic":
        unexpected = {"sourceURL", "license"} & record.keys()
        if unexpected:
            raise ValueError(
                f"{record_name} synthetic provenance cannot contain "
                f"{', '.join(sorted(unexpected))}"
            )
        return

    if not _is_nonempty_string(record.get("sourceURL")) or not _is_nonempty_string(
        record.get("license")
    ):
        raise ValueError(
            f"{record_name} non-synthetic provenance requires sourceURL and license"
        )
    parsed_url = urlsplit(record["sourceURL"])
    if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
        raise ValueError(f"{record_name} sourceURL must be an HTTP(S) URL")


def _target_words_for_family(family_id: str) -> set[str]:
    return set(TARGET_CANDIDATES[family_id])


def _candidates_for_target(family_id: str, target_word: str) -> set[str]:
    return TARGET_CANDIDATES[family_id][target_word.casefold()]


def _contains_whole_target_token(sentence: str, target_word: str) -> bool:
    folded_sentence = sentence.casefold()
    folded_target = target_word.casefold()

    def is_token_character(character: str) -> bool:
        return (
            character == "_"
            or unicodedata.category(character)[0] in {"L", "M", "N"}
        )

    search_start = 0
    while True:
        match_start = folded_sentence.find(folded_target, search_start)
        if match_start < 0:
            return False
        match_end = match_start + len(folded_target)
        before_is_token = match_start > 0 and is_token_character(
            folded_sentence[match_start - 1]
        )
        after_is_token = match_end < len(folded_sentence) and is_token_character(
            folded_sentence[match_end]
        )
        if not before_is_token and not after_is_token:
            return True
        search_start = match_start + 1


def _contextual_case_to_record(case: ContextualCase) -> dict[str, Any]:
    values = asdict(case)
    return {
        "caseID": values["case_id"],
        "familyID": values["family_id"],
        "targetWord": values["target_word"],
        "precedingSentence": values["preceding_sentence"],
        "targetSentence": values["target_sentence"],
        "followingSentence": values["following_sentence"],
        "labelStatus": values["label_status"],
        "labelA": values["label_a"],
        "labelB": values["label_b"],
        "adjudicated": values["adjudicated"],
        "labelEvidenceKind": values["label_evidence_kind"],
        "labelEvidenceID": values["label_evidence_id"],
        "provenance": values["provenance"],
    }


def _parse_contextual_case(raw_case: dict[str, Any] | ContextualCase) -> ContextualCase:
    record = (
        _contextual_case_to_record(raw_case)
        if isinstance(raw_case, ContextualCase)
        else raw_case
    )
    if not isinstance(record, dict):
        raise ValueError("contextual case must be a JSON object")

    _validate_no_private_data(record, "contextual case")
    _validate_fields(
        record,
        required=CONTEXTUAL_REQUIRED_FIELDS,
        allowed=CONTEXTUAL_ALLOWED_FIELDS,
        record_name="contextual case",
    )
    _validate_provenance(record, "contextual case")

    string_fields = ("caseID", "familyID", "targetWord", "targetSentence")
    for field in string_fields:
        if not _is_nonempty_string(record[field]):
            raise ValueError(f"contextual case {field} must be a nonempty string")
    for field in ("precedingSentence", "followingSentence"):
        if record[field] is not None and not _is_nonempty_string(record[field]):
            raise ValueError(f"contextual case {field} must be null or nonempty text")

    family_id = record["familyID"]
    if family_id not in CONTEXTUAL_FAMILIES:
        raise ValueError(f"unknown contextual family {family_id}")
    normalized_target = record["targetWord"].casefold()
    if normalized_target not in _target_words_for_family(family_id):
        raise ValueError(
            f"targetWord {record['targetWord']} does not belong to family {family_id}"
        )
    if not _contains_whole_target_token(
        record["targetSentence"], record["targetWord"]
    ):
        raise ValueError(
            f"targetSentence must contain whole target token {record['targetWord']}"
        )

    label_status = record["labelStatus"]
    if label_status not in {"provisional", "human-labelled"}:
        raise ValueError("labelStatus must be provisional or human-labelled")

    evidence_values = {field: record.get(field) for field in HUMAN_EVIDENCE_FIELDS}
    if label_status == "provisional":
        if any(value is not None for value in evidence_values.values()):
            raise ValueError(
                "provisional rows cannot contain human evidence fields"
            )
    else:
        if not _is_nonempty_string(record.get("labelA")) or not _is_nonempty_string(
            record.get("labelB")
        ):
            raise ValueError("human-labelled rows require labelA and labelB")
        if record.get("labelEvidenceKind") not in HUMAN_EVIDENCE_KINDS:
            raise ValueError(
                "human-labelled rows require independent-human or source-verifiable evidence"
            )
        if not _is_nonempty_string(record.get("labelEvidenceID")):
            raise ValueError(
                "human-labelled rows require a nonempty labelEvidenceID"
            )

        family_candidates = CONTEXTUAL_FAMILIES[family_id]
        target_candidates = _candidates_for_target(family_id, record["targetWord"])
        for field in ("labelA", "labelB", "adjudicated"):
            label = record.get(field)
            if label is not None and label not in family_candidates:
                raise ValueError(
                    f"{field} {label} is not a candidate for family {family_id}"
                )
            if label is not None and label not in target_candidates:
                raise ValueError(
                    f"{field} {label} is not a candidate for targetWord "
                    f"{record['targetWord']}"
                )
        if record["labelA"] != record["labelB"] and record.get("adjudicated") is None:
            raise ValueError(
                "human-labelled dual-label disagreement requires adjudicated"
            )
        if (
            record["labelA"] == record["labelB"]
            and record.get("adjudicated") is not None
            and record["adjudicated"] != record["labelA"]
        ):
            raise ValueError(
                "adjudicated must equal the agreeing labels or be absent"
            )

    return ContextualCase(
        case_id=record["caseID"],
        family_id=family_id,
        target_word=record["targetWord"],
        preceding_sentence=record["precedingSentence"],
        target_sentence=record["targetSentence"],
        following_sentence=record["followingSentence"],
        label_status=label_status,
        label_a=record.get("labelA"),
        label_b=record.get("labelB"),
        adjudicated=record.get("adjudicated"),
        label_evidence_kind=record.get("labelEvidenceKind"),
        label_evidence_id=record.get("labelEvidenceID"),
        provenance=record["provenance"],
    )


def validate_contract(
    raw_cases: Iterable[dict[str, Any] | ContextualCase],
) -> list[ContextualCase]:
    parsed: list[ContextualCase] = []
    seen_case_ids: set[str] = set()
    for raw_case in raw_cases:
        case = _parse_contextual_case(raw_case)
        if case.case_id in seen_case_ids:
            raise ValueError(f"duplicate caseID {case.case_id}")
        seen_case_ids.add(case.case_id)
        parsed.append(case)
    return parsed


def _trusted_receipt_to_record(
    receipt: TrustedLabelReceipt,
) -> dict[str, Any]:
    return {
        "receiptID": receipt.receipt_id,
        "caseID": receipt.case_id,
        "evidenceKind": receipt.evidence_kind,
        "labelA": receipt.label_a,
        "labelB": receipt.label_b,
        "adjudicated": receipt.adjudicated,
    }


def validate_trusted_receipts(
    raw_receipts: Iterable[dict[str, Any] | TrustedLabelReceipt],
) -> list[TrustedLabelReceipt]:
    receipts: list[TrustedLabelReceipt] = []
    seen_receipt_ids: set[str] = set()
    seen_case_ids: set[str] = set()
    for raw_receipt in raw_receipts:
        record = (
            _trusted_receipt_to_record(raw_receipt)
            if isinstance(raw_receipt, TrustedLabelReceipt)
            else raw_receipt
        )
        if not isinstance(record, dict):
            raise ValueError("trusted receipt must be a JSON object")
        _validate_no_private_data(record, "trusted receipt")
        _validate_fields(
            record,
            required=TRUSTED_RECEIPT_FIELDS,
            allowed=TRUSTED_RECEIPT_FIELDS,
            record_name="trusted receipt",
        )
        for field in ("receiptID", "caseID", "evidenceKind", "labelA", "labelB"):
            if not _is_nonempty_string(record[field]):
                raise ValueError(f"trusted receipt {field} must be nonempty")
        if record["adjudicated"] is not None and not _is_nonempty_string(
            record["adjudicated"]
        ):
            raise ValueError("trusted receipt adjudicated must be null or nonempty")
        if record["evidenceKind"] not in HUMAN_EVIDENCE_KINDS:
            raise ValueError(
                "trusted receipt evidenceKind must be independent-human "
                "or source-verifiable"
            )
        if record["receiptID"] in seen_receipt_ids:
            raise ValueError(f"duplicate receiptID {record['receiptID']}")
        if record["caseID"] in seen_case_ids:
            raise ValueError(
                f"multiple trusted receipts for caseID {record['caseID']}"
            )
        seen_receipt_ids.add(record["receiptID"])
        seen_case_ids.add(record["caseID"])
        receipts.append(
            TrustedLabelReceipt(
                receipt_id=record["receiptID"],
                case_id=record["caseID"],
                evidence_kind=record["evidenceKind"],
                label_a=record["labelA"],
                label_b=record["labelB"],
                adjudicated=record["adjudicated"],
            )
        )
    return receipts


def _gold_label(case: ContextualCase) -> str:
    if case.label_a == case.label_b:
        assert case.label_a is not None
        return case.label_a
    assert case.adjudicated is not None
    return case.adjudicated


def qualification_status(
    raw_cases: Iterable[dict[str, Any] | ContextualCase],
    *,
    trusted_receipts: Iterable[
        dict[str, Any] | TrustedLabelReceipt
    ] | None = None,
) -> QualificationResult:
    cases = validate_contract(raw_cases)
    receipts = validate_trusted_receipts(trusted_receipts or [])
    receipts_by_id = {receipt.receipt_id: receipt for receipt in receipts}
    receipt_claims: dict[str, str] = {}
    family_counts = Counter({family: 0 for family in CONTEXTUAL_FAMILIES})
    sense_counts = Counter(
        {
            candidate: 0
            for candidates in CONTEXTUAL_FAMILIES.values()
            for candidate in candidates
        }
    )

    for case in cases:
        if case.label_status != "human-labelled":
            continue
        assert case.label_evidence_id is not None
        receipt = receipts_by_id.get(case.label_evidence_id)
        if receipt is None:
            continue
        previous_case_id = receipt_claims.get(receipt.receipt_id)
        if previous_case_id is not None and previous_case_id != case.case_id:
            raise ValueError(
                f"trusted receipt {receipt.receipt_id} cannot qualify multiple cases"
            )
        receipt_claims[receipt.receipt_id] = case.case_id
        if (
            receipt.case_id != case.case_id
            or receipt.evidence_kind != case.label_evidence_kind
            or receipt.label_a != case.label_a
            or receipt.label_b != case.label_b
            or receipt.adjudicated != case.adjudicated
        ):
            raise ValueError(
                f"trusted receipt {receipt.receipt_id} does not exactly match case "
                f"{case.case_id}"
            )
        family_counts[case.family_id] += 1
        sense_counts[_gold_label(case)] += 1

    missing_family_counts = {
        family: MINIMUM_FAMILY_CASES - family_counts[family]
        for family in sorted(CONTEXTUAL_FAMILIES)
        if family_counts[family] < MINIMUM_FAMILY_CASES
    }
    missing_sense_counts = {
        sense: MINIMUM_SENSE_CASES - sense_counts[sense]
        for sense in sorted(sense_counts)
        if sense_counts[sense] < MINIMUM_SENSE_CASES
    }
    status = (
        "QUALIFIED"
        if not missing_family_counts and not missing_sense_counts
        else "WAITING_FOR_HUMAN_LABELS"
    )
    return QualificationResult(
        status=status,
        family_counts={family: family_counts[family] for family in sorted(family_counts)},
        sense_counts={sense: sense_counts[sense] for sense in sorted(sense_counts)},
        missing_family_counts=missing_family_counts,
        missing_sense_counts=missing_sense_counts,
    )


def validate_distribution_works(raw_works: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_works, list):
        raise ValueError("distribution works must be a JSON array")

    required = {"workID", "provenance", "cases"}
    allowed = required | {"genre", "sampleSentences", "sourceURL", "license"}
    seen_work_ids: set[str] = set()
    works: list[dict[str, Any]] = []
    for raw_work in raw_works:
        if not isinstance(raw_work, dict):
            raise ValueError("distribution work must be a JSON object")
        _validate_no_private_data(raw_work, "distribution work")
        _validate_fields(
            raw_work,
            required=required,
            allowed=allowed,
            record_name="distribution work",
        )
        _validate_provenance(raw_work, "distribution work")
        if not _is_nonempty_string(raw_work["workID"]):
            raise ValueError("distribution workID must be a nonempty string")
        if raw_work["workID"] in seen_work_ids:
            raise ValueError(f"duplicate workID {raw_work['workID']}")
        seen_work_ids.add(raw_work["workID"])
        if (
            not isinstance(raw_work["cases"], int)
            or isinstance(raw_work["cases"], bool)
            or raw_work["cases"] < 1
        ):
            raise ValueError("distribution work cases must be a positive integer")
        if "sampleSentences" in raw_work and (
            not isinstance(raw_work["sampleSentences"], list)
            or not all(
                _is_nonempty_string(sentence)
                for sentence in raw_work["sampleSentences"]
            )
        ):
            raise ValueError("sampleSentences must be a list of nonempty strings")
        works.append(raw_work)

    if len(seen_work_ids) < 10:
        raise ValueError("distribution corpus requires at least 10 works")
    return works


def validate_morphology(raw_rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    required = {
        "caseID",
        "word",
        "expectedBase",
        "expectedRuleID",
        "expectedIPA",
        "automatic",
    }
    seen_case_ids: set[str] = set()
    rows: list[dict[str, Any]] = []
    for raw_row in raw_rows:
        if not isinstance(raw_row, dict):
            raise ValueError("morphology row must be a JSON object")
        _validate_no_private_data(raw_row, "morphology row")
        missing_derivation_fields = {
            "expectedBase",
            "expectedRuleID",
            "expectedIPA",
        } - raw_row.keys()
        if raw_row.get("automatic") is True and missing_derivation_fields:
            raise ValueError(
                "automatic morphology row requires an expected derivation result"
            )
        _validate_fields(
            raw_row,
            required=required,
            allowed=required,
            record_name="morphology row",
        )
        if not _is_nonempty_string(raw_row["caseID"]) or not _is_nonempty_string(
            raw_row["word"]
        ):
            raise ValueError("morphology caseID and word must be nonempty strings")
        if raw_row["caseID"] in seen_case_ids:
            raise ValueError(f"duplicate caseID {raw_row['caseID']}")
        seen_case_ids.add(raw_row["caseID"])
        if not isinstance(raw_row["automatic"], bool):
            raise ValueError("morphology automatic must be a boolean")

        derivation = (
            raw_row["expectedBase"],
            raw_row["expectedRuleID"],
            raw_row["expectedIPA"],
        )
        if raw_row["automatic"]:
            if not all(_is_nonempty_string(value) for value in derivation):
                raise ValueError(
                    "automatic morphology row requires an expected derivation result"
                )
        elif any(value is not None for value in derivation):
            raise ValueError("morphology negative guard cannot claim a derivation")
        rows.append(raw_row)
    return rows


def validate_named_regressions(
    raw_rows: Iterable[dict[str, Any]],
) -> list[dict[str, Any]]:
    required = {
        "caseID",
        "familyID",
        "targetWord",
        "shape",
        "precedingSentence",
        "targetSentence",
        "followingSentence",
        "expectedCandidateID",
        "expectedOutcome",
        "provenance",
    }
    allowed = required | {"sourceURL", "license"}
    seen_case_ids: set[str] = set()
    shapes_by_family: dict[str, set[str]] = {
        family: set() for family in CONTEXTUAL_FAMILIES
    }
    rows: list[dict[str, Any]] = []
    for raw_row in raw_rows:
        if not isinstance(raw_row, dict):
            raise ValueError("named regression must be a JSON object")
        _validate_no_private_data(raw_row, "named regression")
        _validate_fields(
            raw_row,
            required=required,
            allowed=allowed,
            record_name="named regression",
        )
        _validate_provenance(raw_row, "named regression")
        for field in (
            "caseID",
            "familyID",
            "targetWord",
            "shape",
            "targetSentence",
            "expectedCandidateID",
            "expectedOutcome",
        ):
            if not _is_nonempty_string(raw_row[field]):
                raise ValueError(f"named regression {field} must be nonempty")
        for field in ("precedingSentence", "followingSentence"):
            if raw_row[field] is not None and not _is_nonempty_string(raw_row[field]):
                raise ValueError(f"named regression {field} must be null or nonempty")
        if raw_row["caseID"] in seen_case_ids:
            raise ValueError(f"duplicate caseID {raw_row['caseID']}")
        seen_case_ids.add(raw_row["caseID"])

        family_id = raw_row["familyID"]
        if family_id not in CONTEXTUAL_FAMILIES:
            raise ValueError(f"unknown contextual family {family_id}")
        if raw_row["targetWord"].casefold() not in _target_words_for_family(family_id):
            raise ValueError(
                f"targetWord {raw_row['targetWord']} does not belong to family {family_id}"
            )
        if not _contains_whole_target_token(
            raw_row["targetSentence"], raw_row["targetWord"]
        ):
            raise ValueError(
                f"targetSentence must contain whole target token "
                f"{raw_row['targetWord']}"
            )
        if raw_row["expectedCandidateID"] not in CONTEXTUAL_FAMILIES[family_id]:
            raise ValueError(
                f"expectedCandidateID {raw_row['expectedCandidateID']} "
                f"is not a candidate for family {family_id}"
            )
        if raw_row["expectedCandidateID"] not in _candidates_for_target(
            family_id, raw_row["targetWord"]
        ):
            raise ValueError(
                f"expectedCandidateID {raw_row['expectedCandidateID']} "
                f"is not a candidate for targetWord {raw_row['targetWord']}"
            )
        if raw_row["expectedOutcome"] not in {"automatic", "review"}:
            raise ValueError("expectedOutcome must be automatic or review")
        if raw_row["shape"] not in REQUIRED_NAMED_SHAPES:
            raise ValueError(f"unknown named regression shape {raw_row['shape']}")
        shapes_by_family[family_id].add(raw_row["shape"])
        rows.append(raw_row)

    missing = {
        family: sorted(REQUIRED_NAMED_SHAPES - shapes)
        for family, shapes in shapes_by_family.items()
        if shapes != REQUIRED_NAMED_SHAPES
    }
    if missing:
        raise ValueError(f"missing named regression shapes: {json.dumps(missing)}")
    return rows


def _read_utf8(path: Path) -> str:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {path.name}: {error}") from error
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        line_number = data[: error.start].count(b"\n") + 1
        raise ValueError(
            f"{path.name}:{line_number} is not valid UTF-8: {error.reason}"
        ) from error


def _strict_json_loads(text: str, location: str) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"{location} contains duplicate key {key}")
            result[key] = value
        return result

    def reject_nonstandard_constant(value: str) -> None:
        raise ValueError(
            f"{location} contains non-standard JSON constant {value}"
        )

    try:
        return json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_constant,
        )
    except json.JSONDecodeError as error:
        raise ValueError(
            f"{location} is not valid JSON: {error.msg} "
            f"at column {error.colno}"
        ) from error


def _load_json(path: Path) -> Any:
    return _strict_json_loads(_read_utf8(path), path.name)


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    lines = _read_utf8(path).splitlines()
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        row = _strict_json_loads(line, f"{path.name}:{line_number}")
        if not isinstance(row, dict):
            raise ValueError(f"{path.name}:{line_number} must contain a JSON object")
        rows.append(row)
    return rows


def _validate_candidate_research(path: Path) -> int:
    research = _load_json(path)
    if not isinstance(research, dict):
        raise ValueError("candidate source research must be a JSON object")
    _validate_no_private_data(research, "candidate source research")
    if research.get("status") != "candidate-research-only":
        raise ValueError("candidate source research must remain candidate-research-only")
    if research.get("acceptedCorpusEvidence") is not False:
        raise ValueError("candidate source research cannot be accepted corpus evidence")
    if research.get("redistributionStatus") != "unresolved":
        raise ValueError("candidate source redistribution status must remain unresolved")
    sources = research.get("sources")
    if not isinstance(sources, list) or len(sources) != 5:
        raise ValueError("candidate source research must record exactly five sources")
    source_ids: set[str] = set()
    for source in sources:
        if not isinstance(source, dict) or not _is_nonempty_string(
            source.get("sourceID")
        ):
            raise ValueError("candidate source research requires sourceID")
        if source["sourceID"] in source_ids:
            raise ValueError(f"duplicate candidate sourceID {source['sourceID']}")
        source_ids.add(source["sourceID"])
        if source.get("acceptedCorpusEvidence") is not False:
            raise ValueError(
                f"candidate source {source['sourceID']} cannot be accepted evidence"
            )
    return len(sources)


def validate_fixture_directory(fixtures: Path | str) -> dict[str, Any]:
    fixture_directory = Path(fixtures)
    named_path = fixture_directory / "named_regressions_v1.jsonl"
    candidates_path = fixture_directory / "contextual_family_candidates_v1.jsonl"
    labelled_path = fixture_directory / "contextual_families_v1.jsonl"
    distribution_path = fixture_directory / "distribution_works_v1.json"
    morphology_path = fixture_directory / "morphology_v1.jsonl"
    research_path = fixture_directory / "candidate_source_research_v1.json"

    required_paths = (
        named_path,
        candidates_path,
        distribution_path,
        morphology_path,
        research_path,
    )
    missing = [path.name for path in required_paths if not path.is_file()]
    if missing:
        raise ValueError(f"missing pronunciation fixtures: {', '.join(sorted(missing))}")

    named_rows = validate_named_regressions(_load_jsonl(named_path))
    candidate_rows = _load_jsonl(candidates_path)
    if any(row.get("labelStatus") != "provisional" for row in candidate_rows):
        raise ValueError("contextual candidate fixture may contain only provisional rows")

    labelled_rows = _load_jsonl(labelled_path) if labelled_path.is_file() else []
    if any(row.get("labelStatus") != "human-labelled" for row in labelled_rows):
        raise ValueError(
            "contextual labelled fixture may contain only human-labelled rows"
        )
    contextual_records = candidate_rows + labelled_rows
    validate_contract(contextual_records)
    distribution_works = validate_distribution_works(_load_json(distribution_path))
    morphology_rows = validate_morphology(_load_jsonl(morphology_path))
    research_sources = _validate_candidate_research(research_path)

    return {
        "status": "CONTRACT_VALID",
        "namedRegressions": len(named_rows),
        "contextualCandidates": len(candidate_rows),
        "humanLabelledCases": len(labelled_rows),
        "humanLabelledFixturePresent": labelled_path.is_file(),
        "distributionWorks": len(distribution_works),
        "morphologyCases": len(morphology_rows),
        "candidateResearchSources": research_sources,
        "contextualRecords": contextual_records,
    }


def _print_json(summary: dict[str, Any]) -> None:
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    contract_parser = subparsers.add_parser("validate-contract")
    contract_parser.add_argument("--fixtures", type=Path, required=True)
    qualification_parser = subparsers.add_parser("qualification-status")
    qualification_parser.add_argument("--fixtures", type=Path, required=True)
    qualification_parser.add_argument("--trusted-receipts", type=Path)
    arguments = parser.parse_args(argv)

    try:
        summary = validate_fixture_directory(arguments.fixtures)
        contextual_records = summary.pop("contextualRecords")
        if arguments.command == "validate-contract":
            _print_json(summary)
        else:
            trusted_receipts = (
                _load_jsonl(arguments.trusted_receipts)
                if arguments.trusted_receipts is not None
                else []
            )
            _print_json(
                qualification_status(
                    contextual_records,
                    trusted_receipts=trusted_receipts,
                ).as_summary()
            )
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
