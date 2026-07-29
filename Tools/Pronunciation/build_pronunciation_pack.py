#!/usr/bin/env python3
"""Build Echo's pinned, deterministic supplemental pronunciation pack."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


CMUDICT_COMMIT = "74790861f652b15e4ac49015a90074ad62a27690"
CMUDICT_UPSTREAM_URL = "https://github.com/cmusphinx/cmudict"
CMUDICT_DICTIONARY_PATH = "ThirdParty/CMUdict/cmudict.dict"
CMUDICT_LICENSE_PATH = "ThirdParty/CMUdict/LICENSE"
CMUDICT_SHA256 = (
    "sha256:81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22"
)
CMUDICT_LICENSE_SHA256 = (
    "sha256:bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a"
)
DIALECT = "en-US"

GENERATOR_BEHAVIOR = {
    "generatorVersion": "echo-pronunciation-pack-generator-v2",
    "normalizationPolicyVersion": "english-key-normalization-v1",
    "arpabetMappingVersion": "cmudict-arpabet-to-kokoro-v2",
    "sourcePrecedencePolicyVersion": "gold-silver-exclusion-v1",
    "automaticSelectionPolicyVersion": "single-validated-compatible-candidate-v2",
    "candidateValidationPolicyVersion": "source-candidate-validation-v1",
}

VOWELS = {
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

CONSONANTS = {
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

STRESS = {"0": "", "1": "ˈ", "2": "ˌ"}
FREQUENCY_BANDS = {"veryCommon", "common", "uncommon", "rare", "unknown"}
WORD_PATTERN = re.compile(r"^[a-z]+(?:['-][a-z]+)*$")
ALTERNATE_PATTERN = re.compile(r"\(\d+\)$")
TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"
)
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")

DEFAULT_LICENSES = [
    {
        "sourceID": "cmudict",
        "licenseID": "CMUdict-BSD-style",
        "licensePath": "ThirdParty/CMUdict/LICENSE",
    }
]
DEFAULT_ACKNOWLEDGMENTS = [
    "CMUdict notice bundled from THIRD_PARTY_NOTICES.md",
]


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_identity(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def semantic_pack_version(semantic_identity_payload: Mapping[str, Any]) -> str:
    return sha256_identity(canonical_json_bytes(semantic_identity_payload))


def _valid_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
        return False
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value


def current_generation_timestamp() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def choose_generation_timestamp(
    *,
    existing: Mapping[str, Any] | None,
    pack_version: str,
    now: str,
) -> str:
    if not _valid_timestamp(now):
        raise ValueError("generation timestamp must be whole-second RFC 3339 UTC")
    if (
        existing is not None
        and existing.get("packVersion") == pack_version
        and _valid_timestamp(existing.get("generationTimestamp"))
    ):
        return str(existing["generationTimestamp"])
    return now


def _normalize_word(raw_word: str) -> str | None:
    word = ALTERNATE_PATTERN.sub("", raw_word).lower()
    return word if WORD_PATTERN.fullmatch(word) else None


def _normalized_existing_words(values: Mapping[str, Any]) -> set[str]:
    normalized: set[str] = set()
    for raw_word in values:
        word = _normalize_word(raw_word)
        if word is not None:
            normalized.add(word)
    return normalized


def _convert_arpabet(tokens: Sequence[str]) -> str:
    output: list[str] = []
    for token in tokens:
        if token in CONSONANTS:
            output.append(CONSONANTS[token])
            continue

        match = re.fullmatch(r"([A-Z]+)([012])", token)
        if match is None or match.group(1) not in VOWELS:
            raise ValueError(f"unsupported ARPAbet token: {token}")
        phoneme, stress = match.groups()
        unstressed, stressed = VOWELS[phoneme]
        vowel = unstressed if stress == "0" else stressed
        output.append(STRESS[stress] + vowel)
    if not output:
        raise ValueError("pronunciation has no ARPAbet tokens")
    return "".join(output)


def _normalized_vocab(kokoro_vocab: Mapping[str, Any]) -> dict[str, int]:
    raw_vocab = kokoro_vocab.get("vocab", kokoro_vocab)
    if not isinstance(raw_vocab, Mapping) or not raw_vocab:
        raise ValueError("Kokoro vocabulary must be a nonempty object")

    normalized: dict[str, int] = {}
    for scalar, token_id in raw_vocab.items():
        if (
            not isinstance(scalar, str)
            or len(scalar) != 1
            or not isinstance(token_id, int)
            or isinstance(token_id, bool)
        ):
            raise ValueError("Kokoro vocabulary must map Unicode scalars to integers")
        normalized[scalar] = token_id
    return dict(sorted(normalized.items()))


def _normalized_sha256(value: str | None, fallback_bytes: bytes) -> str:
    if value is None:
        return sha256_identity(fallback_bytes)
    normalized = value if value.startswith("sha256:") else f"sha256:{value}"
    if not SHA256_PATTERN.fullmatch(normalized):
        raise ValueError(f"invalid SHA-256 identity: {value}")
    return normalized


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
    cmu_identity = _normalized_sha256(
        cmudict_sha256,
        canonical_json_bytes(sorted(cmu_lines)),
    )
    gold_identity = _normalized_sha256(gold_sha256, canonical_json_bytes(gold))
    silver_identity = _normalized_sha256(
        silver_sha256, canonical_json_bytes(silver)
    )
    return [
        {
            "sourceID": "cmudict",
            "snapshotID": f"cmudict@{commit}",
            "role": "supplemental-candidates",
            "sha256": cmu_identity,
        },
        {
            "sourceID": "echo-us-gold",
            "snapshotID": f"echo-us-gold@{gold_identity}",
            "role": "exclusion-input",
            "sha256": gold_identity,
        },
        {
            "sourceID": "echo-us-silver",
            "snapshotID": f"echo-us-silver@{silver_identity}",
            "role": "exclusion-input",
            "sha256": silver_identity,
        },
    ]


def _validate_sources(sources: Iterable[Mapping[str, Any]]) -> list[dict[str, str]]:
    normalized: list[dict[str, str]] = []
    for source in sources:
        if set(source) != {"sourceID", "snapshotID", "role", "sha256"}:
            raise ValueError("each source must contain exact snapshot fields")
        values = {
            key: source[key]
            for key in ("sourceID", "snapshotID", "role", "sha256")
        }
        if not all(isinstance(value, str) and value for value in values.values()):
            raise ValueError("source snapshot fields must be nonempty strings")
        if not SHA256_PATTERN.fullmatch(values["sha256"]):
            raise ValueError("source snapshot SHA-256 is invalid")
        normalized.append(values)

    normalized.sort(key=lambda item: item["sourceID"])
    source_ids = [source["sourceID"] for source in normalized]
    if source_ids != ["cmudict", "echo-us-gold", "echo-us-silver"]:
        raise ValueError("sources must contain cmudict, echo-us-gold, and echo-us-silver")
    return normalized


def _validate_generator_behavior(
    generator_behavior: Mapping[str, Any],
) -> dict[str, str]:
    if set(generator_behavior) != set(GENERATOR_BEHAVIOR):
        raise ValueError("generator behavior fields do not match the frozen contract")
    normalized = dict(generator_behavior)
    if not all(isinstance(value, str) and value for value in normalized.values()):
        raise ValueError("generator behavior versions must be nonempty strings")
    return normalized


def _validate_frequency_bands(
    frequency_bands: Mapping[str, Any] | None,
) -> dict[str, str]:
    if frequency_bands is None:
        return {}
    normalized: dict[str, str] = {}
    for raw_word, band in frequency_bands.items():
        word = _normalize_word(raw_word)
        if word is None or band not in FREQUENCY_BANDS:
            raise ValueError(f"invalid reviewed frequency band for {raw_word!r}")
        if word in normalized:
            raise ValueError(
                f"frequency keys normalize to duplicate spelling: {word!r}"
            )
        normalized[word] = band
    return normalized


def build_pack(
    *,
    cmu_lines: Iterable[str],
    gold: Mapping[str, Any],
    silver: Mapping[str, Any],
    kokoro_vocab: Mapping[str, Any],
    frequency_bands: Mapping[str, Any] | None = None,
    generation_timestamp: str | None = None,
    commit: str = CMUDICT_COMMIT,
    cmudict_sha256: str | None = None,
    gold_sha256: str | None = None,
    silver_sha256: str | None = None,
    sources: Iterable[Mapping[str, Any]] | None = None,
    generator_behavior: Mapping[str, Any] = GENERATOR_BEHAVIOR,
    licenses: Sequence[Mapping[str, Any]] = DEFAULT_LICENSES,
    required_acknowledgments: Sequence[str] = DEFAULT_ACKNOWLEDGMENTS,
) -> dict[str, Any]:
    if not isinstance(gold, Mapping) or not isinstance(silver, Mapping):
        raise ValueError("gold and silver exclusion inputs must be JSON objects")
    if not isinstance(commit, str) or not commit:
        raise ValueError("CMUdict commit must be nonempty")

    lines = [line.rstrip("\r\n") for line in cmu_lines]
    behavior = _validate_generator_behavior(generator_behavior)
    vocabulary = _normalized_vocab(kokoro_vocab)
    vocabulary_scalars = set(vocabulary)
    reviewed_bands = _validate_frequency_bands(frequency_bands)
    gold_words = _normalized_existing_words(gold)
    silver_words = _normalized_existing_words(silver)
    source_records = _validate_sources(
        sources
        if sources is not None
        else _default_sources(
            cmu_lines=lines,
            gold=gold,
            silver=silver,
            commit=commit,
            cmudict_sha256=cmudict_sha256,
            gold_sha256=gold_sha256,
            silver_sha256=silver_sha256,
        )
    )
    cmudict_snapshot_id = next(
        source["snapshotID"]
        for source in source_records
        if source["sourceID"] == "cmudict"
    )

    pronunciations_by_word: dict[str, list[Sequence[str]]] = {}
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
        pronunciations_by_word.setdefault(word, []).append(fields[1:])

    entries: dict[str, list[dict[str, Any]]] = {}
    existing_gold_count = 0
    existing_silver_count = 0
    ambiguous_count = 0
    incompatible_count = 0

    for word in sorted(pronunciations_by_word):
        if word in gold_words:
            existing_gold_count += 1
            continue
        if word in silver_words:
            existing_silver_count += 1
            continue

        compatible_ipa: set[str] = set()
        for tokens in pronunciations_by_word[word]:
            try:
                ipa = _convert_arpabet(tokens)
            except ValueError:
                incompatible_count += 1
                continue
            if any(scalar not in vocabulary_scalars for scalar in ipa):
                incompatible_count += 1
                continue
            compatible_ipa.add(ipa)

        if not compatible_ipa:
            continue

        is_automatic = len(compatible_ipa) == 1
        if not is_automatic:
            ambiguous_count += 1
        validation_status = (
            "validated-automatic"
            if is_automatic
            else "report-only-missing-sense-label"
        )
        candidates: list[dict[str, Any]] = []
        for ipa in sorted(compatible_ipa):
            digest = hashlib.sha256(
                f"cmudict@{commit}\0{word}\0{ipa}".encode("utf-8")
            ).hexdigest()[:12]
            candidates.append(
                {
                    "candidateID": f"cmudict.{word}.{digest}",
                    "ipa": ipa,
                    "lexicalClass": None,
                    "senseLabel": None,
                    "sourceID": "cmudict",
                    "sourceSnapshotID": cmudict_snapshot_id,
                    "sourceTier": "supplemental",
                    "kind": "explicit",
                    "automaticWithoutContext": is_automatic,
                    "frequencyBand": reviewed_bands.get(word, "unknown"),
                    "validationStatus": validation_status,
                    "ruleProvenance": {
                        "normalizationPolicyVersion": behavior[
                            "normalizationPolicyVersion"
                        ],
                        "arpabetMappingVersion": behavior["arpabetMappingVersion"],
                        "validationPolicyVersion": behavior[
                            "candidateValidationPolicyVersion"
                        ],
                    },
                }
            )
        entries[word] = candidates

    normalized_data_sha256 = sha256_identity(canonical_json_bytes(entries))
    kokoro_vocabulary_version = sha256_identity(canonical_json_bytes(vocabulary))
    semantic_identity_payload = {
        "identitySchemaVersion": 1,
        "normalizedDataSHA256": normalized_data_sha256,
        "sourceSnapshots": [
            {
                "sourceID": source["sourceID"],
                "snapshotID": source["snapshotID"],
                "sha256": source["sha256"],
            }
            for source in source_records
        ],
        "generatorBehavior": behavior,
        "kokoroVocabularyVersion": kokoro_vocabulary_version,
        "dialect": DIALECT,
    }
    pack_version = semantic_pack_version(semantic_identity_payload)

    timestamp = generation_timestamp or current_generation_timestamp()
    if not _valid_timestamp(timestamp):
        raise ValueError("generation timestamp must be whole-second RFC 3339 UTC")

    license_records = [dict(record) for record in licenses]
    acknowledgments = list(required_acknowledgments)
    if not all(isinstance(item, str) and item for item in acknowledgments):
        raise ValueError("required acknowledgments must be nonempty strings")

    candidate_count = sum(len(candidates) for candidates in entries.values())
    return {
        "schemaVersion": 1,
        "packVersion": pack_version,
        "generatorVersion": behavior["generatorVersion"],
        "entryCount": len(entries),
        "candidateCount": candidate_count,
        "normalizedDataSHA256": normalized_data_sha256,
        "kokoroVocabularyVersion": kokoro_vocabulary_version,
        "dialect": DIALECT,
        "sources": source_records,
        "licenses": license_records,
        "requiredAcknowledgments": acknowledgments,
        "generationTimestamp": timestamp,
        "semanticIdentityPayload": semantic_identity_payload,
        "entries": entries,
        "report": {
            "existingGold": existing_gold_count,
            "existingSilver": existing_silver_count,
            "ambiguous": ambiguous_count,
            "incompatible": incompatible_count,
            "imported": len(entries),
        },
    }


def _verify_bytes(path: Path, data: bytes, expected_sha256: str) -> None:
    expected = (
        expected_sha256
        if expected_sha256.startswith("sha256:")
        else f"sha256:{expected_sha256}"
    )
    if not SHA256_PATTERN.fullmatch(expected):
        raise ValueError(f"invalid locked SHA-256 for {path}")
    actual = sha256_identity(data)
    if actual != expected:
        raise ValueError(
            f"SHA-256 mismatch for {path}: expected {expected}, found {actual}"
        )


def verify_locked_file(path: Path, expected_sha256: str) -> None:
    _verify_bytes(path, path.read_bytes(), expected_sha256)


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot load JSON from {path}: {error}") from error


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _load_json_bytes(path: Path, data: bytes) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot load JSON from {path}: {error}") from error


def _expected_lock() -> dict[str, Any]:
    return {
        "sourceID": "cmudict",
        "upstreamURL": CMUDICT_UPSTREAM_URL,
        "commit": CMUDICT_COMMIT,
        "dialect": DIALECT,
        "dictionary": {
            "path": CMUDICT_DICTIONARY_PATH,
            "sha256": CMUDICT_SHA256,
        },
        "license": {
            "path": CMUDICT_LICENSE_PATH,
            "sha256": CMUDICT_LICENSE_SHA256,
        },
    }


def _load_inputs(
    *,
    lock_path: Path,
    gold_path: Path,
    silver_path: Path,
    vocab_path: Path,
    frequency_path: Path | None,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    lock = _load_json(lock_path)
    if not isinstance(lock, Mapping):
        raise ValueError("CMUdict lock must be a JSON object")
    if lock != _expected_lock():
        raise ValueError("lock does not match the frozen CMUdict source")

    cmudict_path = Path(CMUDICT_DICTIONARY_PATH)
    cmudict_license_path = Path(CMUDICT_LICENSE_PATH)
    cmudict_bytes = cmudict_path.read_bytes()
    cmudict_license_bytes = cmudict_license_path.read_bytes()
    gold_bytes = gold_path.read_bytes()
    silver_bytes = silver_path.read_bytes()
    vocab_bytes = vocab_path.read_bytes()
    frequency_bytes = frequency_path.read_bytes() if frequency_path else None

    _verify_bytes(cmudict_path, cmudict_bytes, CMUDICT_SHA256)
    _verify_bytes(
        cmudict_license_path,
        cmudict_license_bytes,
        CMUDICT_LICENSE_SHA256,
    )
    try:
        cmu_lines = cmudict_bytes.decode("utf-8").splitlines()
        cmudict_license_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("CMUdict dictionary or license is not valid UTF-8") from error

    gold = _load_json_bytes(gold_path, gold_bytes)
    silver = _load_json_bytes(silver_path, silver_bytes)
    vocab = _load_json_bytes(vocab_path, vocab_bytes)
    frequency_bands = (
        _load_json_bytes(frequency_path, frequency_bytes)
        if frequency_path is not None and frequency_bytes is not None
        else None
    )
    if frequency_bands is not None and not isinstance(frequency_bands, Mapping):
        raise ValueError("frequency bands input must be a JSON object")

    pack_arguments = {
        "cmu_lines": cmu_lines,
        "gold": gold,
        "silver": silver,
        "kokoro_vocab": vocab,
        "frequency_bands": frequency_bands,
        "commit": CMUDICT_COMMIT,
        "cmudict_sha256": CMUDICT_SHA256,
        "gold_sha256": sha256_identity(gold_bytes),
        "silver_sha256": sha256_identity(silver_bytes),
    }
    return pack_arguments, frequency_bands


def _read_existing(path: Path) -> Mapping[str, Any] | None:
    if not path.exists():
        return None
    try:
        value = _load_json(path)
    except ValueError:
        return None
    return value if isinstance(value, Mapping) else None


def _generate_for_path(
    *,
    lock_path: Path,
    gold_path: Path,
    silver_path: Path,
    vocab_path: Path,
    frequency_path: Path | None,
    existing_path: Path | None,
) -> dict[str, Any]:
    arguments, _ = _load_inputs(
        lock_path=lock_path,
        gold_path=gold_path,
        silver_path=silver_path,
        vocab_path=vocab_path,
        frequency_path=frequency_path,
    )
    now = current_generation_timestamp()
    output = build_pack(**arguments, generation_timestamp=now)
    existing = _read_existing(existing_path) if existing_path else None
    output["generationTimestamp"] = choose_generation_timestamp(
        existing=existing,
        pack_version=output["packVersion"],
        now=now,
    )
    return output


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
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
        subparser.add_argument("--frequency-bands", type=Path)
        if command == "build":
            subparser.add_argument("--output", type=Path, required=True)
        else:
            subparser.add_argument("--expected", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    destination = arguments.output if arguments.command == "build" else arguments.expected
    try:
        output = _generate_for_path(
            lock_path=arguments.lock,
            gold_path=arguments.gold,
            silver_path=arguments.silver,
            vocab_path=arguments.vocab,
            frequency_path=arguments.frequency_bands,
            existing_path=destination,
        )
        generated = canonical_json_bytes(output) + b"\n"
        if arguments.command == "build":
            _write_atomic(arguments.output, generated)
            return 0
        if not arguments.expected.exists() or arguments.expected.read_bytes() != generated:
            raise ValueError(
                f"{arguments.expected} does not match deterministic regeneration"
            )
        return 0
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
