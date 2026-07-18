"""Read-only verification for installed, content-addressed Echo renderers."""

from __future__ import annotations

import hashlib
import os
import platform
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from echo_renderer.identity import (
    RendererManifest,
    canonical_json_bytes,
    identify_regular_file,
    identify_resource_tree,
    manifest_payload,
    parse_manifest,
    validate_commit_sha,
    validate_sha256,
)


_EXECUTABLE_NAME = "echo-cli"
_RESOURCES_NAME = "EchoNarrationResources"
_MANIFEST_NAME = "renderer-manifest.json"
_TOP_LEVEL_NAMES = {_EXECUTABLE_NAME, _RESOURCES_NAME, _MANIFEST_NAME}
_VERSION_PATTERN = re.compile(r"ONNX rv([0-9]+) \(Release\)\n?\Z")
_ARCHITECTURE_PATTERN = re.compile(r"[A-Za-z0-9_]+\Z")
_VERSION_NUMBER_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){1,2}\Z")
_MINOS_PATTERN = re.compile(
    r"^[ \t]*minos[ \t]+([0-9]+(?:\.[0-9]+){1,2})[ \t]*$", re.MULTILINE
)
_LEGACY_MINOS_PATTERN = re.compile(
    r"^[ \t]*cmd[ \t]+LC_VERSION_MIN_MACOSX[ \t]*$"
    r"(?:(?!^[ \t]*Load command).)*?"
    r"^[ \t]*version[ \t]+([0-9]+(?:\.[0-9]+){1,2})[ \t]*$",
    re.MULTILINE | re.DOTALL,
)
# The surfaces the governed wrappers actually invoke. There are no
# `--pronunciation-*` narrate flags: the pronunciation audit and listening
# reel are default `narrate` outputs, and `--no-pronunciation-review` is the
# opt-out. `verify-sidecar` is a required subcommand, not a narrate flag, so
# it is probed and reported separately from the narrate capability set.
_REQUIRED_NARRATE_CAPABILITIES = (
    "--cover",
    "--sidecar",
    "--voice",
    "--db",
    "--work-dir",
    "--jobs",
    "--threads",
    "--resume",
    "--max-chapters",
    "--no-pronunciation-review",
)
_VERIFY_SIDECAR_SUBCOMMAND = "verify-sidecar"
_REQUIRED_CAPABILITIES = _REQUIRED_NARRATE_CAPABILITIES + (_VERIFY_SIDECAR_SUBCOMMAND,)


@dataclass(frozen=True)
class RendererProbe:
    render_version: int
    build_configuration: str
    architectures: Sequence[str]
    minimum_macos_version: str
    capabilities: Sequence[str]


@dataclass(frozen=True)
class VerifiedRenderer:
    source_sha: str
    manifest_sha: str
    build_root: Path
    executable: Path
    resources: Path
    manifest: RendererManifest


