"""Extract the renderer's immutable ONNX model policy from Echo source."""

from __future__ import annotations

import re
from pathlib import Path

from echo_renderer.identity import ModelPolicy


_MODEL_SOURCE = Path("EchoCore/Services/Narration/OnnxKokoroEngine.swift")
_REVISION_PATTERN = re.compile(
    r'^[ \t]*private nonisolated static let modelRevision = "([^"\r\n]+)"[ \t]*$',
    re.MULTILINE,
)
_EXPECTED_BYTES_PATTERN = re.compile(
    r"^[ \t]*nonisolated static let expectedModelBytes = "
    r"([0-9](?:_?[0-9])*)[ \t]*$",
    re.MULTILINE,
)


def read_model_policy(source_root: Path) -> ModelPolicy:
    source_path = source_root / _MODEL_SOURCE
    try:
        source = source_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ValueError(f"cannot read model-policy source: {source_path}") from error

    revisions = _REVISION_PATTERN.findall(source)
    if len(revisions) != 1:
        raise ValueError("model policy must contain exactly one revision literal")

    expected_byte_literals = _EXPECTED_BYTES_PATTERN.findall(source)
    if len(expected_byte_literals) != 1:
        raise ValueError("model policy must contain exactly one expected-byte literal")
    expected_byte_count = int(expected_byte_literals[0].replace("_", ""), 10)
    if expected_byte_count <= 0:
        raise ValueError("model expected-byte count must be positive")

    return ModelPolicy(
        revision=revisions[0],
        expected_byte_count=expected_byte_count,
        delivery_mode="sharedEchoCache",
        bytes_attested=False,
    )
