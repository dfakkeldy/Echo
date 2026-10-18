from __future__ import annotations

import hashlib
import os
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from echo_renderer.identity import (
    FileIdentity,
    ModelPolicy,
    RendererManifest,
    canonical_json_bytes,
    identify_regular_file,
    identify_resource_tree,
    manifest_payload,
)
from echo_renderer.store import (
    RendererProbe,
    RendererStore,
    VerifiedRenderer,
    probe_release_cli,
    verify_build_identity,
)


REQUIRED_NARRATE_CAPABILITIES = (
    "--cover",
    "--sidecar",
    "--voice",
    "--voice-plan",
    "--chapter-voice",
    "--db",
    "--work-dir",
    "--jobs",
    "--threads",
    "--resume",
    "--max-chapters",
    "--no-pronunciation-review",
)
REQUIRED_SUBCOMMAND_CAPABILITIES = (
    "export-blocks",
    "resolve-voice-plan",
    "verify-sidecar",
)
REQUIRED_CAPABILITIES = REQUIRED_NARRATE_CAPABILITIES + REQUIRED_SUBCOMMAND_CAPABILITIES


class ProbeRunner:
    def __init__(
        self,
        *,
        version: str = "ONNX rv15 (Release)\n",
        capabilities: tuple[str, ...] = REQUIRED_NARRATE_CAPABILITIES,
        subcommand_capabilities: tuple[str, ...] = REQUIRED_SUBCOMMAND_CAPABILITIES,
        architectures: tuple[str, ...] = (platform.machine(),),
        minimum_macos_version: str = "15.0",
    ) -> None:
        self.version = version
        self.capabilities = capabilities
        self.subcommand_capabilities = subcommand_capabilities
        self.architectures = architectures
        self.minimum_macos_version = minimum_macos_version
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []

    def __call__(
        self, arguments: list[str], **keywords: object
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append((tuple(arguments), dict(keywords)))
        if arguments[0] == "/usr/bin/lipo":
            stdout = " ".join(self.architectures) + "\n"
        elif arguments[0] == "/usr/bin/otool":
            stdout = (
                "Load command 10\n"
                "      cmd LC_BUILD_VERSION\n"
                "  cmdsize 32\n"
                " platform 1\n"
                f"    minos {self.minimum_macos_version}\n"
                "      sdk 26.0\n"
            )
        elif arguments[1:] == ["--version"]:
            stdout = self.version
        elif arguments[1:] == ["narrate", "--help"]:
            stdout = "USAGE: echo-cli narrate " + " ".join(self.capabilities) + "\n"
        elif len(arguments) == 3 and arguments[2] == "--help":
            subcommand = arguments[1]
            stdout = (
                f"USAGE: echo-cli {subcommand} --fixture\n"
                if subcommand in self.subcommand_capabilities
                else "USAGE: echo-cli narrate ...\n"
            )
        else:
            raise AssertionError(f"unexpected probe arguments: {arguments!r}")
        return subprocess.CompletedProcess(arguments, 0, stdout=stdout, stderr="")


class RendererPackageFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.renderer_root = (Path(self.temporary.name) / "renderers").resolve()
        self.renderer_root.mkdir()
        self.source_sha = "12" * 20
        self.installer_sha = "34" * 20
        self.source_root = self.renderer_root / self.source_sha
        self.source_root.mkdir()

        executable_bytes = b"Mach-O fixture bytes\n"
        resources: dict[str, bytes] = {
            "voices/default.json": b'{"voice":"am_michael"}\n',
            "phonemes.txt": b"fixture phonemes\n",
        }
        executable_identity = FileIdentity(
            sha256=hashlib.sha256(executable_bytes).hexdigest(),
            byte_count=len(executable_bytes),
        )

        resource_scratch = self.source_root / "resource-scratch"
        resource_scratch.mkdir()
        for relative_path, data in resources.items():
            destination = resource_scratch.joinpath(*relative_path.split("/"))
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        resource_identity = identify_resource_tree(resource_scratch)

        self.manifest = RendererManifest(
            schema_version=1,
            echo_source_sha=self.source_sha,
            installer_source_sha=self.installer_sha,
            executable_path="echo-cli",
            executable=executable_identity,
            resources_path="EchoNarrationResources",
            resources=resource_identity,
            render_version=15,
            build_configuration="Release",
            architectures=(platform.machine(),),
            minimum_macos_version="15.0",
            model_policy=ModelPolicy(
                revision="56" * 20,
                expected_byte_count=163_234_740,
            ),
            capabilities=REQUIRED_CAPABILITIES,
        )
        manifest_data = canonical_json_bytes(manifest_payload(self.manifest))
        self.manifest_sha = hashlib.sha256(manifest_data).hexdigest()
        self.build_root = self.source_root / self.manifest_sha
        self.build_root.mkdir()
        resource_scratch.rename(self.build_root / "EchoNarrationResources")
        self.executable = self.build_root / "echo-cli"
        self.executable.write_bytes(executable_bytes)
        self.executable.chmod(0o755)
        self.manifest_path = self.build_root / "renderer-manifest.json"
        self.manifest_path.write_bytes(manifest_data)
        self.runner = ProbeRunner()

    def replace_manifest_payload(self, payload: dict[str, object]) -> None:
        self.replace_manifest_data(canonical_json_bytes(payload))

    def replace_manifest_data(self, data: bytes) -> None:
        new_sha = hashlib.sha256(data).hexdigest()
        new_root = self.source_root / new_sha
        self.build_root.rename(new_root)
        self.manifest_sha = new_sha
        self.build_root = new_root
        self.executable = new_root / "echo-cli"
        self.manifest_path = new_root / "renderer-manifest.json"
        self.manifest_path.write_bytes(data)

    def verify_identity(self) -> VerifiedRenderer:
        return verify_build_identity(
            self.build_root,
            expected_source_sha=self.source_sha,
            expected_manifest_sha=self.manifest_sha,
        )


class BuildIdentityTests(RendererPackageFixture):
    def test_verifies_exact_layout_manifest_and_file_identities(self):
        verified = self.verify_identity()

        self.assertEqual(
            verified,
            VerifiedRenderer(
                source_sha=self.source_sha,
                manifest_sha=self.manifest_sha,
                build_root=self.build_root,
                executable=self.executable,
                resources=self.build_root / "EchoNarrationResources",
                manifest=self.manifest,
            ),
        )

    def test_rejects_wrong_source_or_manifest_directory_names(self):
        wrong_manifest_root = self.source_root / ("ab" * 32)
        self.build_root.rename(wrong_manifest_root)
        with self.assertRaises(ValueError):
            verify_build_identity(
                wrong_manifest_root,
                expected_source_sha=self.source_sha,
                expected_manifest_sha=self.manifest_sha,
            )

        wrong_source_root = self.renderer_root / ("cd" * 20)
        self.source_root.rename(wrong_source_root)
        wrong_build_root = wrong_source_root / wrong_manifest_root.name
        with self.assertRaises(ValueError):
            verify_build_identity(
                wrong_build_root,
                expected_source_sha=self.source_sha,
                expected_manifest_sha=wrong_manifest_root.name,
            )

    def test_rejects_manifest_bytes_with_the_wrong_hash(self):
        self.manifest_path.write_bytes(self.manifest_path.read_bytes() + b" ")

        with self.assertRaises(ValueError):
            self.verify_identity()

    def test_manifest_hash_and_parse_use_the_same_byte_snapshot(self):
        replacement_payload = manifest_payload(self.manifest)
        replacement_payload["installerSourceSHA"] = "78" * 20
        replacement_data = canonical_json_bytes(replacement_payload)

        def replace_manifest_after_identity(path: Path) -> FileIdentity:
            identity = identify_regular_file(path)
            if path == self.manifest_path:
                self.manifest_path.write_bytes(replacement_data)
            return identity

        with patch(
            "echo_renderer.store.identify_regular_file",
            side_effect=replace_manifest_after_identity,
        ):
            verified = self.verify_identity()

        self.assertEqual(verified.manifest, self.manifest)

    def test_rejects_duplicate_and_unknown_manifest_fields(self):
        original = self.manifest_path.read_bytes()
        duplicate = original[:-2] + b',"schemaVersion":1}\n'
        self.replace_manifest_data(duplicate)
        with self.assertRaises(ValueError):
            self.verify_identity()

        self.setUp()
        payload = manifest_payload(self.manifest)
        payload["unknown"] = True
        self.replace_manifest_payload(payload)
        with self.assertRaises(ValueError):
            self.verify_identity()

    def test_rejects_absolute_and_escaping_manifest_paths(self):
        for unsafe_path in ("/tmp/echo-cli", "../echo-cli"):
            with self.subTest(path=unsafe_path):
                payload = manifest_payload(self.manifest)
                payload["executablePath"] = unsafe_path
                self.replace_manifest_payload(payload)
                with self.assertRaises(ValueError):
                    self.verify_identity()
                self.setUp()

    def test_rejects_symlinked_package_components_and_resource_entries(self):
        executable_target = self.build_root / "real-echo-cli"
        self.executable.rename(executable_target)
        self.executable.symlink_to(executable_target)
        with self.assertRaises(ValueError):
            self.verify_identity()

        self.setUp()
        resources = self.build_root / "EchoNarrationResources"
        (resources / "voice-link").symlink_to(resources / "phonemes.txt")
        with self.assertRaises(ValueError):
            self.verify_identity()

        self.setUp()
        manifest_target = self.source_root / "real-renderer-manifest.json"
        self.manifest_path.rename(manifest_target)
        self.manifest_path.symlink_to(manifest_target)
        with self.assertRaises(ValueError):
            self.verify_identity()

        self.setUp()
        linked_root = self.renderer_root.parent / "renderers-link"
        linked_root.symlink_to(self.renderer_root, target_is_directory=True)
        with self.assertRaises(ValueError):
            RendererStore(linked_root, runner=self.runner)

    def test_rejects_special_resource_files(self):
        os.mkfifo(self.build_root / "EchoNarrationResources" / "voice.fifo")

        with self.assertRaises(ValueError):
            self.verify_identity()

    def test_rejects_unexpected_top_level_entries(self):
        (self.build_root / "notes.txt").write_text("unexpected\n", encoding="utf-8")

        with self.assertRaises(ValueError):
            self.verify_identity()

    def test_rejects_altered_executable_and_resources(self):
        self.executable.write_bytes(b"altered executable\n")
        with self.assertRaises(ValueError):
            self.verify_identity()

        self.setUp()
        (self.build_root / "EchoNarrationResources" / "phonemes.txt").write_bytes(
            b"altered resources\n"
        )
        with self.assertRaises(ValueError):
            self.verify_identity()


class ReleaseCLIProbeTests(RendererPackageFixture):
    def test_probes_release_identity_with_explicit_resources_and_argument_arrays(self):
        probe = probe_release_cli(
            self.executable,
            self.build_root / "EchoNarrationResources",
            runner=self.runner,
        )

        self.assertEqual(
            probe,
            RendererProbe(
                render_version=15,
                build_configuration="Release",
                architectures=(platform.machine(),),
                minimum_macos_version="15.0",
                capabilities=REQUIRED_CAPABILITIES,
            ),
        )
        self.assertEqual(
            [call[0] for call in self.runner.calls],
            [
                (str(self.executable), "--version"),
                (str(self.executable), "narrate", "--help"),
                (str(self.executable), "export-blocks", "--help"),
                (str(self.executable), "resolve-voice-plan", "--help"),
                (str(self.executable), "verify-sidecar", "--help"),
                ("/usr/bin/lipo", "-archs", str(self.executable)),
                ("/usr/bin/otool", "-l", str(self.executable)),
            ],
        )
        for arguments, keywords in self.runner.calls[:5]:
            self.assertEqual(
                keywords["env"]["ECHO_RESOURCE_DIR"],
                str(self.build_root / "EchoNarrationResources"),
                arguments,
            )

    def test_rejects_debug_or_malformed_version_output(self):
        for version in (
            "ONNX rv15 (Debug)\n",
            "ONNX rv15 (Release) trailing\n",
            "rv15 (Release)\n",
        ):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    probe_release_cli(
                        self.executable,
                        self.build_root / "EchoNarrationResources",
                        runner=ProbeRunner(version=version),
                    )

    def test_rejects_each_missing_narrate_capability(self):
        for missing in REQUIRED_NARRATE_CAPABILITIES:
            with self.subTest(missing=missing):
                capabilities = tuple(
                    capability
                    for capability in REQUIRED_NARRATE_CAPABILITIES
                    if capability != missing
                )
                with self.assertRaises(ValueError):
                    probe_release_cli(
                        self.executable,
                        self.build_root / "EchoNarrationResources",
                        runner=ProbeRunner(capabilities=capabilities),
                    )

    def test_rejects_each_missing_required_subcommand(self):
        for missing in REQUIRED_SUBCOMMAND_CAPABILITIES:
            with self.subTest(missing=missing):
                available = tuple(
                    capability
                    for capability in REQUIRED_SUBCOMMAND_CAPABILITIES
                    if capability != missing
                )
                with self.assertRaises(ValueError):
                    probe_release_cli(
                        self.executable,
                        self.build_root / "EchoNarrationResources",
                        runner=ProbeRunner(subcommand_capabilities=available),
                    )

    def test_returns_only_the_capabilities_actually_observed(self):
        probe = probe_release_cli(
            self.executable,
            self.build_root / "EchoNarrationResources",
            runner=ProbeRunner(
                capabilities=REQUIRED_NARRATE_CAPABILITIES + ("--some-future-flag",)
            ),
        )

        self.assertNotIn("--some-future-flag", probe.capabilities)
        self.assertEqual(
            tuple(sorted(probe.capabilities)), tuple(sorted(REQUIRED_CAPABILITIES))
        )

    def test_rejects_an_executable_without_the_current_host_architecture(self):
        incompatible = "x86_64" if platform.machine() == "arm64" else "arm64"

        with self.assertRaises(ValueError):
            probe_release_cli(
                self.executable,
                self.build_root / "EchoNarrationResources",
                runner=ProbeRunner(architectures=(incompatible,)),
            )

    def test_rejects_a_deployment_floor_above_the_current_host(self):
        with self.assertRaises(ValueError):
            probe_release_cli(
                self.executable,
                self.build_root / "EchoNarrationResources",
                runner=ProbeRunner(minimum_macos_version="9999.0"),
            )


class RendererStoreTests(RendererPackageFixture):
    def test_store_verifies_manifest_against_live_probes_without_mutation(self):
        before = sorted(
            path.relative_to(self.renderer_root)
            for path in self.renderer_root.rglob("*")
        )

        verified = RendererStore(self.renderer_root, runner=self.runner).verify(
            self.source_sha, self.manifest_sha
        )

        after = sorted(
            path.relative_to(self.renderer_root)
            for path in self.renderer_root.rglob("*")
        )
        self.assertEqual(verified.manifest, self.manifest)
        self.assertEqual(after, before)

    def test_store_rejects_manifest_probe_mismatches(self):
        cases = (
            ("renderVersion", 14),
            ("buildConfiguration", "Debug"),
            ("architectures", ["x86_64" if platform.machine() == "arm64" else "arm64"]),
            ("minimumMacOSVersion", "14.0"),
            ("capabilities", list(REQUIRED_CAPABILITIES[:-1])),
        )
        for field, value in cases:
            with self.subTest(field=field):
                payload = manifest_payload(self.manifest)
                payload[field] = value
                self.replace_manifest_payload(payload)
                with self.assertRaises(ValueError):
                    RendererStore(self.renderer_root, runner=self.runner).verify(
                        self.source_sha, self.manifest_sha
                    )
                self.setUp()


if __name__ == "__main__":
    unittest.main()
