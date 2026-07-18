from __future__ import annotations

import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence
from unittest import mock

from echo_renderer.cli import build_parser, main
from echo_renderer.identity import FileIdentity, ModelPolicy, RendererManifest, ResourceTreeIdentity
from echo_renderer.lease import TEMPORARY_FAILURE
from echo_renderer.store import (
    InstallRequest,
    InstallResult,
    RendererIncompatibleError,
    RepairMismatchError,
    VerifiedRenderer,
)


SOURCE_SHA = "ab" * 20
INSTALLER_SHA = "cd" * 20
MANIFEST_SHA = "12" * 32

_USAGE_EXIT_CODE = 64


def _manifest(*, installer_source_sha: str = INSTALLER_SHA) -> RendererManifest:
    return RendererManifest(
        schema_version=1,
        echo_source_sha=SOURCE_SHA,
        installer_source_sha=installer_source_sha,
        executable_path="echo-cli",
        executable=FileIdentity(sha256="ef" * 32, byte_count=1024),
        resources_path="EchoNarrationResources",
        resources=ResourceTreeIdentity(sha256="34" * 32, regular_file_count=7),
        render_version=15,
        build_configuration="Release",
        architectures=("arm64",),
        minimum_macos_version="15.0",
        model_policy=ModelPolicy(revision="56" * 20, expected_byte_count=163_234_740),
        capabilities=("--cover", "verify-sidecar"),
    )


def _verified(build_root: Path, *, manifest: RendererManifest | None = None) -> VerifiedRenderer:
    manifest = manifest or _manifest()
    return VerifiedRenderer(
        source_sha=SOURCE_SHA,
        manifest_sha=MANIFEST_SHA,
        build_root=build_root,
        executable=build_root / "echo-cli",
        resources=build_root / "EchoNarrationResources",
        manifest=manifest,
    )


@dataclass
class _Call:
    method: str
    args: tuple[object, ...]


class FakeStore:
    """Records dispatch and returns scripted results/errors per method."""

    last_instance: "FakeStore | None" = None

    def __init__(self, renderer_root: Path) -> None:
        self.renderer_root = renderer_root
        self.calls: list[_Call] = []
        FakeStore.last_instance = self

    # Class-level scripting hooks, reset per test via setUp.
    install_result: InstallResult | None = None
    install_error: BaseException | None = None
    verify_result: VerifiedRenderer | None = None
    verify_error: BaseException | None = None
    promote_result: Path | None = None
    promote_error: BaseException | None = None
    repair_result: InstallResult | None = None
    repair_error: BaseException | None = None

    def install(self, request: InstallRequest) -> InstallResult:
        self.calls.append(_Call("install", (request,)))
        if type(self).install_error is not None:
            raise type(self).install_error
        assert type(self).install_result is not None
        return type(self).install_result

    def verify(self, source_sha: str, manifest_sha: str) -> VerifiedRenderer:
        self.calls.append(_Call("verify", (source_sha, manifest_sha)))
        if type(self).verify_error is not None:
            raise type(self).verify_error
        assert type(self).verify_result is not None
        return type(self).verify_result

    def promote(self, source_sha: str, manifest_sha: str) -> Path:
        self.calls.append(_Call("promote", (source_sha, manifest_sha)))
        if type(self).promote_error is not None:
            raise type(self).promote_error
        assert type(self).promote_result is not None
        return type(self).promote_result

    def repair(self, request: InstallRequest, manifest_sha: str) -> InstallResult:
        self.calls.append(_Call("repair", (request, manifest_sha)))
        if type(self).repair_error is not None:
            raise type(self).repair_error
        assert type(self).repair_result is not None
        return type(self).repair_result


class CLITestCase(unittest.TestCase):
    def setUp(self) -> None:
        for attribute in (
            "install_result",
            "install_error",
            "verify_result",
            "verify_error",
            "promote_result",
            "promote_error",
            "repair_result",
            "repair_error",
        ):
            setattr(FakeStore, attribute, None)
        FakeStore.last_instance = None

    def run_main(self, argv: Sequence[str]) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = main(list(argv), store_factory=FakeStore)
        return code, stdout.getvalue(), stderr.getvalue()

    def assert_usage_error(self, argv: Sequence[str]) -> str:
        """Usage errors exit via argparse's own SystemExit, never a return."""
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                main(list(argv), store_factory=FakeStore)
        self.assertEqual(raised.exception.code, _USAGE_EXIT_CODE)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIsNone(FakeStore.last_instance)
        return stderr.getvalue()