def verify_build_identity(
    path: Path,
    *,
    expected_source_sha: str,
    expected_manifest_sha: str,
) -> VerifiedRenderer:
    """Verify one installed package's names, schema, and bytes without mutation."""
    validate_commit_sha(expected_source_sha, "expected source SHA")
    validate_sha256(expected_manifest_sha, "expected manifest SHA")
    build_root = _require_canonical_directory(path, "renderer build root")
    source_root = _require_canonical_directory(
        build_root.parent, "renderer source root"
    )
    if build_root.name != expected_manifest_sha:
        raise ValueError("renderer build directory does not match the manifest SHA")
    if source_root.name != expected_source_sha:
        raise ValueError("renderer source directory does not match the source SHA")

    try:
        entries = list(os.scandir(build_root))
    except OSError as error:
        raise ValueError(f"cannot inspect renderer package: {build_root}") from error
    entry_names = {entry.name for entry in entries}
    if len(entries) != len(_TOP_LEVEL_NAMES) or entry_names != _TOP_LEVEL_NAMES:
        raise ValueError("renderer package has unexpected top-level entries")

    executable = build_root / _EXECUTABLE_NAME
    resources = build_root / _RESOURCES_NAME
    manifest_path = build_root / _MANIFEST_NAME
    manifest_data = _read_regular_file_once(manifest_path, "renderer manifest")
    if hashlib.sha256(manifest_data).hexdigest() != expected_manifest_sha:
        raise ValueError("renderer manifest bytes do not match the expected SHA")
    manifest = parse_manifest(manifest_data)
    if manifest_data != canonical_json_bytes(manifest_payload(manifest)):
        raise ValueError("renderer manifest is not canonically encoded")

    if manifest.echo_source_sha != expected_source_sha:
        raise ValueError("renderer manifest source SHA does not match its directory")
    if manifest.executable_path != _EXECUTABLE_NAME:
        raise ValueError("renderer manifest executable path does not match the layout")
    if manifest.resources_path != _RESOURCES_NAME:
        raise ValueError("renderer manifest resources path does not match the layout")
    if identify_regular_file(executable) != manifest.executable:
        raise ValueError("renderer executable identity does not match the manifest")
    if identify_resource_tree(resources) != manifest.resources:
        raise ValueError("renderer resource identity does not match the manifest")

    return VerifiedRenderer(
        source_sha=expected_source_sha,
        manifest_sha=expected_manifest_sha,
        build_root=build_root,
        executable=executable,
        resources=resources,
        manifest=manifest,
    )


def probe_release_cli(
    executable: Path,
    resources: Path,
    *,
    runner: Callable = subprocess.run,
) -> RendererProbe:
    """Probe one Release CLI's live identity and host compatibility."""
    environment = os.environ.copy()
    environment["ECHO_RESOURCE_DIR"] = str(resources)
    version_output = _run_probe(
        runner, [str(executable), "--version"], environment=environment
    )
    version_match = _VERSION_PATTERN.fullmatch(version_output)
    if version_match is None:
        raise ValueError("echo-cli version must identify one Release render version")
    render_version = int(version_match.group(1))

    help_output = _run_probe(
        runner,
        [str(executable), "narrate", "--help"],
        environment=environment,
    )
    observed_capabilities = tuple(
        capability
        for capability in _REQUIRED_NARRATE_CAPABILITIES
        if _capability_present(capability, help_output)
    )
    missing_capabilities = [
        capability
        for capability in _REQUIRED_NARRATE_CAPABILITIES
        if capability not in observed_capabilities
    ]
    if missing_capabilities:
        raise ValueError(
            f"echo-cli narrate help is missing capabilities: {missing_capabilities}"
        )

    verify_sidecar_help_output = _run_probe(
        runner,
        [str(executable), _VERIFY_SIDECAR_SUBCOMMAND, "--help"],
        environment=environment,
    )
    if not _capability_present(_VERIFY_SIDECAR_SUBCOMMAND, verify_sidecar_help_output):
        raise ValueError(
            f"echo-cli is missing the {_VERIFY_SIDECAR_SUBCOMMAND} subcommand"
        )
    observed_capabilities = observed_capabilities + (_VERIFY_SIDECAR_SUBCOMMAND,)

    architecture_output = _run_probe(
        runner, ["/usr/bin/lipo", "-archs", str(executable)]
    )
    architecture_values = architecture_output.split()
    if (
        not architecture_values
        or len(set(architecture_values)) != len(architecture_values)
        or any(
            _ARCHITECTURE_PATTERN.fullmatch(value) is None
            for value in architecture_values
        )
    ):
        raise ValueError("lipo returned an invalid architecture list")
    architectures = tuple(sorted(architecture_values))
    host_architecture = platform.machine()
    if not host_architecture or host_architecture not in architectures:
        raise ValueError("renderer does not support the current host architecture")

    load_commands = _run_probe(runner, ["/usr/bin/otool", "-l", str(executable)])
    minimum_versions = _MINOS_PATTERN.findall(load_commands)
    if not minimum_versions:
        minimum_versions = _LEGACY_MINOS_PATTERN.findall(load_commands)
    if not minimum_versions or len(set(minimum_versions)) != 1:
        raise ValueError("otool did not return one deployment floor")
    minimum_macos_version = minimum_versions[0]
    host_macos_version = platform.mac_ver()[0]
    if not host_macos_version:
        raise ValueError("cannot determine the current host macOS version")
    if _version_tuple(minimum_macos_version) > _version_tuple(host_macos_version):
        raise ValueError("renderer requires a newer macOS version than this host")

    return RendererProbe(
        render_version=render_version,
        build_configuration="Release",
        architectures=architectures,
        minimum_macos_version=minimum_macos_version,
        capabilities=observed_capabilities,
    )


