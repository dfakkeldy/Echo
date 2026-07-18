"""Installation, publication, and read-only verification of content-addressed
Echo renderers."""

from __future__ import annotations

import hashlib
import os
import platform
import re
import shutil
import stat
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from echo_renderer.git_state import ApprovedWorktree
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
from echo_renderer.lease import LeaseSet, canonical_lease_root
from echo_renderer.model_policy import read_model_policy


_EXECUTABLE_NAME = "echo-cli"
_RESOURCES_NAME = "EchoNarrationResources"
_MANIFEST_NAME = "renderer-manifest.json"
_TOP_LEVEL_NAMES = {_EXECUTABLE_NAME, _RESOURCES_NAME, _MANIFEST_NAME}
_MAKE = "/usr/bin/make"
_ECHO_CLI_MAKE_TARGET = "echo-cli"
_BUILD_OUTPUT_RELATIVE = Path(".build") / "cli"
_BUILD_PRODUCTS_RELATIVE = Path("Build") / "Products" / "Release"
_STAGING_PREFIX = "echo-renderer-staging-"
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


@dataclass(frozen=True)
class InstallRequest:
    installer_worktree: Path
    installer_sha: str
    source_worktree: Path
    source_sha: str
    renderer_root: Path
    build_gate: Path
    promote: bool = False


@dataclass(frozen=True)
class InstallResult:
    verified: VerifiedRenderer
    selector_updated: bool


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

    def install(self, request: InstallRequest) -> InstallResult:
        """Build, stage, verify, and atomically publish one renderer package.

        Follows the leased installation transaction exactly: attest both
        worktrees, lease the installer root, source root, and build output;
        re-attest; run the build gate then ``make echo-cli``; stage a copy of
        the executable and resources beside the renderer root while the
        build-output lease is held; probe the staged CLI; extract the model
        policy; require the staged resources to completely match the build
        output before the manifest can describe them; write the canonical
        manifest; re-attest once more; verify the staged package; hash the
        manifest; and atomically publish it to ``<source SHA>/<manifest
        SHA>``. All three leases are held until publication completes.
        """
        resolved_request_root = _require_canonical_directory(
            request.renderer_root, "install request renderer root"
        )
        if resolved_request_root != self.renderer_root:
            raise ValueError(
                "install request renderer root does not match this store's "
                "renderer root"
            )

        installer_attested = ApprovedWorktree.attest(
            request.installer_worktree, request.installer_sha
        )
        source_attested = ApprovedWorktree.attest(
            request.source_worktree, request.source_sha
        )

        build_output_root = request.source_worktree / _BUILD_OUTPUT_RELATIVE
        lease = LeaseSet.acquire(
            lock_root=canonical_lease_root(),
            resources=(
                request.installer_worktree,
                request.source_worktree,
                build_output_root,
            ),
        )
        staging: Path | None = None
        try:
            installer_attested.reattest()
            source_attested.reattest()

            _run_build_command(
                self._runner,
                [str(request.build_gate), "--wait"],
                step="renderer build gate",
            )
            _run_build_command(
                self._runner,
                [_MAKE, "-C", str(request.source_worktree), _ECHO_CLI_MAKE_TARGET],
                step="renderer build",
            )

            build_products = build_output_root / _BUILD_PRODUCTS_RELATIVE
            build_executable = build_products / _EXECUTABLE_NAME
            build_resources = build_products / _RESOURCES_NAME

            staging = Path(
                tempfile.mkdtemp(dir=self.renderer_root.parent, prefix=_STAGING_PREFIX)
            )
            lease.assert_held()

            staged_executable = _copy_regular_file(
                build_executable, staging / _EXECUTABLE_NAME, mode=0o755
            )
            staged_resources = _copy_resource_tree(
                build_resources, staging / _RESOURCES_NAME
            )
            _fsync_directory(staging)

            probe = probe_release_cli(
                staged_executable, staged_resources, runner=self._runner
            )
            model_policy = read_model_policy(request.source_worktree)

            # Independently recompute both digests now, so an incomplete
            # staged copy cannot describe itself as complete: comparing the
            # staged copy against itself would let a silently dropped file
            # go unnoticed.
            build_resource_identity = identify_resource_tree(build_resources)
            staged_resource_identity = identify_resource_tree(staged_resources)
            if staged_resource_identity != build_resource_identity:
                raise ValueError(
                    "staged resources do not completely match the build "
                    f"output: staged={staged_resource_identity} "
                    f"build={build_resource_identity}"
                )

            manifest = RendererManifest(
                schema_version=1,
                echo_source_sha=request.source_sha,
                installer_source_sha=request.installer_sha,
                executable_path=_EXECUTABLE_NAME,
                executable=identify_regular_file(staged_executable),
                resources_path=_RESOURCES_NAME,
                resources=staged_resource_identity,
                render_version=probe.render_version,
                build_configuration=probe.build_configuration,
                architectures=tuple(probe.architectures),
                minimum_macos_version=probe.minimum_macos_version,
                model_policy=model_policy,
                capabilities=tuple(probe.capabilities),
            )
            manifest_data = canonical_json_bytes(manifest_payload(manifest))
            _write_regular_file(staging / _MANIFEST_NAME, manifest_data)
            _fsync_directory(staging)

            installer_attested.reattest()
            source_attested.reattest()

            _verify_staged_package(staging, expected_source_sha=request.source_sha)

            manifest_sha = hashlib.sha256(manifest_data).hexdigest()
            verified = self._publish_staged_package(
                staging, request.source_sha, manifest_sha
            )
            staging = None
        finally:
            if staging is not None:
                _remove_tree(staging)
            lease.close()

        selector_updated = False
        if request.promote:
            self.promote(request.source_sha, verified.manifest_sha)
            selector_updated = True

        return InstallResult(verified=verified, selector_updated=selector_updated)

    def _publish_staged_package(
        self, staging: Path, source_sha: str, manifest_sha: str
    ) -> VerifiedRenderer:
        """Atomically publish staging, or confirm an existing identical package."""
        source_dir = self.renderer_root / source_sha
        source_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination = source_dir / manifest_sha
        if destination.exists():
            try:
                verified = verify_build_identity(
                    destination,
                    expected_source_sha=source_sha,
                    expected_manifest_sha=manifest_sha,
                )
            except ValueError as error:
                raise ValueError(
                    "refusing to overwrite an existing renderer package that "
                    f"differs from the newly staged package: {destination}"
                ) from error
            _remove_tree(staging)
            return verified

        os.rename(staging, destination)
        _fsync_directory(source_dir)
        _fsync_directory(self.renderer_root)
        return verify_build_identity(
            destination,
            expected_source_sha=source_sha,
            expected_manifest_sha=manifest_sha,
        )

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