class ParserTests(unittest.TestCase):
    def test_builds_a_parser_with_all_four_subcommands(self) -> None:
        parser = build_parser()
        subcommands = {
            action.dest: action.choices
            for action in parser._subparsers._group_actions  # noqa: SLF001
            if action.dest == "command"
        }
        self.assertIn("command", subcommands)
        self.assertEqual(
            set(subcommands["command"]), {"install", "verify", "promote", "repair"}
        )

    def test_install_requires_installer_and_source_pairs(self) -> None:
        parser = build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["install", "--installer-sha", "aa" * 20])

    def test_renderer_root_default_expands_to_application_support(self) -> None:
        parser = build_parser()
        args = parser.parse_args(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )
        self.assertEqual(
            args.renderer_root,
            Path("~/Library/Application Support/Echo/Renderers").expanduser(),
        )

    def test_build_gate_default_uses_home_env(self) -> None:
        with mock.patch.dict("os.environ", {"HOME": "/Users/fixture-home"}):
            parser = build_parser()
            args = parser.parse_args(
                [
                    "install",
                    "--installer-worktree",
                    "/tmp/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/tmp/source",
                    "--source-sha",
                    SOURCE_SHA,
                ]
            )
        self.assertEqual(
            args.build_gate,
            Path("/Users/fixture-home/.claude/bin/xcode-build-gate.sh"),
        )

    def test_renderer_root_can_be_overridden(self) -> None:
        parser = build_parser()
        args = parser.parse_args(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
                "--renderer-root",
                "/tmp/custom-renderers",
            ]
        )
        self.assertEqual(args.renderer_root, Path("/tmp/custom-renderers"))


class SHAValidationTests(CLITestCase):
    """Bad SHAs and bad subcommands are usage errors (64), rejected by the
    parser itself -- before ``store_factory`` is ever called -- via
    ``SystemExit``, argparse's own control flow for parse failures."""

    def test_rejects_a_short_source_sha(self) -> None:
        stderr = self.assert_usage_error(
            ["verify", "--source-sha", "ab", "--manifest-sha", MANIFEST_SHA]
        )
        self.assertIn("error", stderr.lower())

    def test_rejects_an_uppercase_source_sha(self) -> None:
        self.assert_usage_error(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA.upper(),
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )

    def test_rejects_a_short_manifest_sha(self) -> None:
        self.assert_usage_error(
            ["verify", "--source-sha", SOURCE_SHA, "--manifest-sha", "ab" * 20]
        )

    def test_rejects_a_64_char_value_where_a_40_char_sha_is_required(self) -> None:
        self.assert_usage_error(
            ["verify", "--source-sha", MANIFEST_SHA, "--manifest-sha", MANIFEST_SHA]
        )

    def test_missing_subcommand_is_a_usage_error(self) -> None:
        self.assert_usage_error([])

    def test_unknown_subcommand_is_a_usage_error(self) -> None:
        self.assert_usage_error(["nonexistent"])


