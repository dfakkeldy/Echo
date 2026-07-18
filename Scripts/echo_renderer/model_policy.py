"""Extract the renderer's immutable ONNX model policy from Echo source."""

from __future__ import annotations

import re
from pathlib import Path

from echo_renderer.identity import ModelPolicy


_MODEL_SOURCE = Path("EchoCore/Services/Narration/OnnxKokoroEngine.swift")
_REVISION_PATTERN = re.compile(
    r'^[ \t]*private nonisolated static let modelRevision = "([0-9a-f]{40})"[ \t]*$',
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
        raise ValueError(
            f"{source_path}: expected exactly one "
            f'`modelRevision = "<40-hex>"` assignment, found {len(revisions)}'
        )

    expected_byte_literals = _EXPECTED_BYTES_PATTERN.findall(source)
    if len(expected_byte_literals) != 1:
        raise ValueError(
            f"{source_path}: expected exactly one "
            f"`expectedModelBytes = <integer>` assignment, "
            f"found {len(expected_byte_literals)}"
        )
    expected_byte_count = int(expected_byte_literals[0].replace("_", ""), 10)
    if expected_byte_count <= 0:
        raise ValueError(
            f"{source_path}: `expectedModelBytes = <integer>` assignment "
            "must be a positive integer"
        )

    return ModelPolicy(
        revision=revisions[0],
        expected_byte_count=expected_byte_count,
        delivery_mode="sharedEchoCache",
        bytes_attested=False,
    )
