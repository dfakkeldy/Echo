#!/usr/bin/env python3
"""Build Echo's pinned, advisory-only pronunciation disagreement pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import unicodedata
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

try:
    from .build_pronunciation_pack import (
        CMUDICT_COMMIT,
        CMUDICT_DICTIONARY_PATH,
        CMUDICT_LICENSE_PATH,
        CMUDICT_LICENSE_SHA256,
        CMUDICT_SHA256,
        DIALECT,
        SHA256_PATTERN,
        _convert_arpabet,
        _load_json,
        _load_json_bytes,
        _normalize_word,
        _normalized_sha256,
        _normalized_vocab,
        _valid_timestamp,
        _verify_bytes,
        canonical_json_bytes,
        current_generation_timestamp,
        semantic_pack_version,
        sha256_identity,
    )
except ImportError:  # Direct script execution from the repository root.
    from build_pronunciation_pack import (
    CMUDICT_COMMIT,
    CMUDICT_DICTIONARY_PATH,
    CMUDICT_LICENSE_PATH,
    CMUDICT_LICENSE_SHA256,
    CMUDICT_SHA256,
    DIALECT,
    SHA256_PATTERN,
    _convert_arpabet,
    _load_json,
    _load_json_bytes,
    _normalize_word,
    _normalized_sha256,
    _normalized_vocab,
    _valid_timestamp,
    _verify_bytes,
    canonical_json_bytes,
    current_generation_timestamp,
    semantic_pack_version,
    sha256_identity,
)


AUDIT_GENERATOR_BEHAVIOR = {
    "generatorVersion": "echo-pronunciation-audit-pack-generator-v1",
    "normalizationPolicyVersion": "english-key-normalization-v1",
    "arpabetMappingVersion": "cmudict-arpabet-to-kokoro-v2",
    "sourceComparisonPolicyVersion": "gold-silver-cmudict-disagreement-v1",
    "automaticSelectionPolicyVersion": "advisory-only-shadow-v1",
    "candidateValidationPolicyVersion": "strict-kokoro-vocabulary-v1",
}

DEFAULT_LICENSES = [
    {
        "sourceID": "cmudict",
        "licenseID": "CMUdict-BSD-style",
        "licensePath": "ThirdParty/CMUdict/LICENSE",
    },
    {
        "sourceID": "echo-us-gold",
        "licenseID": "MisakiSwift-Apache-2.0",
        "licensePath": "ThirdParty/MisakiSwift/LICENSE",
    },
    {
        "sourceID": "echo-us-silver",
        "licenseID": "MisakiSwift-Apache-2.0",
        "licensePath": "ThirdParty/MisakiSwift/LICENSE",
    },
]
DEFAULT_ACKNOWLEDGMENTS = [
    "CMUdict notice bundled from THIRD_PARTY_NOTICES.md",
    "MisakiSwift Apache-2.0 notice bundled from THIRD_PARTY_NOTICES.md",
]


def _default_sources(
    *,
    cmu_lines: Sequence[str],
    gold: Mapping[str, Any],
    silver: Mapping[str, Any],
    commit: str,
    cmudict_sha256: str | None,
    gold_sha256: str | None,
    silver_sha256: str | None,
) -> list[dict[str, str]]:
    return [
        {
            "sourceID": "cmudict",
            "snapshotID": f"cmudict@{commit}",
            "role": "comparison-candidates",
            "sha256": _normalized_sha256(
                cmudict_sha256, canonical_json_bytes(sorted(cmu_lines))),
        },
        {
            "sourceID": "echo-us-gold",
            "snapshotID": "echo-us-gold",
            "role": "comparison-candidates",
            "sha256": _normalized_sha256(gold_sha256, canonical_json_bytes(gold)),
        },
        {
            "sourceID": "echo-us-silver",
            "snapshotID": "echo-us-silver",
            "role": "comparison-candidates",
            "sha256": _normalized_sha256(silver_sha256, canonical_json_bytes(silver)),
        },
    ]


def _validate_sources(sources: Iterable[Mapping[str, Any]]) -> list[dict[str, str]]:
    normalized: list[dict[str, str]] = []
    for source in sources:
        if set(source) != {"sourceID", "snapshotID", "role", "sha256"}:
            raise ValueError("sources must contain exact snapshot fields")
        record = {key: source[key] for key in source}
        if not all(isinstance(value, str) and value for value in record.values()):
            raise ValueError("source snapshot fields must be nonempty strings")
        if not SHA256_PATTERN.fullmatch(record["sha256"]):
            raise ValueError("source snapshot SHA-256 is invalid")
        normalized.append(record)
    normalized.sort(key=lambda item: item["sourceID"])
    if [item["sourceID"] for item in normalized] != [
        "cmudict", "echo-us-gold", "echo-us-silver",
    ]:
        raise ValueError("sources must contain cmudict, echo-us-gold, and echo-us-silver")
    return normalized


def _validate_licenses(licenses: Sequence[Mapping[str, Any]]) -> list[dict[str, str]]:
    normalized = [dict(item) for item in licenses]
    required = {(item["sourceID"], item["licenseID"], item["licensePath"]) for item in DEFAULT_LICENSES}
    actual = {
        (item.get("sourceID"), item.get("licenseID"), item.get("licensePath"))
        for item in normalized
        if set(item) == {"sourceID", "licenseID", "licensePath"}
    }
    if actual != required or len(normalized) != len(DEFAULT_LICENSES):
        raise ValueError("licenses do not match the required audit source notices")
    return sorted(normalized, key=lambda item: item["sourceID"])


def _ipa_values(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for nested in value.values():
            yield from _ipa_values(nested)
    elif value is None:
        # Gold uses explicit null sense overrides to fall back to its default.
        return
    else:
        raise ValueError("gold and silver pronunciation values must be strings or objects")


def _normalized_source_ipas(
    source: Mapping[str, Any], vocabulary: set[str]
) -> tuple[dict[str, set[str]], int]:
    values: dict[str, set[str]] = {}
    incompatible = 0
    for raw_word, raw_value in source.items():
        if not isinstance(raw_word, str):
            raise ValueError("gold and silver keys must be strings")
        word = _normalize_word(raw_word)
        if word is None:
            continue
        for raw_ipa in _ipa_values(raw_value):
            ipa = unicodedata.normalize("NFC", raw_ipa)
            if not ipa or any(character not in vocabulary for character in ipa):
                incompatible += 1
                continue
            values.setdefault(word, set()).add(ipa)
    return values, incompatible


def _cmudict_ipas(
    lines: Iterable[str], vocabulary: set[str]
) -> tuple[dict[str, set[str]], int]:
    values: dict[str, set[str]] = {}
    incompatible = 0
    for line in lines:
        stripped = line.partition("#")[0].strip()
        if not stripped or stripped.startswith(";;;"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            continue
        word = _normalize_word(fields[0])
        if word is None:
            continue
        try:
            ipa = _convert_arpabet(fields[1:])
        except ValueError:
            incompatible += 1
            continue
        if any(character not in vocabulary for character in ipa):
            incompatible += 1
            continue
        values.setdefault(word, set()).add(ipa)
    return values, incompatible


def build_audit_pack(
    *,
    cmu_lines: Iterable[str],
    gold: Mapping[str, Any],
    silver: Mapping[str, Any],
    kokoro_vocab: Mapping[str, Any],
    generation_timestamp: str | None = None,
    commit: str = CMUDICT_COMMIT,
    cmudict_sha256: str | None = None,
    gold_sha256: str | None = None,
    silver_sha256: str | None = None,
    sources: Iterable[Mapping[str, Any]] | None = None,
    licenses: Sequence[Mapping[str, Any]] = DEFAULT_LICENSES,
    required_acknowledgments: Sequence[str] = DEFAULT_ACKNOWLEDGMENTS,
) -> dict[str, Any]:
    if not isinstance(gold, Mapping) or not isinstance(silver, Mapping):
        raise ValueError("gold and silver comparison inputs must be JSON objects")
    if not isinstance(commit, str) or not commit:
        raise ValueError("CMUdict commit must be nonempty")
    if list(required_acknowledgments) != DEFAULT_ACKNOWLEDGMENTS:
        raise ValueError("required acknowledgments do not match audit source notices")

    lines = [line.rstrip("\r\n") for line in cmu_lines]
    vocabulary = set(_normalized_vocab(kokoro_vocab))
    source_records = _validate_sources(
        sources if sources is not None else _default_sources(
            cmu_lines=lines,
            gold=gold,
            silver=silver,
            commit=commit,
            cmudict_sha256=cmudict_sha256,
            gold_sha256=gold_sha256,
            silver_sha256=silver_sha256,
        )
    )
    license_records = _validate_licenses(licenses)
    cmu, cmu_incompatible = _cmudict_ipas(lines, vocabulary)
    gold_values, gold_incompatible = _normalized_source_ipas(gold, vocabulary)
    silver_values, silver_incompatible = _normalized_source_ipas(silver, vocabulary)

    entries: dict[str, dict[str, Any]] = {}
    overlap_count = 0
    disagreement_count = 0
    for word in sorted(cmu):
        source_values = {
            "cmudict": cmu[word],
            "echo-us-gold": gold_values.get(word, set()),
            "echo-us-silver": silver_values.get(word, set()),
        }
        comparison_values = [value for source_id, value in source_values.items() if source_id != "cmudict" and value]
        if not comparison_values:
            continue
        overlap_count += 1
        if all(value == cmu[word] for value in comparison_values):
            continue
        disagreement_count += 1
        candidates = []
        for source_id in sorted(source_values):
            for ipa in sorted(source_values[source_id]):
                digest = hashlib.sha256(
                    f"{source_id}\0{word}\0{ipa}".encode("utf-8")).hexdigest()[:12]
                candidates.append({
                    "candidateID": f"{source_id}.{word}.{digest}",
                    "ipa": ipa,
                    "sourceID": source_id,
                    "authority": "uncertain",
                    "validation": "shadow",
                    "automaticEligible": False,
                })
        entries[word] = {"normalizedWord": word, "candidates": candidates}

    normalized_data_sha256 = sha256_identity(canonical_json_bytes(entries))
    vocabulary_version = sha256_identity(canonical_json_bytes(_normalized_vocab(kokoro_vocab)))
    semantic_identity_payload = {
        "identitySchemaVersion": 1,
        "normalizedDataSHA256": normalized_data_sha256,
        "sourceSnapshots": [
            {key: source[key] for key in ("sourceID", "snapshotID", "sha256")}
            for source in source_records
        ],
        "generatorBehavior": AUDIT_GENERATOR_BEHAVIOR,
        "kokoroVocabularyVersion": vocabulary_version,
        "dialect": DIALECT,
    }
    version = semantic_pack_version(semantic_identity_payload)
    timestamp = generation_timestamp or current_generation_timestamp()
    if not _valid_timestamp(timestamp):
        raise ValueError("generation timestamp must be whole-second RFC 3339 UTC")

    candidate_count = sum(len(entry["candidates"]) for entry in entries.values())
    return {
        "schemaVersion": 1,
        "auditPackVersion": version,
        "generatorVersion": AUDIT_GENERATOR_BEHAVIOR["generatorVersion"],
        "entryCount": len(entries),
        "candidateCount": candidate_count,
        "normalizedDataSHA256": normalized_data_sha256,
        "kokoroVocabularyVersion": vocabulary_version,
        "dialect": DIALECT,
        "sources": source_records,
        "licenses": license_records,
        "requiredAcknowledgments": list(required_acknowledgments),
        "generationTimestamp": timestamp,
        "semanticIdentityPayload": semantic_identity_payload,
        "entries": entries,
        "report": {
            "overlaps": overlap_count,
            "disagreements": disagreement_count,
            "incompatible": cmu_incompatible + gold_incompatible + silver_incompatible,
        },
    }


def _expected_lock() -> dict[str, Any]:
    return {
        "sourceID": "cmudict",
        "upstreamURL": "https://github.com/cmusphinx/cmudict",
        "commit": CMUDICT_COMMIT,
        "dialect": DIALECT,
        "dictionary": {"path": CMUDICT_DICTIONARY_PATH, "sha256": CMUDICT_SHA256},
        "license": {"path": CMUDICT_LICENSE_PATH, "sha256": CMUDICT_LICENSE_SHA256},
    }


def _load_inputs(
    *, lock_path: Path, gold_path: Path, silver_path: Path, vocab_path: Path
) -> dict[str, Any]:
    lock = _load_json(lock_path)
    if lock != _expected_lock():
        raise ValueError("lock does not match the frozen CMUdict source")
    cmudict_path = Path(CMUDICT_DICTIONARY_PATH)
    license_path = Path(CMUDICT_LICENSE_PATH)
    cmudict_bytes = cmudict_path.read_bytes()
    _verify_bytes(cmudict_path, cmudict_bytes, CMUDICT_SHA256)
    _verify_bytes(license_path, license_path.read_bytes(), CMUDICT_LICENSE_SHA256)
    gold_bytes = gold_path.read_bytes()
    silver_bytes = silver_path.read_bytes()
    vocab_bytes = vocab_path.read_bytes()
    try:
        lines = cmudict_bytes.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError("CMUdict dictionary is not valid UTF-8") from error
    return {
        "cmu_lines": lines,
        "gold": _load_json_bytes(gold_path, gold_bytes),
        "silver": _load_json_bytes(silver_path, silver_bytes),
        "kokoro_vocab": _load_json_bytes(vocab_path, vocab_bytes),
        "cmudict_sha256": CMUDICT_SHA256,
        "gold_sha256": sha256_identity(gold_bytes),
        "silver_sha256": sha256_identity(silver_bytes),
    }


def _read_existing(path: Path) -> Mapping[str, Any] | None:
    if not path.exists():
        return None
    try:
        value = _load_json(path)
    except ValueError:
        return None
    return value if isinstance(value, Mapping) else None


def _generate_for_path(
    *, lock_path: Path, gold_path: Path, silver_path: Path, vocab_path: Path,
    existing_path: Path | None,
) -> dict[str, Any]:
    output = build_audit_pack(**_load_inputs(
        lock_path=lock_path, gold_path=gold_path, silver_path=silver_path,
        vocab_path=vocab_path), generation_timestamp=current_generation_timestamp())
    existing = _read_existing(existing_path) if existing_path else None
    if (
        existing is not None
        and existing.get("auditPackVersion") == output["auditPackVersion"]
        and _valid_timestamp(existing.get("generationTimestamp"))
    ):
        output["generationTimestamp"] = existing["generationTimestamp"]
    return output


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as file:
            os.fchmod(file.fileno(), 0o644)
            file.write(data)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "check"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--lock", type=Path, required=True)
        subparser.add_argument("--gold", type=Path, required=True)
        subparser.add_argument("--silver", type=Path, required=True)
        subparser.add_argument("--vocab", type=Path, required=True)
        subparser.add_argument("--output" if command == "build" else "--expected", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    destination = arguments.output if arguments.command == "build" else arguments.expected
    try:
        output = _generate_for_path(
            lock_path=arguments.lock, gold_path=arguments.gold,
            silver_path=arguments.silver, vocab_path=arguments.vocab,
            existing_path=destination)
        generated = canonical_json_bytes(output) + b"\n"
        if arguments.command == "build":
            _write_atomic(destination, generated)
        elif not destination.exists() or destination.read_bytes() != generated:
            raise ValueError(f"{destination} does not match deterministic regeneration")
        return 0
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