class VerifyDispatchTests(CLITestCase):
    def test_verify_dispatches_to_the_injected_store_and_prints_sorted_fields(self) -> None:
        build_root = Path("/renderers") / SOURCE_SHA / MANIFEST_SHA
        FakeStore.verify_result = _verified(build_root)

        code, stdout, stderr = self.run_main(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
                "--renderer-root",
                "/renderers",
            ]
        )

        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        self.assertEqual(FakeStore.last_instance.renderer_root, Path("/renderers"))
        self.assertEqual(
            FakeStore.last_instance.calls,
            [_Call("verify", (SOURCE_SHA, MANIFEST_SHA))],
        )
        lines = stdout.strip("\n").split("\n")
        self.assertEqual(lines, sorted(lines))
        expected = {
            "executableSHA256": "ef" * 32,
            "installedPath": str(build_root),
            "installerSourceSHA": INSTALLER_SHA,
            "manifestSHA256": MANIFEST_SHA,
            "resourcesSHA256": "34" * 32,
            "sourceSHA": SOURCE_SHA,
        }
        actual = dict(line.split("=", 1) for line in lines)
        self.assertEqual(actual, expected)
        self.assertNotIn("selectorUpdated", actual)

    def test_verify_maps_corruption_failure_to_exit_65(self) -> None:
        FakeStore.verify_error = ValueError("renderer manifest bytes do not match")

        code, stdout, stderr = self.run_main(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )

        self.assertEqual(code, 65)
        self.assertEqual(stdout, "")
        self.assertIn("renderer manifest bytes do not match", stderr)

    def test_verify_maps_incompatibility_to_exit_69(self) -> None:
        FakeStore.verify_error = RendererIncompatibleError(
            "renderer requires a newer macOS version than this host"
        )

        code, stdout, stderr = self.run_main(
            [
                "verify",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )

        self.assertEqual(code, 69)
        self.assertEqual(stdout, "")
        self.assertIn("newer macOS version", stderr)

    def test_verify_passes_through_lease_contention_system_exit(self) -> None:
        FakeStore.verify_error = SystemExit(TEMPORARY_FAILURE)

        with self.assertRaises(SystemExit) as raised:
            self.run_main(
                ["verify", "--source-sha", SOURCE_SHA, "--manifest-sha", MANIFEST_SHA]
            )
        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)

    def test_verify_against_a_real_store_hitting_a_nonexistent_root_exits_65(
        self,
    ) -> None:
        stdout_buffer = io.StringIO()
        stderr_buffer = io.StringIO()
        with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
            code = main(
                [
                    "verify",
                    "--source-sha",
                    SOURCE_SHA,
                    "--manifest-sha",
                    MANIFEST_SHA,
                    "--renderer-root",
                    "/nonexistent/echo-renderer-cli-test-root",
                ]
            )
        self.assertEqual(code, 65)
        self.assertEqual(stdout_buffer.getvalue(), "")
        self.assertNotEqual(stderr_buffer.getvalue(), "")


class PromoteDispatchTests(CLITestCase):
    def test_promote_dispatches_promote_then_verify_and_omits_selector_updated(
        self,
    ) -> None:
        build_root = Path("/renderers") / SOURCE_SHA / MANIFEST_SHA
        FakeStore.promote_result = build_root.parent / "approved-renderer.json"
        FakeStore.verify_result = _verified(build_root)

        code, stdout, stderr = self.run_main(
            [
                "promote",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
                "--renderer-root",
                "/renderers",
            ]
        )

        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        self.assertEqual(
            [call.method for call in FakeStore.last_instance.calls],
            ["promote", "verify"],
        )
        self.assertNotIn("selectorUpdated", stdout)
        self.assertIn(f"sourceSHA={SOURCE_SHA}", stdout)

    def test_promote_maps_corruption_failure_to_exit_65(self) -> None:
        FakeStore.promote_error = ValueError("bad selector")

        code, _, stderr = self.run_main(
            ["promote", "--source-sha", SOURCE_SHA, "--manifest-sha", MANIFEST_SHA]
        )

        self.assertEqual(code, 65)
        self.assertIn("bad selector", stderr)


class InstallDispatchTests(CLITestCase):
    def test_install_builds_a_request_from_flags_and_prints_selector_updated(
        self,
    ) -> None:
        build_root = Path("/renderers") / SOURCE_SHA / MANIFEST_SHA
        FakeStore.install_result = InstallResult(
            verified=_verified(build_root), selector_updated=True
        )

        code, stdout, stderr = self.run_main(
            [
                "install",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
                "--renderer-root",
                "/renderers",
                "--build-gate",
                "/work/gate.sh",
                "--promote",
            ]
        )

        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        [call] = FakeStore.last_instance.calls
        self.assertEqual(call.method, "install")
        (request,) = call.args
        self.assertEqual(
            request,
            InstallRequest(
                installer_worktree=Path("/work/installer"),
                installer_sha=INSTALLER_SHA,
                source_worktree=Path("/work/source"),
                source_sha=SOURCE_SHA,
                renderer_root=Path("/renderers"),
                build_gate=Path("/work/gate.sh"),
                promote=True,
            ),
        )
        self.assertIn("selectorUpdated=true", stdout)

    def test_install_without_promote_flag_defaults_promote_false(self) -> None:
        build_root = Path("/renderers") / SOURCE_SHA / MANIFEST_SHA
        FakeStore.install_result = InstallResult(
            verified=_verified(build_root), selector_updated=False
        )

        code, stdout, _ = self.run_main(
            [
                "install",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
                "--renderer-root",
                "/renderers",
                "--build-gate",
                "/work/gate.sh",
            ]
        )

        self.assertEqual(code, 0)
        [call] = FakeStore.last_instance.calls
        (request,) = call.args
        self.assertFalse(request.promote)
        self.assertIn("selectorUpdated=false", stdout)

    def test_install_maps_incompatibility_to_exit_69(self) -> None:
        FakeStore.install_error = RendererIncompatibleError(
            "echo-cli narrate help is missing capabilities: ['--cover']"
        )

        code, stdout, stderr = self.run_main(
            [
                "install",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
            ]
        )

        self.assertEqual(code, 69)
        self.assertEqual(stdout, "")
        self.assertIn("missing capabilities", stderr)

    def test_install_passes_through_lease_contention_system_exit(self) -> None:
        FakeStore.install_error = SystemExit(TEMPORARY_FAILURE)

        with self.assertRaises(SystemExit) as raised:
            self.run_main(
                [
                    "install",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                ]
            )
        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)