class RendererStore:
    def __init__(
        self,
        renderer_root: Path,
        *,
        runner: Callable = subprocess.run,
    ) -> None:
        """Bind operations to one canonical renderer root."""
        self.renderer_root = _require_canonical_directory(
            renderer_root, "renderer store root"
        )
        self._runner = runner

    def verify(self, source_sha: str, manifest_sha: str) -> VerifiedRenderer:
        """Strictly verify one source and manifest identity without mutation."""
        verified = verify_build_identity(
            self.renderer_root / source_sha / manifest_sha,
            expected_source_sha=source_sha,
            expected_manifest_sha=manifest_sha,
        )
        probe = probe_release_cli(
            verified.executable,
            verified.resources,
            runner=self._runner,
        )
        manifest = verified.manifest
        if probe.render_version != manifest.render_version:
            raise ValueError("live render version does not match the manifest")
        if probe.build_configuration != manifest.build_configuration:
            raise ValueError("live build configuration does not match the manifest")
        if tuple(sorted(probe.architectures)) != tuple(sorted(manifest.architectures)):
            raise ValueError("live architectures do not match the manifest")
        if probe.minimum_macos_version != manifest.minimum_macos_version:
            raise ValueError("live deployment floor does not match the manifest")
        if tuple(sorted(probe.capabilities)) != tuple(sorted(manifest.capabilities)):
            raise ValueError("live capabilities do not match the manifest")
        return verified


def _require_canonical_directory(path: Path, field: str) -> Path:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"cannot inspect {field}: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{field} must be a non-link directory")
    if path != resolved:
        raise ValueError(f"{field} must be a canonical path without symlink components")
    return path


def _read_regular_file_once(path: Path, field: str) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        file_descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"cannot open {field}: {path}") from error
    try:
        descriptor_metadata = os.fstat(file_descriptor)
        path_metadata = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(descriptor_metadata.st_mode) or not stat.S_ISREG(
            path_metadata.st_mode
        ):
            raise ValueError(f"{field} must be a regular non-link file")
        if (
            descriptor_metadata.st_dev != path_metadata.st_dev
            or descriptor_metadata.st_ino != path_metadata.st_ino
        ):
            raise ValueError(f"{field} changed while opening: {path}")
        with os.fdopen(file_descriptor, "rb") as handle:
            file_descriptor = -1
            return handle.read()
    except OSError as error:
        raise ValueError(f"cannot read {field}: {path}") from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)


def _run_probe(
    runner: Callable,
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
) -> str:
    keywords: dict[str, object] = {
        "check": False,
        "capture_output": True,
        "text": True,
    }
    if environment is not None:
        keywords["env"] = environment
    try:
        completed = runner(arguments, **keywords)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f"cannot run renderer probe: {arguments[0]}") from error
    if completed.returncode != 0 or not isinstance(completed.stdout, str):
        raise ValueError(f"renderer probe failed: {arguments[0]}")
    return completed.stdout


def _capability_present(capability: str, help_output: str) -> bool:
    return (
        re.search(
            rf"(?<![A-Za-z0-9_-]){re.escape(capability)}(?![A-Za-z0-9_-])",
            help_output,
        )
        is not None
    )


def _version_tuple(value: str) -> tuple[int, int, int]:
    if _VERSION_NUMBER_PATTERN.fullmatch(value) is None:
        raise ValueError(f"invalid macOS version: {value}")
    components = [int(component, 10) for component in value.split(".")]
    return tuple((components + [0, 0])[:3])