def _run_build_command(runner: Callable, arguments: list[str], *, step: str) -> None:
    """Run one gate or build subprocess as an argument array; never a shell."""
    try:
        completed = runner(arguments, check=False, capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f"cannot run {step}: {arguments[0]}") from error
    if completed.returncode != 0:
        raise ValueError(f"{step} failed: {' '.join(arguments)}")


def _copy_regular_file(source: Path, destination: Path, *, mode: int) -> Path:
    """Copy one regular, non-symlink file, fsyncing its bytes before returning."""
    read_flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        read_flags |= os.O_NOFOLLOW
    try:
        source_fd = os.open(source, read_flags)
    except OSError as error:
        raise ValueError(f"cannot open build output file: {source}") from error

    destination_fd = -1
    try:
        source_metadata = os.fstat(source_fd)
        if not stat.S_ISREG(source_metadata.st_mode):
            raise ValueError(f"build output file must be a regular file: {source}")

        write_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            write_flags |= os.O_NOFOLLOW
        destination_fd = os.open(destination, write_flags, mode)
        with os.fdopen(source_fd, "rb") as source_handle:
            source_fd = -1
            with os.fdopen(destination_fd, "wb") as destination_handle:
                destination_fd = -1
                for chunk in iter(lambda: source_handle.read(1024 * 1024), b""):
                    destination_handle.write(chunk)
                destination_handle.flush()
                os.fsync(destination_handle.fileno())
    except OSError as error:
        raise ValueError(
            f"cannot copy build output file: {source} -> {destination}"
        ) from error
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        if source_fd >= 0:
            os.close(source_fd)
    os.chmod(destination, mode)
    return destination


