"""Deterministic identities for Echo renderer files, resources, and manifests.

Resource-tree schema v1 sorts normalized POSIX-relative path strings. For each
regular file, the tree hash receives exactly the following bytes in order:

1. the UTF-8 path-byte length as an unsigned 8-byte big-endian integer;
2. the UTF-8 POSIX-relative path bytes; and
3. the file's raw 32-byte SHA-256 digest.

There is no size field, delimiter, terminator, or domain-prefix byte sequence.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Mapping, Sequence


_COMMIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
_SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class FileIdentity:
    sha256: str
    byte_count: int


@dataclass(frozen=True)
class ResourceTreeIdentity:
    sha256: str
    regular_file_count: int


@dataclass(frozen=True)
class ModelPolicy:
    revision: str
    expected_byte_count: int
    delivery_mode: str = "sharedEchoCache"
    bytes_attested: bool = False


@dataclass(frozen=True)
class RendererManifest:
    schema_version: int
    echo_source_sha: str
    installer_source_sha: str
    executable_path: str
    executable: FileIdentity
    resources_path: str
    resources: ResourceTreeIdentity
    render_version: str
    build_configuration: str
    architectures: Sequence[str]
    minimum_macos_version: str
    model_policy: ModelPolicy
    capabilities: Sequence[str]


def canonical_json_bytes(payload: Mapping[str, object]) -> bytes:
    """Encode one JSON mapping using the renderer's canonical byte format."""
    return (
        json.dumps(
            dict(payload),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        + b"\n"
    )


def strict_json_object(data: bytes) -> dict[str, object]:
    """Decode one JSON object while rejecting duplicate keys at every depth."""

    def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        payload = json.loads(data, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValueError("invalid JSON") from error
    if not isinstance(payload, dict):
        raise ValueError("expected a JSON object")
    return payload


def identify_regular_file(path: Path) -> FileIdentity:
    """Return the byte identity of a regular, non-symbolic-link file."""
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ValueError(f"cannot inspect regular file: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"expected a regular non-link file: {path}")

    digest = hashlib.sha256()
    byte_count = 0
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
                byte_count += len(chunk)
    except OSError as error:
        raise ValueError(f"cannot read regular file: {path}") from error
    return FileIdentity(sha256=digest.hexdigest(), byte_count=byte_count)


def identify_resource_tree(root: Path) -> ResourceTreeIdentity:
    """Identify a link-free tree using the documented resource-tree v1 frame."""
    try:
        root_metadata = root.lstat()
    except OSError as error:
        raise ValueError(f"cannot inspect resource root: {root}") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ValueError(f"expected a regular non-link directory: {root}")

    regular_files: list[tuple[str, Path]] = []

    def visit(directory: Path, relative_parts: tuple[str, ...]) -> None:
        try:
            entries = list(os.scandir(directory))
        except OSError as error:
            raise ValueError(f"cannot read resource directory: {directory}") from error
        for entry in entries:
            entry_path = Path(entry.path)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise ValueError(f"cannot inspect resource entry: {entry_path}") from error
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"resource links are not allowed: {entry_path}")

            parts = (*relative_parts, entry.name)
            relative_path = "/".join(parts)
            _validate_relative_path(relative_path, "resource entry path")
            if stat.S_ISDIR(metadata.st_mode):
                visit(entry_path, parts)
            elif stat.S_ISREG(metadata.st_mode):
                regular_files.append((relative_path, entry_path))
            else:
                raise ValueError(f"special resource files are not allowed: {entry_path}")

    visit(root, ())

    tree_digest = hashlib.sha256()
    for relative_path, path in sorted(regular_files, key=lambda item: item[0]):
        try:
            path_bytes = relative_path.encode("utf-8")
        except UnicodeEncodeError as error:
            raise ValueError(f"resource path is not valid UTF-8: {relative_path!r}") from error
        file_identity = identify_regular_file(path)
        tree_digest.update(len(path_bytes).to_bytes(8, "big", signed=False))
        tree_digest.update(path_bytes)
        tree_digest.update(bytes.fromhex(file_identity.sha256))

    return ResourceTreeIdentity(
        sha256=tree_digest.hexdigest(),
        regular_file_count=len(regular_files),
    )


def manifest_payload(manifest: RendererManifest) -> dict[str, object]:
    """Convert a renderer manifest into its schema-v1 JSON object."""
    payload: dict[str, object] = {
        "schemaVersion": manifest.schema_version,
        "echoSourceSHA": manifest.echo_source_sha,
        "installerSourceSHA": manifest.installer_source_sha,
        "executablePath": manifest.executable_path,
        "executable": {
            "sha256": manifest.executable.sha256,
            "byteCount": manifest.executable.byte_count,
        },
        "resourcesPath": manifest.resources_path,
        "resources": {
            "sha256": manifest.resources.sha256,
            "regularFileCount": manifest.resources.regular_file_count,
        },
        "renderVersion": manifest.render_version,
        "buildConfiguration": manifest.build_configuration,
        "architectures": list(manifest.architectures),
        "minimumMacOSVersion": manifest.minimum_macos_version,
        "modelPolicy": {
            "revision": manifest.model_policy.revision,
            "expectedByteCount": manifest.model_policy.expected_byte_count,
            "deliveryMode": manifest.model_policy.delivery_mode,
            "modelBytesAttested": manifest.model_policy.bytes_attested,
        },
        "capabilities": list(manifest.capabilities),
    }
    _manifest_from_payload(payload)
    return payload


def parse_manifest(data: bytes) -> RendererManifest:
    """Strictly decode and validate one renderer manifest schema-v1 object."""
    return _manifest_from_payload(strict_json_object(data))


def _manifest_from_payload(payload: Mapping[str, object]) -> RendererManifest:
    _require_exact_keys(
        payload,
        {
            "schemaVersion",
            "echoSourceSHA",
            "installerSourceSHA",
            "executablePath",
            "executable",
            "resourcesPath",
            "resources",
            "renderVersion",
            "buildConfiguration",
            "architectures",
            "minimumMacOSVersion",
            "modelPolicy",
            "capabilities",
        },
        "renderer manifest",
    )

    schema_version = _require_integer(payload["schemaVersion"], "schemaVersion")
    if schema_version != 1:
        raise ValueError("schemaVersion must be 1")

    echo_source_sha = _require_string(payload["echoSourceSHA"], "echoSourceSHA")
    installer_source_sha = _require_string(
        payload["installerSourceSHA"], "installerSourceSHA"
    )
    if _COMMIT_SHA_PATTERN.fullmatch(echo_source_sha) is None:
        raise ValueError("echoSourceSHA must be 40 lowercase hexadecimal characters")
    if _COMMIT_SHA_PATTERN.fullmatch(installer_source_sha) is None:
        raise ValueError("installerSourceSHA must be 40 lowercase hexadecimal characters")

    executable_path = _require_string(payload["executablePath"], "executablePath")
    resources_path = _require_string(payload["resourcesPath"], "resourcesPath")
    _validate_relative_path(executable_path, "executablePath")
    _validate_relative_path(resources_path, "resourcesPath")

    executable_payload = _require_object(payload["executable"], "executable")
    _require_exact_keys(executable_payload, {"sha256", "byteCount"}, "executable")
    executable = FileIdentity(
        sha256=_require_sha256(executable_payload["sha256"], "executable.sha256"),
        byte_count=_require_nonnegative_integer(
            executable_payload["byteCount"], "executable.byteCount"
        ),
    )

    resources_payload = _require_object(payload["resources"], "resources")
    _require_exact_keys(
        resources_payload, {"sha256", "regularFileCount"}, "resources"
    )
    resources = ResourceTreeIdentity(
        sha256=_require_sha256(resources_payload["sha256"], "resources.sha256"),
        regular_file_count=_require_nonnegative_integer(
            resources_payload["regularFileCount"], "resources.regularFileCount"
        ),
    )

    render_version = _require_nonempty_string(payload["renderVersion"], "renderVersion")
    build_configuration = _require_nonempty_string(
        payload["buildConfiguration"], "buildConfiguration"
    )
    minimum_macos_version = _require_nonempty_string(
        payload["minimumMacOSVersion"], "minimumMacOSVersion"
    )
    architectures = _require_nonempty_string_list(payload["architectures"], "architectures")
    capabilities = _require_nonempty_string_list(payload["capabilities"], "capabilities")

    model_payload = _require_object(payload["modelPolicy"], "modelPolicy")
    _require_exact_keys(
        model_payload,
        {
            "revision",
            "expectedByteCount",
            "deliveryMode",
            "modelBytesAttested",
        },
        "modelPolicy",
    )
    revision = _require_nonempty_string(model_payload["revision"], "modelPolicy.revision")
    expected_byte_count = _require_nonnegative_integer(
        model_payload["expectedByteCount"], "modelPolicy.expectedByteCount"
    )
    delivery_mode = _require_string(
        model_payload["deliveryMode"], "modelPolicy.deliveryMode"
    )
    if delivery_mode != "sharedEchoCache":
        raise ValueError("modelPolicy.deliveryMode must be sharedEchoCache")
    bytes_attested = model_payload["modelBytesAttested"]
    if bytes_attested is not False:
        raise ValueError("modelPolicy.modelBytesAttested must be false")

    return RendererManifest(
        schema_version=schema_version,
        echo_source_sha=echo_source_sha,
        installer_source_sha=installer_source_sha,
        executable_path=executable_path,
        executable=executable,
        resources_path=resources_path,
        resources=resources,
        render_version=render_version,
        build_configuration=build_configuration,
        architectures=architectures,
        minimum_macos_version=minimum_macos_version,
        model_policy=ModelPolicy(
            revision=revision,
            expected_byte_count=expected_byte_count,
            delivery_mode=delivery_mode,
            bytes_attested=False,
        ),
        capabilities=capabilities,
    )


def _validate_relative_path(value: str, field: str) -> None:
    if not value or value in (".", "..") or "\\" in value:
        raise ValueError(f"{field} must be a nonempty POSIX-relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value:
        raise ValueError(f"{field} must be a normalized POSIX-relative path")
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"{field} contains an unsafe path component")


def _require_exact_keys(
    payload: Mapping[str, object], expected: set[str], field: str
) -> None:
    actual = set(payload)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise ValueError(f"{field} keys do not match schema; missing={missing}, unknown={unknown}")


def _require_object(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{field} must be an object")
    return value


def _require_string(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    return value


def _require_nonempty_string(value: object, field: str) -> str:
    result = _require_string(value, field)
    if not result:
        raise ValueError(f"{field} must not be empty")
    return result


def _require_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{field} must be an integer")
    return value


def _require_nonnegative_integer(value: object, field: str) -> int:
    result = _require_integer(value, field)
    if result < 0:
        raise ValueError(f"{field} must not be negative")
    return result


def _require_sha256(value: object, field: str) -> str:
    result = _require_string(value, field)
    if _SHA256_PATTERN.fullmatch(result) is None:
        raise ValueError(f"{field} must be 64 lowercase hexadecimal characters")
    return result


def _require_nonempty_string_list(value: object, field: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{field} must be a nonempty array")
    result: list[str] = []
    for item in value:
        result.append(_require_nonempty_string(item, f"{field} item"))
    return tuple(result)