class RepairDispatchTests(CLITestCase):
    def test_repair_builds_a_request_with_manifest_sha_and_promote_false(self) -> None:
        build_root = Path("/renderers") / SOURCE_SHA / MANIFEST_SHA
        FakeStore.repair_result = InstallResult(
            verified=_verified(build_root), selector_updated=False
        )

        code, stdout, stderr = self.run_main(
            [
                "repair",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
                "--renderer-root",
                "/renderers",
                "--build-gate",
                "/work/gate.sh",
            ]
        )

        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")
        [call] = FakeStore.last_instance.calls
        self.assertEqual(call.method, "repair")
        request, manifest_sha = call.args
        self.assertEqual(manifest_sha, MANIFEST_SHA)
        self.assertFalse(request.promote)
        self.assertIn("selectorUpdated=false", stdout)

    def test_repair_has_no_promote_flag_in_its_contract(self) -> None:
        parser = build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(
                [
                    "repair",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--manifest-sha",
                    MANIFEST_SHA,
                    "--promote",
                ]
            )

    def test_repair_maps_corruption_failure_to_exit_65(self) -> None:
        FakeStore.repair_error = ValueError("non-resumable manifest")

        code, stdout, stderr = self.run_main(
            [
                "repair",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )

        self.assertEqual(code, 65)
        self.assertEqual(stdout, "")
        self.assertIn("non-resumable manifest", stderr)

    def test_repair_passes_through_lease_contention_system_exit(self) -> None:
        FakeStore.repair_error = SystemExit(TEMPORARY_FAILURE)

        with self.assertRaises(SystemExit) as raised:
            self.run_main(
                [
                    "repair",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--manifest-sha",
                    MANIFEST_SHA,
                ]
            )
        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)


class OSErrorClassificationTests(CLITestCase):
    """OS-level failures (e.g. the lease layer failing to create or lock
    files under its lock root) must exit with a classified code and a
    message on stderr, never escape as a traceback with exit 1."""

    def test_install_oserror_maps_to_exit_74(self) -> None:
        FakeStore.install_error = OSError("flock failed on the lease root")

        with tempfile.TemporaryDirectory() as tmp:
            code, stdout, stderr = self.run_main(
                [
                    "install",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--renderer-root",
                    tmp,
                    "--build-gate",
                    "/work/gate.sh",
                ]
            )

        self.assertEqual(code, 74)
        self.assertEqual(stdout, "")
        self.assertIn("flock failed on the lease root", stderr)

    def test_repair_oserror_maps_to_exit_74(self) -> None:
        FakeStore.repair_error = OSError("cannot create lease lock file")

        with tempfile.TemporaryDirectory() as tmp:
            code, stdout, stderr = self.run_main(
                [
                    "repair",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--manifest-sha",
                    MANIFEST_SHA,
                    "--renderer-root",
                    tmp,
                    "--build-gate",
                    "/work/gate.sh",
                ]
            )

        self.assertEqual(code, 74)
        self.assertEqual(stdout, "")
        self.assertIn("cannot create lease lock file", stderr)


