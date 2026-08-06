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
import unicodedata
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
CAPITALIZATION_VARIANTS = ("lowercase", "titlecase", "uppercase")
PUNCTUATION_VARIANTS = ("none", "leading", "trailing", "paired")
SENTENCE_POSITION_VARIANTS = ("initial", "medial", "final")
SYSTEMATIC_VARIANTS = {
    "capitalization": CAPITALIZATION_VARIANTS,
    "punctuation": PUNCTUATION_VARIANTS,
    "sentencePosition": SENTENCE_POSITION_VARIANTS,
}
ALLOWED_PROVENANCE = {"public-domain", "permissive", "synthetic"}
MINIMUM_REVIEWED_CASES = 500
MINIMUM_CASES_PER_CATEGORY = 75
MINIMUM_CASES_PER_SYSTEMATIC_VARIANT = 25
MINIMUM_AUTOMATIC_CASES = 500
MINIMUM_PRECISION = 0.99
MINIMUM_WILSON_95_LOWER_BOUND = 0.98
CONVERSION_VERSION = "mini-bart-arpabet-to-kokoro-v1"
VALIDATION_VERSION = "kokoro-vocab-validation-v1"
SELECTION_VERSION = "neural-oov-complete-selection-v1"
QUALIFICATION_RECEIPT_SCHEMA_VERSION = 3
AUTHORIZATION_PURPOSE = "neural-g2p-human-evidence-qualification"
MACHINE_EVIDENCE_GENERATOR = "echo-mini-bart-g2p-locked-evaluator-v1"
MACHINE_EVIDENCE_SCHEMA_VERSION = 1
RUNTIME_EVIDENCE_KIND = "neural-g2p-runtime-qualification-v1"
RUNTIME_EVIDENCE_SCHEMA_VERSION = 1
RUNTIME_LISTENING_AUTHORIZATION_PURPOSE = (
    "neural-g2p-runtime-listening-qualification"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
PROOF_STATE_VOCABULARY = {
    "corpus": frozenset({"CONTRACT_VALID"}),
    "human": frozenset({"WAITING_FOR_HUMAN_LABELS", "FAILED", "QUALIFIED"}),
    "performance": frozenset(
        {"NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
    "device": frozenset(
        {"NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
    "render": frozenset(
        {"NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
    "listening": frozenset(
        {"NOT_PROVIDED", "FAILED", "VERIFIED"}
    ),
}
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GOLD_PATH = (
    REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_gold.json"
)
DEFAULT_SILVER_PATH = (
    REPOSITORY_ROOT / "EchoCore/Services/Narration/MisakiResources/us_silver.json"
)
DEFAULT_PRONUNCIATION_PACK_PATH = (
    REPOSITORY_ROOT
    / "EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json"
)

CANDIDATE_REQUIRED_FIELDS = {
    "caseID",
    "word",
    "category",
    "context",
    "capitalization",
    "punctuation",
    "sentencePosition",
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
}
MACHINE_RECEIPT_FIELDS = {
    "schemaVersion",
    "generatorID",
    "receiptID",
    "caseID",
    "evaluatorInputSHA256",
    "rawModelOutputs",
    "convertedOutputs",
    "mappedTokenIDs",
    "genuineDeterministicOOV",
    "stable",
    "automaticSelectionEligible",
    "selectedIPA",
    "modelRevision",
    "modelLockSHA256",
    "vocabSHA256",
    "goldLexiconSHA256",
    "silverLexiconSHA256",
    "pronunciationPackSHA256",
    "conversionVersion",
    "validationVersion",
    "selectionVersion",
    "receiptSHA256",
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


def _normalized_evaluator_input(word: str) -> str:
    normalized = word.casefold()
    if (
        re.fullmatch(r"[a-z](?:[a-z'-]*[a-z])?", normalized) is None
        or "''" in normalized
        or "--" in normalized
        or "'-" in normalized
        or "-'" in normalized
    ):
        raise ValueError("candidate word is not one governed evaluator input")
    return normalized


def _capitalization_variant(word: str) -> str | None:
    letters = [character for character in word if character.isalpha()]
    if not letters:
        return None
    if all(character.islower() for character in letters):
        return "lowercase"
    if letters[0].isupper() and all(character.islower() for character in letters[1:]):
        return "titlecase"
    if all(character.isupper() for character in letters):
        return "uppercase"
    return None


def _is_punctuation(character: str) -> bool:
    return bool(character) and unicodedata.category(character).startswith("P")


def _context_variants(word: str, context: str) -> tuple[str, str]:
    if context.count(word) != 1:
        raise ValueError("candidate context must contain its exact word once")
    start = context.index(word)
    end = start + len(word)
    has_leading = start > 0 and _is_punctuation(context[start - 1])
    has_trailing = end < len(context) and _is_punctuation(context[end])
    if has_leading and has_trailing:
        punctuation = "paired"
    elif has_leading:
        punctuation = "leading"
    elif has_trailing:
        punctuation = "trailing"
    else:
        punctuation = "none"

    has_substantive_before = any(character.isalnum() for character in context[:start])
    has_substantive_after = any(character.isalnum() for character in context[end:])
    if not has_substantive_before and has_substantive_after:
        position = "initial"
    elif has_substantive_before and not has_substantive_after:
        position = "final"
    elif has_substantive_before and has_substantive_after:
        position = "medial"
    else:
        raise ValueError("candidate sentencePosition is ambiguous")
    return punctuation, position


def validate_candidates(raw_rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    case_ids: set[str] = set()
    governed_cases: set[tuple[str, str, str, str, str]] = set()
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
            "capitalization",
            "punctuation",
            "sentencePosition",
        ):
            if not _nonempty_string(row[field]):
                raise ValueError(f"candidate row {index} {field} must be nonempty")
        if row["category"] not in CATEGORIES:
            raise ValueError(
                "candidate category must be proper-noun, technical, morphology, "
                "loanword, or adversarial"
            )
        if row["capitalization"] not in CAPITALIZATION_VARIANTS:
            raise ValueError("candidate capitalization is invalid")
        if row["punctuation"] not in PUNCTUATION_VARIANTS:
            raise ValueError("candidate punctuation is invalid")
        if row["sentencePosition"] not in SENTENCE_POSITION_VARIANTS:
            raise ValueError("candidate sentencePosition is invalid")
        normalized_word = _normalized_evaluator_input(row["word"])
        if _capitalization_variant(row["word"]) != row["capitalization"]:
            raise ValueError("candidate capitalization does not match its word")
        punctuation, sentence_position = _context_variants(
            row["word"], row["context"]
        )
        if punctuation != row["punctuation"]:
            raise ValueError("candidate punctuation does not match its context")
        if sentence_position != row["sentencePosition"]:
            raise ValueError("candidate sentencePosition does not match its context")
        if row["labelStatus"] != "provisional":
            raise ValueError("candidate labelStatus must remain provisional")
        if row["provenance"] not in ALLOWED_PROVENANCE:
            raise ValueError(
                "candidate provenance must be public-domain, permissive, or synthetic"
            )
        _validate_provenance(row, f"candidate row {index}")

        if row["caseID"] in case_ids:
            raise ValueError(f"duplicate caseID {row['caseID']}")
        identity = (
            row["category"],
            normalized_word,
            row["capitalization"],
            row["punctuation"],
            row["sentencePosition"],
        )
        if identity in governed_cases:
            raise ValueError(
                "duplicate governed category/word/systematic-variant case "
                f"{row['category']}/{row['word']}"
            )
        case_ids.add(row["caseID"])
        governed_cases.add(identity)
        rows.append(row)
    return rows


def systematic_variant_counts(
    rows: Iterable[dict[str, Any]],
) -> dict[str, dict[str, int]]:
    counts = {
        axis: {variant: 0 for variant in variants}
        for axis, variants in SYSTEMATIC_VARIANTS.items()
    }
    for row in rows:
        for axis in SYSTEMATIC_VARIANTS:
            counts[axis][row[axis]] += 1
    return counts


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


def load_governed_qualification_resources(
    lock_path: Path | str,
    vocab_path: Path | str,
    gold_path: Path | str = DEFAULT_GOLD_PATH,
    silver_path: Path | str = DEFAULT_SILVER_PATH,
    pronunciation_pack_path: Path | str = DEFAULT_PRONUNCIATION_PACK_PATH,
) -> dict[str, Any]:
    model_identity, vocab = _load_qualification_resources(lock_path, vocab_path)
    gold_bytes = _read_stable_regular_bytes(gold_path, name="gold lexicon")
    silver_bytes = _read_stable_regular_bytes(silver_path, name="silver lexicon")
    pack_bytes = _read_stable_regular_bytes(
        pronunciation_pack_path, name="pronunciation pack"
    )
    gold = _decode_json_snapshot(gold_bytes, name="gold lexicon")
    silver = _decode_json_snapshot(silver_bytes, name="silver lexicon")
    pack = _decode_json_snapshot(pack_bytes, name="pronunciation pack")
    pack_entries = pack.get("entries") if isinstance(pack, dict) else None
    if (
        not isinstance(gold, dict)
        or not isinstance(silver, dict)
        or not isinstance(pack_entries, dict)
        or any(not isinstance(word, str) for word in gold)
        or any(not isinstance(word, str) for word in silver)
        or any(not isinstance(word, str) for word in pack_entries)
    ):
        raise ValueError("deterministic pronunciation resources are invalid")
    deterministic_words = {
        word.casefold() for source in (gold, silver, pack_entries) for word in source
    }
    return {
        "modelIdentity": model_identity,
        "vocab": vocab,
        "deterministicWords": deterministic_words,
        "deterministicLexiconIdentity": {
            "goldSHA256": hashlib.sha256(gold_bytes).hexdigest(),
            "silverSHA256": hashlib.sha256(silver_bytes).hexdigest(),
            "pronunciationPackSHA256": hashlib.sha256(pack_bytes).hexdigest(),
        },
    }


_ARPABET_VOWELS = {
    "AA": ("ɑ", "ɑ"),
    "AE": ("æ", "æ"),
    "AH": ("ə", "ʌ"),
    "AO": ("ɔ", "ɔ"),
    "AW": ("aʊ", "aʊ"),
    "AY": ("aɪ", "aɪ"),
    "EH": ("ɛ", "ɛ"),
    "ER": ("ɚ", "ɜɹ"),
    "EY": ("eɪ", "eɪ"),
    "IH": ("ɪ", "ɪ"),
    "IY": ("i", "i"),
    "OW": ("oʊ", "oʊ"),
    "OY": ("ɔɪ", "ɔɪ"),
    "UH": ("ʊ", "ʊ"),
    "UW": ("u", "u"),
}
_ARPABET_CONSONANTS = {
    "B": "b",
    "CH": "ʧ",
    "D": "d",
    "DH": "ð",
    "F": "f",
    "G": "ɡ",
    "HH": "h",
    "JH": "ʤ",
    "K": "k",
    "L": "l",
    "M": "m",
    "N": "n",
    "NG": "ŋ",
    "P": "p",
    "R": "ɹ",
    "S": "s",
    "SH": "ʃ",
    "T": "t",
    "TH": "θ",
    "V": "v",
    "W": "w",
    "Y": "j",
    "Z": "z",
    "ZH": "ʒ",
}
_ARPABET_STRESSES = {"0": "", "1": "ˈ", "2": "ˌ"}


def _convert_arpabet_output(raw_output: str, vocab: dict[str, int]) -> str:
    tokens = raw_output.split()
    if not tokens:
        raise ValueError("empty ARPAbet output")
    converted: list[str] = []
    for token in tokens:
        consonant = _ARPABET_CONSONANTS.get(token)
        if consonant is not None:
            converted.append(consonant)
            continue
        if token[-1:] in _ARPABET_STRESSES:
            base = token[:-1]
            vowel = _ARPABET_VOWELS.get(base)
            if vowel is None:
                raise ValueError("malformed ARPAbet stress")
            stress = token[-1]
            converted.append(_ARPABET_STRESSES[stress])
            converted.append(vowel[0] if stress == "0" else vowel[1])
            continue
        raise ValueError("unsupported ARPAbet token")
    ipa = "".join(converted)
    if any(character not in vocab for character in ipa):
        raise ValueError("ARPAbet conversion is not Kokoro compatible")
    return ipa


def machine_evidence_receipt_digest(receipt: dict[str, Any]) -> str:
    payload = dict(receipt)
    payload.pop("receiptSHA256", None)
    return _canonical_sha256(payload)


def build_machine_evidence_receipt(
    candidate: dict[str, Any],
    raw_model_outputs: list[str],
    resources: dict[str, Any],
    *,
    receipt_id: str,
) -> dict[str, Any]:
    if not _nonempty_string(receipt_id):
        raise ValueError("machine evidence receiptID must be nonempty")
    if (
        not isinstance(raw_model_outputs, list)
        or any(not isinstance(output, str) for output in raw_model_outputs)
    ):
        raise ValueError("machine evidence raw outputs are invalid")
    normalized_word = _normalized_evaluator_input(candidate["word"])
    converted_outputs: list[str | None] = []
    for raw_output in raw_model_outputs:
        try:
            converted_outputs.append(
                _convert_arpabet_output(raw_output, resources["vocab"])
            )
        except ValueError:
            converted_outputs.append(None)
    stable = (
        len(converted_outputs) >= 2
        and converted_outputs[0] is not None
        and all(output == converted_outputs[0] for output in converted_outputs[1:])
    )
    genuine_oov = normalized_word not in resources["deterministicWords"]
    automatic = stable and genuine_oov
    selected_ipa = converted_outputs[0] if automatic else None
    mapped_token_ids = (
        [resources["vocab"][character] for character in selected_ipa]
        if selected_ipa is not None
        else []
    )
    model_identity = resources["modelIdentity"]
    lexicon_identity = resources["deterministicLexiconIdentity"]
    receipt: dict[str, Any] = {
        "schemaVersion": MACHINE_EVIDENCE_SCHEMA_VERSION,
        "generatorID": MACHINE_EVIDENCE_GENERATOR,
        "receiptID": receipt_id,
        "caseID": candidate["caseID"],
        "evaluatorInputSHA256": hashlib.sha256(
            normalized_word.encode("utf-8")
        ).hexdigest(),
        "rawModelOutputs": raw_model_outputs,
        "convertedOutputs": converted_outputs,
        "mappedTokenIDs": mapped_token_ids,
        "genuineDeterministicOOV": genuine_oov,
        "stable": stable,
        "automaticSelectionEligible": automatic,
        "selectedIPA": selected_ipa,
        "modelRevision": model_identity["revision"],
        "modelLockSHA256": model_identity["lockSHA256"],
        "vocabSHA256": model_identity["vocabSHA256"],
        "goldLexiconSHA256": lexicon_identity["goldSHA256"],
        "silverLexiconSHA256": lexicon_identity["silverSHA256"],
        "pronunciationPackSHA256": lexicon_identity["pronunciationPackSHA256"],
        "conversionVersion": CONVERSION_VERSION,
        "validationVersion": VALIDATION_VERSION,
        "selectionVersion": SELECTION_VERSION,
    }
    receipt["receiptSHA256"] = machine_evidence_receipt_digest(receipt)
    return receipt


def validate_machine_evidence_receipts(
    raw_receipts: Iterable[dict[str, Any]],
    candidates: Iterable[dict[str, Any]],
    resources: dict[str, Any],
) -> list[dict[str, Any]]:
    candidates_by_id = {candidate["caseID"]: candidate for candidate in candidates}
    validated: list[dict[str, Any]] = []
    receipt_ids: set[str] = set()
    case_ids: set[str] = set()
    for index, raw_receipt in enumerate(raw_receipts, start=1):
        if not isinstance(raw_receipt, dict):
            raise ValueError(f"machine evidence receipt {index} must be an object")
        receipt = dict(raw_receipt)
        _validate_no_private_data(receipt, f"machine evidence receipt {index}")
        _validate_exact_fields(
            receipt,
            required=MACHINE_RECEIPT_FIELDS,
            allowed=MACHINE_RECEIPT_FIELDS,
            name=f"machine evidence receipt {index}",
        )
        candidate = candidates_by_id.get(receipt.get("caseID"))
        if candidate is None:
            raise ValueError("machine evidence references an unknown caseID")
        receipt_id = receipt.get("receiptID")
        if not isinstance(receipt_id, str) or not receipt_id:
            raise ValueError("machine evidence receiptID is invalid")
        if receipt_id in receipt_ids or receipt["caseID"] in case_ids:
            raise ValueError("machine evidence receipts must be unique per case")
        expected = build_machine_evidence_receipt(
            candidate,
            receipt.get("rawModelOutputs"),
            resources,
            receipt_id=receipt_id,
        )
        if receipt != expected:
            raise ValueError(
                f"machine evidence receipt {receipt_id} does not match locked evaluation"
            )
        receipt_ids.add(receipt_id)
        case_ids.add(receipt["caseID"])
        validated.append(receipt)
    return validated


def load_external_machine_evidence(
    path: Path | str | None,
    *,
    candidates: list[dict[str, Any]],
    resources: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    if path is None:
        return [], None
    content = _read_external_unique_regular_bytes(
        Path(path), name="machine evidence receipts"
    )
    receipts = validate_machine_evidence_receipts(
        _decode_external_jsonl(content, "machine evidence receipts"),
        candidates,
        resources,
    )
    return receipts, {
        "sourceFileSHA256": hashlib.sha256(content).hexdigest(),
        "receiptSetSHA256": _canonical_sha256(receipts),
        "receiptCount": len(receipts),
    }


RUNTIME_RECORD_FIELDS = {
    "schemaVersion",
    "evidenceKind",
    "deviceModel",
    "osBuild",
    "appCommitSHA",
    "modelRevision",
    "modelLockSHA256",
    "vocabSHA256",
    "performance",
    "device",
    "render",
    "listening",
    "receiptSHA256",
}
RUNTIME_PERFORMANCE_FIELDS = {
    "addedPeakRSSBytes",
    "coldPreflightMilliseconds",
    "sustainedPreflightMilliseconds",
    "kokoroRenderMilliseconds",
}
RUNTIME_DEVICE_FIELDS = {
    "oldestSupportedPhysicalIPhoneAttested",
    "cancellationPassed",
    "relaunchPassed",
    "foregroundPassed",
    "lockScreenPassed",
    "backgroundPassed",
}
RUNTIME_RENDER_FIELDS = {
    "primaryVoiceID",
    "controlVoiceID",
    "primaryVoiceProbeSHA256",
    "controlVoiceProbeSHA256",
}
RUNTIME_LISTENING_FIELDS = {
    "authorityReceiptSHA256",
    "primaryVoiceProbeSHA256",
    "controlVoiceProbeSHA256",
    "verdict",
}
LISTENING_AUTHORITY_FIELDS = {
    "schemaVersion",
    "authorityKind",
    "authorizationPurpose",
    "runtimeReceiptSHA256",
    "deviceModel",
    "osBuild",
    "appCommitSHA",
    "modelRevision",
    "modelLockSHA256",
    "vocabSHA256",
    "primaryVoiceID",
    "controlVoiceID",
    "primaryVoiceProbeSHA256",
    "controlVoiceProbeSHA256",
    "listeningVerdict",
    "listenerReferenceSHA256",
    "listenerIndependenceAttested",
    "receiptSHA256",
}


def runtime_evidence_receipt_digest(record: dict[str, Any]) -> str:
    payload = dict(record)
    payload.pop("receiptSHA256", None)
    listening = dict(payload.get("listening", {}))
    listening.pop("authorityReceiptSHA256", None)
    payload["listening"] = listening
    return _canonical_sha256(payload)


def runtime_evidence_measurement_digest(record: dict[str, Any]) -> str:
    return runtime_evidence_receipt_digest(record)


def listening_authority_receipt_digest(authority: dict[str, Any]) -> str:
    payload = dict(authority)
    payload.pop("receiptSHA256", None)
    return _canonical_sha256(payload)


def build_runtime_evidence_record(
    *,
    device_model: str,
    os_build: str,
    app_commit_sha: str,
    model_identity: dict[str, Any],
    added_peak_rss_bytes: int,
    cold_preflight_milliseconds: float,
    sustained_preflight_milliseconds: float,
    kokoro_render_milliseconds: float,
    oldest_supported_physical_iphone_attested: bool,
    cancellation_passed: bool,
    relaunch_passed: bool,
    foreground_passed: bool,
    lock_screen_passed: bool,
    background_passed: bool,
    primary_voice_id: str,
    control_voice_id: str,
    primary_voice_probe_sha256: str,
    control_voice_probe_sha256: str,
    listening_authority_sha256: str,
    listening_verdict: str,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "schemaVersion": RUNTIME_EVIDENCE_SCHEMA_VERSION,
        "evidenceKind": RUNTIME_EVIDENCE_KIND,
        "deviceModel": device_model,
        "osBuild": os_build,
        "appCommitSHA": app_commit_sha,
        "modelRevision": model_identity["revision"],
        "modelLockSHA256": model_identity["lockSHA256"],
        "vocabSHA256": model_identity["vocabSHA256"],
        "performance": {
            "addedPeakRSSBytes": added_peak_rss_bytes,
            "coldPreflightMilliseconds": cold_preflight_milliseconds,
            "sustainedPreflightMilliseconds": sustained_preflight_milliseconds,
            "kokoroRenderMilliseconds": kokoro_render_milliseconds,
        },
        "device": {
            "oldestSupportedPhysicalIPhoneAttested": (
                oldest_supported_physical_iphone_attested
            ),
            "cancellationPassed": cancellation_passed,
            "relaunchPassed": relaunch_passed,
            "foregroundPassed": foreground_passed,
            "lockScreenPassed": lock_screen_passed,
            "backgroundPassed": background_passed,
        },
        "render": {
            "primaryVoiceID": primary_voice_id,
            "controlVoiceID": control_voice_id,
            "primaryVoiceProbeSHA256": primary_voice_probe_sha256,
            "controlVoiceProbeSHA256": control_voice_probe_sha256,
        },
        "listening": {
            "authorityReceiptSHA256": listening_authority_sha256,
            "primaryVoiceProbeSHA256": primary_voice_probe_sha256,
            "controlVoiceProbeSHA256": control_voice_probe_sha256,
            "verdict": listening_verdict,
        },
    }
    record["receiptSHA256"] = runtime_evidence_receipt_digest(record)
    return record


def build_listening_evidence_authority(
    record: dict[str, Any], *, listener_reference_sha256: str
) -> dict[str, Any]:
    if (
        not isinstance(listener_reference_sha256, str)
        or SHA256_PATTERN.fullmatch(listener_reference_sha256) is None
    ):
        raise ValueError("listening authority listener reference is invalid")
    render = record["render"]
    authority: dict[str, Any] = {
        "schemaVersion": 1,
        "authorityKind": "user-controlled-out-of-repository",
        "authorizationPurpose": RUNTIME_LISTENING_AUTHORIZATION_PURPOSE,
        "runtimeReceiptSHA256": record["receiptSHA256"],
        "deviceModel": record["deviceModel"],
        "osBuild": record["osBuild"],
        "appCommitSHA": record["appCommitSHA"],
        "modelRevision": record["modelRevision"],
        "modelLockSHA256": record["modelLockSHA256"],
        "vocabSHA256": record["vocabSHA256"],
        "primaryVoiceID": render["primaryVoiceID"],
        "controlVoiceID": render["controlVoiceID"],
        "primaryVoiceProbeSHA256": render["primaryVoiceProbeSHA256"],
        "controlVoiceProbeSHA256": render["controlVoiceProbeSHA256"],
        "listeningVerdict": record["listening"]["verdict"],
        "listenerReferenceSHA256": listener_reference_sha256,
        "listenerIndependenceAttested": True,
    }
    authority["receiptSHA256"] = listening_authority_receipt_digest(authority)
    return authority


def _validate_runtime_record_shape(
    record: Any, model_identity: dict[str, Any]
) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise ValueError("runtime evidence record must be an object")
    _validate_no_private_data(record, "runtime evidence record")
    _validate_exact_fields(
        record,
        required=RUNTIME_RECORD_FIELDS,
        allowed=RUNTIME_RECORD_FIELDS,
        name="runtime evidence record",
    )
    if (
        record["schemaVersion"] != RUNTIME_EVIDENCE_SCHEMA_VERSION
        or record["evidenceKind"] != RUNTIME_EVIDENCE_KIND
        or not _nonempty_string(record["deviceModel"])
        or not _nonempty_string(record["osBuild"])
        or not isinstance(record["appCommitSHA"], str)
        or GIT_SHA_PATTERN.fullmatch(record["appCommitSHA"]) is None
    ):
        raise ValueError("runtime evidence identity is invalid")
    for field, expected in (
        ("modelRevision", model_identity["revision"]),
        ("modelLockSHA256", model_identity["lockSHA256"]),
        ("vocabSHA256", model_identity["vocabSHA256"]),
    ):
        if record[field] != expected:
            raise ValueError("runtime evidence model identity is invalid")
    for field, expected_fields in (
        ("performance", RUNTIME_PERFORMANCE_FIELDS),
        ("device", RUNTIME_DEVICE_FIELDS),
        ("render", RUNTIME_RENDER_FIELDS),
        ("listening", RUNTIME_LISTENING_FIELDS),
    ):
        value = record[field]
        if not isinstance(value, dict) or set(value) != expected_fields:
            raise ValueError(f"runtime evidence {field} record is invalid")
    if (
        not isinstance(record["receiptSHA256"], str)
        or record["receiptSHA256"] != runtime_evidence_receipt_digest(record)
    ):
        raise ValueError("runtime evidence receipt digest is invalid")
    return dict(record)


def _validate_listening_authority(
    raw_authority: Any,
    record: dict[str, Any],
) -> dict[str, Any]:
    if (
        not isinstance(raw_authority, dict)
        or set(raw_authority) != LISTENING_AUTHORITY_FIELDS
    ):
        raise ValueError("listening evidence authority schema is invalid")
    authority = dict(raw_authority)
    _validate_no_private_data(authority, "listening evidence authority")
    if (
        authority["schemaVersion"] != 1
        or authority["authorityKind"] != "user-controlled-out-of-repository"
        or authority["authorizationPurpose"]
        != RUNTIME_LISTENING_AUTHORIZATION_PURPOSE
        or authority["listenerIndependenceAttested"] is not True
        or not isinstance(authority["listenerReferenceSHA256"], str)
        or SHA256_PATTERN.fullmatch(authority["listenerReferenceSHA256"])
        is None
        or not isinstance(authority["receiptSHA256"], str)
        or authority["receiptSHA256"]
        != listening_authority_receipt_digest(authority)
    ):
        raise ValueError("listening evidence authority receipt is invalid")
    render = record["render"]
    expected_binding = {
        "runtimeReceiptSHA256": record["receiptSHA256"],
        "deviceModel": record["deviceModel"],
        "osBuild": record["osBuild"],
        "appCommitSHA": record["appCommitSHA"],
        "modelRevision": record["modelRevision"],
        "modelLockSHA256": record["modelLockSHA256"],
        "vocabSHA256": record["vocabSHA256"],
        "primaryVoiceID": render["primaryVoiceID"],
        "controlVoiceID": render["controlVoiceID"],
        "primaryVoiceProbeSHA256": render["primaryVoiceProbeSHA256"],
        "controlVoiceProbeSHA256": render["controlVoiceProbeSHA256"],
        "listeningVerdict": record["listening"]["verdict"],
    }
    if any(authority[field] != value for field, value in expected_binding.items()):
        raise ValueError("listening evidence authority does not bind runtime evidence")
    if record["listening"]["authorityReceiptSHA256"] != authority["receiptSHA256"]:
        raise ValueError("runtime evidence does not bind listening authority receipt")
    if authority["listeningVerdict"] not in {"passed", "failed"}:
        raise ValueError("listening evidence authority verdict is invalid")
    return authority


def derive_runtime_proof_states(
    raw_record: Any,
    raw_authority: Any,
    model_identity: dict[str, Any],
) -> tuple[dict[str, str], dict[str, Any] | None]:
    if raw_record is None and raw_authority is None:
        return (
            {
                "performance": "NOT_PROVIDED",
                "device": "NOT_PROVIDED",
                "render": "NOT_PROVIDED",
                "listening": "NOT_PROVIDED",
            },
            None,
        )
    if raw_record is None or raw_authority is None:
        raise ValueError(
            "runtime evidence and listening evidence authority must be supplied together"
        )
    record = _validate_runtime_record_shape(raw_record, model_identity)
    authority = _validate_listening_authority(raw_authority, record)
    performance = record["performance"]
    numeric_fields = (
        "coldPreflightMilliseconds",
        "sustainedPreflightMilliseconds",
        "kokoroRenderMilliseconds",
    )
    numeric_valid = all(
        isinstance(performance[field], (int, float))
        and not isinstance(performance[field], bool)
        and math.isfinite(performance[field])
        and performance[field] >= 0
        for field in numeric_fields
    )
    rss = performance["addedPeakRSSBytes"]
    rss_valid = isinstance(rss, int) and not isinstance(rss, bool) and rss >= 0
    performance_passed = (
        numeric_valid
        and rss_valid
        and rss <= 64 * 1024 * 1024
        and performance["coldPreflightMilliseconds"] <= 2000
        and performance["kokoroRenderMilliseconds"] > 0
        and performance["sustainedPreflightMilliseconds"]
        <= performance["kokoroRenderMilliseconds"] * 0.05
    )
    device = record["device"]
    device_valid = all(isinstance(device[field], bool) for field in device)
    device_passed = (
        device_valid
        and all(device.values())
        and re.fullmatch(r"iPhone[0-9]+,[0-9]+", record["deviceModel"]) is not None
    )
    render = record["render"]
    render_passed = (
        _nonempty_string(render["primaryVoiceID"])
        and _nonempty_string(render["controlVoiceID"])
        and render["primaryVoiceID"] != render["controlVoiceID"]
        and all(
            isinstance(render[field], str)
            and SHA256_PATTERN.fullmatch(render[field]) is not None
            for field in ("primaryVoiceProbeSHA256", "controlVoiceProbeSHA256")
        )
        and render["primaryVoiceProbeSHA256"]
        != render["controlVoiceProbeSHA256"]
    )
    listening = record["listening"]
    listening_passed = (
        render_passed
        and listening["primaryVoiceProbeSHA256"]
        == render["primaryVoiceProbeSHA256"]
        and listening["controlVoiceProbeSHA256"]
        == render["controlVoiceProbeSHA256"]
        and listening["verdict"] == "passed"
        and authority["listeningVerdict"] == "passed"
    )
    states = {
        "performance": "VERIFIED" if performance_passed else "FAILED",
        "device": "VERIFIED" if device_passed else "FAILED",
        "render": "VERIFIED" if render_passed else "FAILED",
        "listening": "VERIFIED" if listening_passed else "FAILED",
    }
    identity = {
        "receiptSHA256": record["receiptSHA256"],
        "runtimeReceiptSHA256": record["receiptSHA256"],
        "deviceModel": record["deviceModel"],
        "osBuild": record["osBuild"],
        "appCommitSHA": record["appCommitSHA"],
        "primaryVoiceID": render["primaryVoiceID"],
        "controlVoiceID": render["controlVoiceID"],
        "primaryVoiceProbeSHA256": render["primaryVoiceProbeSHA256"],
        "controlVoiceProbeSHA256": render["controlVoiceProbeSHA256"],
        "listeningAuthorityReceiptSHA256": listening["authorityReceiptSHA256"],
        "listenerReferenceSHA256": authority["listenerReferenceSHA256"],
    }
    return states, identity


def load_external_runtime_evidence(
    runtime_evidence: Path | str | None,
    listening_evidence_authority: Path | str | None,
    *,
    model_identity: dict[str, Any],
) -> tuple[dict[str, str], dict[str, Any] | None]:
    if runtime_evidence is None and listening_evidence_authority is None:
        return derive_runtime_proof_states(None, None, model_identity)
    if runtime_evidence is None or listening_evidence_authority is None:
        raise ValueError(
            "runtime evidence and listening evidence authority must be supplied together"
        )
    try:
        if Path(runtime_evidence).resolve(strict=True) == Path(
            listening_evidence_authority
        ).resolve(strict=True):
            raise ValueError("runtime evidence and listening authority must be distinct files")
    except OSError as error:
        raise ValueError("runtime/listening evidence is unavailable") from error
    runtime_bytes = _read_external_unique_regular_bytes(
        Path(runtime_evidence), name="runtime evidence"
    )
    authority_bytes = _read_external_unique_regular_bytes(
        Path(listening_evidence_authority), name="listening evidence authority"
    )
    try:
        record = _strict_json_loads(runtime_bytes.decode("utf-8"), "runtime evidence")
        authority = _strict_json_loads(
            authority_bytes.decode("utf-8"), "listening evidence authority"
        )
    except UnicodeDecodeError as error:
        raise ValueError("runtime/listening evidence is not valid UTF-8") from error
    states, identity = derive_runtime_proof_states(record, authority, model_identity)
    assert identity is not None
    identity.update(
        {
            "sourceFileSHA256": hashlib.sha256(runtime_bytes).hexdigest(),
            "listeningAuthorityFileSHA256": hashlib.sha256(
                authority_bytes
            ).hexdigest(),
        }
    )
    return states, identity


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


def qualification_decision(proof_states: dict[str, str]) -> str:
    states = validate_proof_states(proof_states)
    runtime_lanes = ("performance", "device", "render", "listening")
    if any(states[lane] == "FAILED" for lane in runtime_lanes):
        return "FAILED"
    human_state = states["human"]
    if human_state != "QUALIFIED":
        return human_state
    return (
        "QUALIFIED"
        if all(states[lane] == "VERIFIED" for lane in runtime_lanes)
        else "FAILED"
    )


def qualification_status(
    raw_candidates: Iterable[dict[str, Any]],
    raw_receipts: Iterable[dict[str, Any]],
    trusted_authority: dict[str, Any] | None,
    lock_path: Path | str,
    vocab_path: Path | str,
    *,
    gold_path: Path | str = DEFAULT_GOLD_PATH,
    silver_path: Path | str = DEFAULT_SILVER_PATH,
    pronunciation_pack_path: Path | str = DEFAULT_PRONUNCIATION_PACK_PATH,
    machine_evidence_path: Path | str | None = None,
    runtime_evidence_path: Path | str | None = None,
    listening_evidence_authority_path: Path | str | None = None,
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

    resources = load_governed_qualification_resources(
        lock_path,
        vocab_path,
        gold_path,
        silver_path,
        pronunciation_pack_path,
    )
    model_identity = resources["modelIdentity"]
    machine_receipts, machine_evidence_identity = load_external_machine_evidence(
        machine_evidence_path,
        candidates=candidates,
        resources=resources,
    )
    runtime_states, runtime_evidence_identity = load_external_runtime_evidence(
        runtime_evidence_path,
        listening_evidence_authority_path,
        model_identity=model_identity,
    )
    candidates_by_id = {row["caseID"]: row for row in candidates}
    machine_by_case_id = {row["caseID"]: row for row in machine_receipts}
    reviewed_categories: Counter[str] = Counter()
    recomputed_eligible_categories: Counter[str] = Counter()
    qualifying_categories: Counter[str] = Counter()
    invalid_counts = {
        "missingMachineEvidence": 0,
        "emptyOrUnmappable": 0,
        "unstable": 0,
        "notDeterministicOOV": 0,
    }
    reviewed_variants = systematic_variant_counts([])
    recomputed_eligible_variants = systematic_variant_counts([])
    correct_recomputed_variants = systematic_variant_counts([])
    variant_failures = {
        axis: {
            variant: {
                "missingMachineEvidence": 0,
                "machineIneligible": 0,
                "incorrect": 0,
            }
            for variant in variants
        }
        for axis, variants in SYSTEMATIC_VARIANTS.items()
    }
    automatic_count = 0
    correct_count = 0
    recomputed_eligible_count = 0
    correct_recomputed_eligible_count = 0

    for receipt in receipts:
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
        for axis in SYSTEMATIC_VARIANTS:
            reviewed_variants[axis][candidate_row[axis]] += 1

        machine_receipt = machine_by_case_id.get(receipt["caseID"])
        if machine_receipt is None:
            invalid_counts["missingMachineEvidence"] += 1
            for axis in SYSTEMATIC_VARIANTS:
                variant_failures[axis][candidate_row[axis]][
                    "missingMachineEvidence"
                ] += 1
            continue
        if not machine_receipt["genuineDeterministicOOV"]:
            invalid_counts["notDeterministicOOV"] += 1
        elif any(output is None for output in machine_receipt["convertedOutputs"]):
            invalid_counts["emptyOrUnmappable"] += 1
        elif not machine_receipt["stable"]:
            invalid_counts["unstable"] += 1
        elif not machine_receipt["automaticSelectionEligible"]:
            invalid_counts["emptyOrUnmappable"] += 1
        if not machine_receipt["automaticSelectionEligible"]:
            for axis in SYSTEMATIC_VARIANTS:
                variant_failures[axis][candidate_row[axis]]["machineIneligible"] += 1
            continue
        recomputed_eligible_count += 1
        recomputed_eligible_categories[receipt["category"]] += 1
        for axis in SYSTEMATIC_VARIANTS:
            recomputed_eligible_variants[axis][candidate_row[axis]] += 1
        if machine_receipt["selectedIPA"] == _gold_label(receipt):
            correct_recomputed_eligible_count += 1
            for axis in SYSTEMATIC_VARIANTS:
                correct_recomputed_variants[axis][candidate_row[axis]] += 1
        else:
            for axis in SYSTEMATIC_VARIANTS:
                variant_failures[axis][candidate_row[axis]]["incorrect"] += 1

    reviewed_count = len(receipts)
    precision = correct_count / automatic_count if automatic_count else None
    wilson = (
        wilson_lower_bound(correct_count, automatic_count)
        if automatic_count
        else None
    )
    recomputed_precision = (
        correct_recomputed_eligible_count / recomputed_eligible_count
        if recomputed_eligible_count
        else None
    )
    recomputed_wilson = (
        wilson_lower_bound(
            correct_recomputed_eligible_count,
            recomputed_eligible_count,
        )
        if recomputed_eligible_count
        else None
    )
    evidence_ready = (
        reviewed_count >= MINIMUM_REVIEWED_CASES
        and all(
            reviewed_categories[category] >= MINIMUM_CASES_PER_CATEGORY
            for category in CATEGORIES
        )
        and all(
            reviewed_variants[axis][variant]
            >= MINIMUM_CASES_PER_SYSTEMATIC_VARIANT
            for axis, variants in SYSTEMATIC_VARIANTS.items()
            for variant in variants
        )
    )
    all_invalid_zero = all(value == 0 for value in invalid_counts.values())
    # A self-declared generator ID cannot prove that raw ARPAbet bytes came from
    # the locked Swift evaluator. Until a governed producer/attestation is wired,
    # machine receipts remain diagnostic and automatic qualification is closed.
    governed_machine_producer_state = "UNAVAILABLE_FAIL_CLOSED"
    systematic_results: dict[str, dict[str, Any]] = {}
    all_systematic_derived_gates_pass = True
    for axis, variants in SYSTEMATIC_VARIANTS.items():
        systematic_results[axis] = {}
        for variant in variants:
            reviewed = reviewed_variants[axis][variant]
            eligible = recomputed_eligible_variants[axis][variant]
            correct = correct_recomputed_variants[axis][variant]
            failures = variant_failures[axis][variant]
            review_coverage_passed = (
                reviewed >= MINIMUM_CASES_PER_SYSTEMATIC_VARIANT
            )
            derived_gate_passed = (
                review_coverage_passed
                and eligible >= MINIMUM_CASES_PER_SYSTEMATIC_VARIANT
                and correct == eligible
                and all(value == 0 for value in failures.values())
            )
            all_systematic_derived_gates_pass = (
                all_systematic_derived_gates_pass and derived_gate_passed
            )
            systematic_results[axis][variant] = {
                "reviewedCount": reviewed,
                "recomputedEligibleCount": eligible,
                "correctRecomputedEligibleCount": correct,
                "recomputedPrecision": correct / eligible if eligible else None,
                "failures": failures,
                "reviewCoverageGatePassed": review_coverage_passed,
                "derivedEvidenceGatePassed": derived_gate_passed,
                "qualificationGatePassed": (
                    governed_machine_producer_state == "VERIFIED"
                    and derived_gate_passed
                ),
            }

    gates_pass = (
        governed_machine_producer_state == "VERIFIED"
        and automatic_count >= MINIMUM_AUTOMATIC_CASES
        and all(
            qualifying_categories[category] >= MINIMUM_CASES_PER_CATEGORY
            for category in CATEGORIES
        )
        and precision is not None
        and precision >= MINIMUM_PRECISION
        and wilson is not None
        and wilson >= MINIMUM_WILSON_95_LOWER_BOUND
        and all_invalid_zero
        and all_systematic_derived_gates_pass
    )
    if not evidence_ready:
        human_status = "WAITING_FOR_HUMAN_LABELS"
    elif gates_pass:
        human_status = "QUALIFIED"
    else:
        human_status = "FAILED"

    proof_states = validate_proof_states(
        {
            "corpus": "CONTRACT_VALID",
            "human": human_status,
            **runtime_states,
        }
    )
    status = qualification_decision(proof_states)

    return {
        "schemaVersion": QUALIFICATION_RECEIPT_SCHEMA_VERSION,
        "status": status,
        "proofStates": proof_states,
        "corpusSHA256": _canonical_sha256(candidates),
        "categoryCounts": {
            category: qualifying_categories[category] for category in CATEGORIES
        },
        "recomputedEligibleCategoryCounts": {
            category: recomputed_eligible_categories[category]
            for category in CATEGORIES
        },
        "systematicVariantCounts": systematic_variant_counts(candidates),
        "systematicVariantResults": systematic_results,
        "reviewedCount": reviewed_count,
        "automaticCount": automatic_count,
        "correctAutomaticCount": correct_count,
        "recomputedEligibleCount": recomputed_eligible_count,
        "correctRecomputedEligibleCount": correct_recomputed_eligible_count,
        "precision": precision,
        "wilson95LowerBound": wilson,
        "recomputedPrecision": recomputed_precision,
        "recomputedWilson95LowerBound": recomputed_wilson,
        "invalidCounts": invalid_counts,
        "modelIdentity": model_identity,
        "deterministicLexiconIdentity": resources[
            "deterministicLexiconIdentity"
        ],
        "machineEvidenceIdentity": machine_evidence_identity,
        "governedMachineProducerState": governed_machine_producer_state,
        "runtimeEvidenceIdentity": runtime_evidence_identity,
        "humanEvidenceAuthoritySHA256": (
            trusted_authority["evidenceBundleSHA256"]
            if trusted_authority is not None
            else None
        ),
        "conversionVersion": CONVERSION_VERSION,
        "validationVersion": VALIDATION_VERSION,
        "selectionVersion": SELECTION_VERSION,
        "thresholds": {
            "minimumReviewedCases": MINIMUM_REVIEWED_CASES,
            "minimumCasesPerCategory": MINIMUM_CASES_PER_CATEGORY,
            "minimumCasesPerSystematicVariant": (
                MINIMUM_CASES_PER_SYSTEMATIC_VARIANT
            ),
            "minimumAutomaticCases": MINIMUM_AUTOMATIC_CASES,
            "minimumPrecision": MINIMUM_PRECISION,
            "minimumWilson95LowerBound": MINIMUM_WILSON_95_LOWER_BOUND,
            "requireZeroInvalidOutputs": True,
            "requireStableRepetition": True,
            "requireGovernedLockedEvaluatorProducer": True,
            "requireExternalRuntimeAndListeningAuthority": True,
        },
    }


def validate_qualification_receipt(receipt: Any) -> dict[str, str]:
    if (
        not isinstance(receipt, dict)
        or not isinstance(receipt.get("schemaVersion"), int)
        or isinstance(receipt.get("schemaVersion"), bool)
        or receipt["schemaVersion"] != QUALIFICATION_RECEIPT_SCHEMA_VERSION
    ):
        raise ValueError("qualification receipt schema version is invalid")
    proof_states = validate_proof_states(receipt.get("proofStates"))
    if receipt.get("status") != qualification_decision(proof_states):
        raise ValueError("proof states do not match qualification status")
    return proof_states


def render_report(receipt: dict[str, Any]) -> str:
    proof_states = validate_qualification_receipt(receipt)
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
- Governed machine producer: `{receipt['governedMachineProducerState']}`
- Recomputed eligible observations (diagnostic only): {receipt['recomputedEligibleCount']}

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
- Listening proof: `{proof_states['listening']}`

These states are not inferred from corpus validation or human-label qualification.
Runtime and listening states are derived only from a bound external runtime
receipt and a distinct user-controlled listening authority receipt.
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
        command_parser.add_argument("--machine-evidence", type=Path)
        command_parser.add_argument("--runtime-evidence", type=Path)
        command_parser.add_argument(
            "--listening-evidence-authority", type=Path
        )
        if command == "report":
            command_parser.add_argument("--output", type=Path, required=True)
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
            machine_evidence_path=arguments.machine_evidence,
            runtime_evidence_path=arguments.runtime_evidence,
            listening_evidence_authority_path=(
                arguments.listening_evidence_authority
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