def _copy_resource_tree(source: Path, destination: Path) -> Path:
    """Copy a link-free resource tree into staging, fsyncing files and directories."""
    try:
        root_metadata = source.lstat()
    except OSError as error:
        raise ValueError(f"cannot inspect build resources: {source}") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ValueError(f"expected a regular non-link resource directory: {source}")

    def visit(current_source: Path, current_destination: Path) -> None:
        try:
            current_destination.mkdir(mode=0o700)
        except OSError as error:
            raise ValueError(
                f"cannot create staged resource directory: {current_destination}"
            ) from error
        try:
            entries = list(os.scandir(current_source))
        except OSError as error:
            raise ValueError(
                f"cannot read build resource directory: {current_source}"
            ) from error
        for entry in entries:
            entry_path = Path(entry.path)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise ValueError(
                    f"cannot inspect build resource entry: {entry_path}"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"build resource links are not allowed: {entry_path}")
            destination_entry = current_destination / entry.name
            if stat.S_ISDIR(metadata.st_mode):
                visit(entry_path, destination_entry)
            elif stat.S_ISREG(metadata.st_mode):
                _copy_regular_file(entry_path, destination_entry, mode=0o644)
            else:
                raise ValueError(
                    f"special build resource files are not allowed: {entry_path}"
                )
        _fsync_directory(current_destination)

    visit(source, destination)
    return destination


def _write_regular_file(path: Path, data: bytes, *, mode: int = 0o644) -> None:
    """Write one new regular file and fsync its bytes before returning."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        file_descriptor = os.open(path, flags, mode)
    except OSError as error:
        raise ValueError(f"cannot create staged file: {path}") from error
    try:
        with os.fdopen(file_descriptor, "wb") as handle:
            file_descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        raise ValueError(f"cannot write staged file: {path}") from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
    os.chmod(path, mode)


def _fsync_directory(path: Path) -> None:
    """Fsync one directory's entries so a preceding write or rename is durable."""
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        directory_fd = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"cannot open directory to fsync: {path}") from error
    try:
        os.fsync(directory_fd)
    except OSError as error:
        raise ValueError(f"cannot fsync directory: {path}") from error
    finally:
        os.close(directory_fd)


def _remove_tree(path: Path) -> None:
    """Best-effort recursive removal of one staging directory."""
    shutil.rmtree(path, ignore_errors=True)


def _verify_staged_package(staging: Path, *, expected_source_sha: str) -> RendererManifest:
    """Validate one staged package's layout and content before it is named by hash.

    Mirrors ``verify_build_identity``'s content checks, but staging is not yet
    named by its manifest hash, so directory-name-to-SHA binding is checked
    separately after publication instead of here.
    """
    try:
        entries = list(os.scandir(staging))
    except OSError as error:
        raise ValueError(f"cannot inspect staged renderer package: {staging}") from error
    entry_names = {entry.name for entry in entries}
    if len(entries) != len(_TOP_LEVEL_NAMES) or entry_names != _TOP_LEVEL_NAMES:
        raise ValueError("staged renderer package has unexpected top-level entries")

    executable = staging / _EXECUTABLE_NAME
    resources = staging / _RESOURCES_NAME
    manifest_path = staging / _MANIFEST_NAME
    manifest_data = _read_regular_file_once(manifest_path, "staged renderer manifest")
    manifest = parse_manifest(manifest_data)
    if manifest_data != canonical_json_bytes(manifest_payload(manifest)):
        raise ValueError("staged renderer manifest is not canonically encoded")
    if manifest.echo_source_sha != expected_source_sha:
        raise ValueError("staged renderer manifest source SHA does not match the request")
    if manifest.executable_path != _EXECUTABLE_NAME:
        raise ValueError(
            "staged renderer manifest executable path does not match the layout"
        )
    if manifest.resources_path != _RESOURCES_NAME:
        raise ValueError(
            "staged renderer manifest resources path does not match the layout"
        )
    if identify_regular_file(executable) != manifest.executable:
        raise ValueError("staged renderer executable identity does not match the manifest")
    if identify_resource_tree(resources) != manifest.resources:
        raise ValueError("staged renderer resource identity does not match the manifest")
    executable_mode = stat.S_IMODE(executable.lstat().st_mode)
    if executable_mode != 0o755:
        raise ValueError("staged renderer executable must be mode 0755")
    return manifest