class RepairMismatchReportingTests(CLITestCase):
    def test_repair_mismatch_emits_structured_hash_lines_on_stderr(self) -> None:
        rebuilt_sha = "fe" * 32
        FakeStore.repair_error = RepairMismatchError(
            "renderer repair could not restore the requested identity",
            requested_manifest_sha=MANIFEST_SHA,
            rebuilt_manifest_sha=rebuilt_sha,
        )

        code, stdout, stderr = self.run_main(
            [
                "repair",
                "--installer-worktree",
                "/work/installer",
                "--installer-sha",
                INSTALLER_SHA,
                "--source-worktree",
                "/work/source",
                "--source-sha",
                SOURCE_SHA,
                "--manifest-sha",
                MANIFEST_SHA,
            ]
        )

        self.assertEqual(code, 65)
        self.assertEqual(stdout, "")
        self.assertIn(f"requestedManifestSHA256={MANIFEST_SHA}\n", stderr)
        self.assertIn(f"rebuiltManifestSHA256={rebuilt_sha}\n", stderr)
        self.assertIn("could not restore the requested identity", stderr)


class RendererRootCreationTests(CLITestCase):
    """A fresh machine has no ``~/Library/Application Support/Echo/Renderers``
    yet, so the very first ``install`` must not die on that alone.
    ``install``/``repair`` create a missing renderer root before
    constructing the store; ``verify``/``promote`` deliberately do not --
    a missing root there honestly means "nothing installed" (exit 65).
    """

    def test_install_creates_a_missing_renderer_root_before_constructing_the_store(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            renderer_root = Path(tmp) / "nested" / "renderers"
            self.assertFalse(renderer_root.exists())
            build_root = renderer_root / SOURCE_SHA / MANIFEST_SHA
            FakeStore.install_result = InstallResult(
                verified=_verified(build_root), selector_updated=False
            )

            code, stdout, stderr = self.run_main(
                [
                    "install",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--renderer-root",
                    str(renderer_root),
                    "--build-gate",
                    "/work/gate.sh",
                ]
            )

            self.assertEqual(code, 0)
            self.assertEqual(stderr, "")
            self.assertTrue(renderer_root.is_dir())
            self.assertFalse(renderer_root.is_symlink())
            self.assertEqual(FakeStore.last_instance.renderer_root, renderer_root)

    def test_repair_creates_a_missing_renderer_root_before_constructing_the_store(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            renderer_root = Path(tmp) / "nested" / "renderers"
            self.assertFalse(renderer_root.exists())
            build_root = renderer_root / SOURCE_SHA / MANIFEST_SHA
            FakeStore.repair_result = InstallResult(
                verified=_verified(build_root), selector_updated=False
            )

            code, stdout, stderr = self.run_main(
                [
                    "repair",
                    "--installer-worktree",
                    "/work/installer",
                    "--installer-sha",
                    INSTALLER_SHA,
                    "--source-worktree",
                    "/work/source",
                    "--source-sha",
                    SOURCE_SHA,
                    "--manifest-sha",
                    MANIFEST_SHA,
                    "--renderer-root",
                    str(renderer_root),
                    "--build-gate",
                    "/work/gate.sh",
                ]
            )

            self.assertEqual(code, 0)
            self.assertEqual(stderr, "")
            self.assertTrue(renderer_root.is_dir())
            self.assertFalse(renderer_root.is_symlink())
            self.assertEqual(FakeStore.last_instance.renderer_root, renderer_root)

    def test_verify_against_a_real_store_with_a_missing_root_does_not_create_it(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            renderer_root = Path(tmp) / "nested" / "renderers"
            self.assertFalse(renderer_root.exists())

            stdout_buffer = io.StringIO()
            stderr_buffer = io.StringIO()
            with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
                code = main(
                    [
                        "verify",
                        "--source-sha",
                        SOURCE_SHA,
                        "--manifest-sha",
                        MANIFEST_SHA,
                        "--renderer-root",
                        str(renderer_root),
                    ]
                )

            self.assertEqual(code, 65)
            self.assertEqual(stdout_buffer.getvalue(), "")
            self.assertFalse(
                renderer_root.exists(),
                "verify must never create the renderer root it was asked "
                "to check -- a missing root there is a real answer (exit "
                "65: nothing installed), not something to paper over",
            )

    def test_install_against_a_real_store_with_root_occupied_by_a_file_fails_closed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            renderer_root = Path(tmp) / "renderers"
            renderer_root.write_text("not a directory")
            self.assertTrue(renderer_root.is_file())

            stdout_buffer = io.StringIO()
            stderr_buffer = io.StringIO()
            with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
                code = main(
                    [
                        "install",
                        "--installer-worktree",
                        "/work/installer",
                        "--installer-sha",
                        INSTALLER_SHA,
                        "--source-worktree",
                        "/work/source",
                        "--source-sha",
                        SOURCE_SHA,
                        "--renderer-root",
                        str(renderer_root),
                    ]
                )

            self.assertEqual(code, 65)
            self.assertEqual(stdout_buffer.getvalue(), "")
            self.assertTrue(
                renderer_root.is_file(),
                "install must never delete or replace a file occupying the "
                "renderer root path -- it must fail closed instead",
            )
            self.assertEqual(renderer_root.read_text(), "not a directory")


class RelativeRendererRootTests(unittest.TestCase):
    """A relative --renderer-root is always rejected by the store's
    canonical-path check, so the CLI must not first mkdir it into the
    current working directory and leave a stray directory behind."""

    def test_a_relative_renderer_root_is_rejected_without_creating_a_directory(
        self,
    ) -> None:
        original_cwd = os.getcwd()
        self.addCleanup(os.chdir, original_cwd)
        with tempfile.TemporaryDirectory() as tmp:
            os.chdir(tmp)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                # Deliberately the REAL RendererStore: the contract under
                # test is "reject without side effects", end to end.
                code = main(
                    [
                        "install",
                        "--installer-worktree",
                        "/work/installer",
                        "--installer-sha",
                        INSTALLER_SHA,
                        "--source-worktree",
                        "/work/source",
                        "--source-sha",
                        SOURCE_SHA,
                        "--renderer-root",
                        "relative/renderers",
                        "--build-gate",
                        "/work/gate.sh",
                    ]
                )
            os.chdir(original_cwd)

            self.assertEqual(code, 65)
            self.assertIn("renderer store root", stderr.getvalue())
            self.assertFalse((Path(tmp) / "relative").exists())


class TestCIWorkflowRunsInstallerTestsFirst(unittest.TestCase):
    """Contract test: CI must run the fast, no-Xcode renderer installer suite
    before any Xcode-heavy step, and must keep proving echo-cli still compiles.

    This locks in Task 8 (CI integration): a step running
    `make renderer-install-test` gives fast signal (seconds, no simulator) on
    every push/PR, ahead of the expensive xcodebuild steps. Parsed as plain
    text so this test has no YAML-library dependency (stdlib only).
    """

    def _read_ci_workflow(self) -> str:
        # Resolve relative to this test file's location, not the CWD, so the
        # test is stable regardless of where the suite is invoked from:
        # tests/ -> echo_renderer/ -> Scripts/ -> repo root.
        repo_root = Path(__file__).resolve().parents[3]
        ci_path = repo_root / ".github" / "workflows" / "ci.yml"
        return ci_path.read_text()

    def test_renderer_install_test_runs_before_xcodebuild_steps(self) -> None:
        text = self._read_ci_workflow()

        self.assertIn(
            "make renderer-install-test",
            text,
            "ci.yml must invoke `make renderer-install-test` as a CI step.",
        )

        renderer_step_index = text.index("make renderer-install-test")
        # WARNING: this anchors on the FIRST "xcodebuild" occurrence anywhere
        # in ci.yml -- a comment mentioning xcodebuild before the renderer
        # step trips the ordering assertion below just like a real step.
        self.assertIn(
            "xcodebuild",
            text,
            "ci.yml no longer mentions xcodebuild at all; this contract "
            "test's ordering anchor vanished -- update it deliberately.",
        )
        first_xcodebuild_index = text.index("xcodebuild")

        self.assertLess(
            renderer_step_index,
            first_xcodebuild_index,
            "The renderer installer tests must run before the first "
            "xcodebuild-based step, so CI gets fast (no-Xcode) signal first.",
        )

    def test_echo_cli_compilation_proof_is_retained(self) -> None:
        text = self._read_ci_workflow()

        self.assertIn(
            "-scheme echo-cli",
            text,
            "ci.yml must retain the existing echo-cli xcodebuild compilation step.",
        )


if __name__ == "__main__":
    unittest.main()
