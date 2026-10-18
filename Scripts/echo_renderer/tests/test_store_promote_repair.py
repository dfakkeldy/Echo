from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import echo_renderer.store as store_module
from echo_renderer.identity import canonical_json_bytes
from echo_renderer.lease import TEMPORARY_FAILURE, LeaseSet
from echo_renderer.store import (
    InstallRequest,
    InstallResult,
    RendererStore,
    RepairMismatchError,
)
from echo_renderer.tests.test_store_install import GIT, MAKE, InstallRunner


_SELECTOR_NAME = "approved-renderer.json"
_SELECTOR_KEYS = {"echoSourceSHA", "manifestSHA256", "schemaVersion"}


class PromoteRepairFixture(unittest.TestCase):
    """Cribs Task 5's git/runner fixture pattern; adds selector/quarantine helpers.

    Patches ``store_module.canonical_lease_root`` so every lease acquired by
    the code under test -- and every lease this fixture pre-holds to test
    contention -- lands under a throwaway temp directory rather than the
    real shared ``~/.cache/explainer-audiobooks/echo-pronunciation-leases/``.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

        self.renderer_root = (self.root / "renderers").resolve()
        self.renderer_root.mkdir()

        self.lease_root = (self.root / "leases").resolve()
        lease_root_patch = mock.patch.object(
            store_module, "canonical_lease_root", lambda: self.lease_root
        )
        lease_root_patch.start()
        self.addCleanup(lease_root_patch.stop)

        self.installer_worktree = (self.root / "installer-worktree").resolve()
        self.installer_worktree.mkdir()
        self.installer_sha = self._init_repo(
            self.installer_worktree, {"installer.txt": "installer fixture v1\n"}
        )

        self.source_worktree = (self.root / "source-worktree").resolve()
        self.source_worktree.mkdir()
        self.source_sha = self._init_repo(
            self.source_worktree,
            {
                ".gitignore": ".build/\n",
                "EchoCore/Services/Narration/OnnxKokoroEngine.swift": (
                    "private nonisolated static let modelRevision = "
                    '"1939ad2a8e416c0acfeecc08a694d14ef25f2231"\n'
                    "nonisolated static let expectedModelBytes = 163_234_740\n"
                ),
            },
        )

        self.build_gate = self.installer_worktree / "fake-build-gate.sh"
        self.runner = InstallRunner(
            source_worktree=self.source_worktree, build_gate=self.build_gate
        )
        self.store = RendererStore(self.renderer_root, runner=self.runner)

    def _git(self, root: Path, *arguments: str) -> str:
        completed = subprocess.run(
            [GIT, *arguments],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout

    def _init_repo(self, root: Path, files: dict[str, str]) -> str:
        self._git(root, "init", "--quiet")
        self._git(root, "config", "user.name", "Renderer Promote/Repair Tests")
        self._git(
            root, "config", "user.email", "renderer-promote-repair-tests@example.invalid"
        )
        for relative_path, content in files.items():
            self._write_and_add(root, relative_path, content)
        self._git(root, "commit", "--quiet", "-m", "initial commit")
        return self._git(root, "rev-parse", "HEAD").strip()

    def _write_and_add(self, root: Path, relative_path: str, content: str) -> None:
        destination = root.joinpath(*relative_path.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        self._git(root, "add", relative_path)

    def _recommit_installer(self, content: str) -> str:
        self._write_and_add(self.installer_worktree, "installer.txt", content)
        self._git(self.installer_worktree, "commit", "--quiet", "-m", "second commit")
        return self._git(self.installer_worktree, "rev-parse", "HEAD").strip()

    def request(self, **overrides: object) -> InstallRequest:
        fields: dict[str, object] = dict(
            installer_worktree=self.installer_worktree,
            installer_sha=self.installer_sha,
            source_worktree=self.source_worktree,
            source_sha=self.source_sha,
            renderer_root=self.renderer_root,
            build_gate=self.build_gate,
            promote=False,
        )
        fields.update(overrides)
        return InstallRequest(**fields)

    def selector_path(self, source_sha: str | None = None) -> Path:
        return self.renderer_root / (source_sha or self.source_sha) / _SELECTOR_NAME

    def package_dir(self, manifest_sha: str, source_sha: str | None = None) -> Path:
        return self.renderer_root / (source_sha or self.source_sha) / manifest_sha

    def quarantine_dirs(self, manifest_sha: str, source_sha: str | None = None) -> list[Path]:
        source_dir = self.renderer_root / (source_sha or self.source_sha)
        if not source_dir.is_dir():
            return []
        return sorted(
            p for p in source_dir.iterdir() if p.name.startswith(f"{manifest_sha}.quarantine-")
        )


class PromotionWriteTests(PromoteRepairFixture):
    def test_promote_writes_the_documented_selector_schema(self):
        installed = self.store.install(self.request())

        result_path = self.store.promote(self.source_sha, installed.verified.manifest_sha)

        expected_path = self.selector_path()
        self.assertEqual(result_path, expected_path)
        raw = expected_path.read_bytes()
        expected_bytes = canonical_json_bytes(
            {
                "echoSourceSHA": self.source_sha,
                "manifestSHA256": installed.verified.manifest_sha,
                "schemaVersion": 1,
            }
        )
        self.assertEqual(raw, expected_bytes)
        payload = json.loads(raw)
        self.assertEqual(set(payload), _SELECTOR_KEYS)

    def test_promote_uses_a_sibling_temp_file_then_atomic_replace(self):
        installed = self.store.install(self.request())
        selector_dir = self.selector_path().parent

        observed_temp_names: list[str] = []
        original_replace = store_module.os.replace

        def recording_replace(src, dst):
            observed_temp_names.append(Path(src).name)
            self.assertEqual(Path(src).parent, selector_dir)
            self.assertTrue(Path(src).is_file())
            return original_replace(src, dst)

        with mock.patch.object(store_module.os, "replace", side_effect=recording_replace):
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertEqual(len(observed_temp_names), 1)
        self.assertNotEqual(observed_temp_names[0], _SELECTOR_NAME)
        # No temp file left behind after a successful replace (the package
        # directory itself is expected to remain alongside the selector).
        leftovers = [
            p.name
            for p in selector_dir.iterdir()
            if p.name not in (_SELECTOR_NAME, installed.verified.manifest_sha)
        ]
        self.assertEqual(leftovers, [])

    def test_promote_returns_the_selector_path_without_creating_extra_files(self):
        installed = self.store.install(self.request())

        result_path = self.store.promote(self.source_sha, installed.verified.manifest_sha)

        source_dir = self.renderer_root / self.source_sha
        self.assertEqual(
            sorted(p.name for p in source_dir.iterdir()),
            sorted([installed.verified.manifest_sha, _SELECTOR_NAME]),
        )
        self.assertEqual(result_path.name, _SELECTOR_NAME)


class PromotionVerificationOrderTests(PromoteRepairFixture):
    def test_promote_refuses_a_package_that_fails_verification_and_writes_nothing(self):
        installed = self.store.install(self.request())
        installed.verified.executable.write_bytes(b"corrupted bytes\n")

        with self.assertRaises(ValueError):
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertFalse(self.selector_path().exists())

    def test_promote_refuses_a_manifest_sha_that_was_never_installed(self):
        self.store.install(self.request())
        bogus_manifest_sha = "0" * 64

        with self.assertRaises(ValueError):
            self.store.promote(self.source_sha, bogus_manifest_sha)

        self.assertFalse(self.selector_path().exists())


class PromotionLeaseTests(PromoteRepairFixture):
    def test_promote_leases_exactly_the_package_and_the_selector(self):
        installed = self.store.install(self.request())
        recorded: list[tuple[str, ...]] = []
        original_acquire = LeaseSet.acquire.__func__

        def recording_acquire(cls, *, lock_root, resources, wait=False):
            recorded.append(tuple(sorted(str(r) for r in resources)))
            return original_acquire(cls, lock_root=lock_root, resources=resources, wait=wait)

        with mock.patch.object(LeaseSet, "acquire", classmethod(recording_acquire)):
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertEqual(len(recorded), 1)
        expected = tuple(
            sorted(
                str(path)
                for path in (
                    self.package_dir(installed.verified.manifest_sha),
                    self.selector_path(),
                )
            )
        )
        self.assertEqual(recorded[0], expected)

    def test_promote_holds_the_lease_while_writing_the_selector(self):
        installed = self.store.install(self.request())
        package_dir = self.package_dir(installed.verified.manifest_sha)
        selector_path = self.selector_path()
        observed: dict[str, object] = {}
        original_replace = store_module.os.replace

        def recording_replace(src, dst):
            try:
                LeaseSet.acquire(
                    lock_root=self.lease_root, resources=(package_dir, selector_path)
                )
            except SystemExit as error:
                observed["code"] = error.code
            else:
                observed["code"] = None
            return original_replace(src, dst)

        with mock.patch.object(store_module.os, "replace", side_effect=recording_replace):
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertEqual(observed["code"], TEMPORARY_FAILURE)

    def test_promote_exits_75_when_the_package_is_already_leased(self):
        installed = self.store.install(self.request())
        package_dir = self.package_dir(installed.verified.manifest_sha)
        held = LeaseSet.acquire(lock_root=self.lease_root, resources=(package_dir,))
        self.addCleanup(held.close)

        with self.assertRaises(SystemExit) as raised:
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        self.assertFalse(self.selector_path().exists())

    def test_promote_exits_75_when_the_selector_is_already_leased(self):
        installed = self.store.install(self.request())
        held = LeaseSet.acquire(lock_root=self.lease_root, resources=(self.selector_path(),))
        self.addCleanup(held.close)

        with self.assertRaises(SystemExit) as raised:
            self.store.promote(self.source_sha, installed.verified.manifest_sha)

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        self.assertFalse(self.selector_path().exists())


class PromotionSelectorStabilityTests(PromoteRepairFixture):
    def test_installing_a_second_build_does_not_move_an_existing_selector(self):
        first = self.store.install(self.request(promote=True))
        selector_bytes_before = self.selector_path().read_bytes()

        second_installer_sha = self._recommit_installer("installer fixture v2\n")
        second = self.store.install(self.request(installer_sha=second_installer_sha))

        self.assertNotEqual(first.verified.manifest_sha, second.verified.manifest_sha)
        self.assertFalse(second.selector_updated)
        self.assertEqual(self.selector_path().read_bytes(), selector_bytes_before)

    def test_explicit_promote_moves_the_selector_to_a_new_build(self):
        first = self.store.install(self.request(promote=True))
        second_installer_sha = self._recommit_installer("installer fixture v2\n")
        second = self.store.install(self.request(installer_sha=second_installer_sha))

        self.store.promote(self.source_sha, second.verified.manifest_sha)

        payload = json.loads(self.selector_path().read_bytes())
        self.assertEqual(payload["manifestSHA256"], second.verified.manifest_sha)
        self.assertNotEqual(second.verified.manifest_sha, first.verified.manifest_sha)


class RepairRestoreTests(PromoteRepairFixture):
    def test_repair_quarantines_a_corrupted_package_and_restores_its_identity(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        original_bytes = first.verified.executable.read_bytes()
        corrupted_bytes = b"corrupted renderer executable bytes\n"
        first.verified.executable.write_bytes(corrupted_bytes)

        with self.assertRaises(ValueError):
            self.store.verify(self.source_sha, manifest_sha)

        result = self.store.repair(self.request(), manifest_sha)

        self.assertIsInstance(result, InstallResult)
        self.assertEqual(result.verified.manifest_sha, manifest_sha)
        self.assertFalse(result.selector_updated)

        # The identity verifies clean again -- restored, not patched in place.
        self.store.verify(self.source_sha, manifest_sha)
        self.assertEqual(result.verified.executable.read_bytes(), original_bytes)

        quarantines = self.quarantine_dirs(manifest_sha)
        self.assertEqual(len(quarantines), 1)
        self.assertRegex(quarantines[0].name, rf"^{manifest_sha}\.quarantine-[0-9a-f]+$")
        self.assertEqual((quarantines[0] / "echo-cli").read_bytes(), corrupted_bytes)

    def test_repair_rebuilds_a_missing_package_without_quarantining_anything(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        shutil.rmtree(self.package_dir(manifest_sha))
        self.assertFalse(self.package_dir(manifest_sha).exists())

        result = self.store.repair(self.request(), manifest_sha)

        self.assertEqual(result.verified.manifest_sha, manifest_sha)
        self.assertEqual(self.quarantine_dirs(manifest_sha), [])

    def test_repair_promotes_on_match_only_when_the_request_asks_for_it(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        first.verified.executable.write_bytes(b"corrupted\n")

        result = self.store.repair(self.request(promote=True), manifest_sha)

        self.assertEqual(result.verified.manifest_sha, manifest_sha)
        self.assertTrue(result.selector_updated)
        payload = json.loads(self.selector_path().read_bytes())
        self.assertEqual(payload["manifestSHA256"], manifest_sha)
        self.assertEqual(payload["echoSourceSHA"], self.source_sha)


class RepairMismatchTests(PromoteRepairFixture):
    def test_repair_mismatch_publishes_a_new_candidate_and_leaves_an_unrelated_selector_untouched(
        self,
    ):
        first = self.store.install(self.request(promote=True))
        selector_bytes_before = self.selector_path().read_bytes()

        second_installer_sha = self._recommit_installer("installer fixture v2\n")
        second = self.store.install(self.request(installer_sha=second_installer_sha))
        second_manifest_sha = second.verified.manifest_sha

        # Force the rebuild triggered by repair() to diverge from the
        # original build output, simulating a non-reproducible toolchain.
        self.runner.executable_bytes = b"different fixture bytes for a mismatch\n"

        with self.assertRaises(ValueError) as raised:
            self.store.repair(self.request(installer_sha=second_installer_sha), second_manifest_sha)

        message = str(raised.exception)
        self.assertIn(second_manifest_sha, message)
        self.assertIn("non-resumable", message)

        # The selector -- pointing at an entirely different build -- never moved.
        self.assertEqual(self.selector_path().read_bytes(), selector_bytes_before)
        self.store.verify(self.source_sha, first.verified.manifest_sha)

        # The new candidate is published side-by-side at its own hash.
        source_dir = self.renderer_root / self.source_sha
        published_names = {p.name for p in source_dir.iterdir()}
        self.assertIn(first.verified.manifest_sha, published_names)
        new_candidates = published_names - {
            first.verified.manifest_sha,
            _SELECTOR_NAME,
            *[p.name for p in self.quarantine_dirs(second_manifest_sha)],
        }
        self.assertEqual(len(new_candidates), 1)
        new_manifest_sha = next(iter(new_candidates))
        self.assertNotEqual(new_manifest_sha, second_manifest_sha)
        self.store.verify(self.source_sha, new_manifest_sha)

        # The old (now-quarantined) requested identity is exactly preserved.
        quarantines = self.quarantine_dirs(second_manifest_sha)
        self.assertEqual(len(quarantines), 1)

    def test_repair_mismatch_raises_a_structured_error_carrying_both_hashes(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        self.runner.executable_bytes = b"different fixture bytes for a mismatch\n"

        with self.assertRaises(RepairMismatchError) as raised:
            self.store.repair(self.request(), manifest_sha)

        error = raised.exception
        self.assertEqual(error.requested_manifest_sha, manifest_sha)
        self.assertNotEqual(error.rebuilt_manifest_sha, manifest_sha)
        # The attributes name the real hashes: the rebuilt one verifies.
        self.store.verify(self.source_sha, error.rebuilt_manifest_sha)

    def test_repair_does_not_promote_a_mismatched_rebuild_even_when_requested(self):
        first = self.store.install(self.request(promote=True))
        first_manifest_sha = first.verified.manifest_sha
        selector_bytes_before = self.selector_path().read_bytes()

        # Force the repair rebuild of the *currently selected* identity to
        # diverge. The selector text is left byte-for-byte unchanged -- even
        # though that means it now names a quarantined, no-longer-published
        # identity. That is deliberate fail-closed behavior: repair() must
        # never silently swap the approved build for an unreviewed rebuild.
        self.runner.executable_bytes = b"different fixture bytes for a mismatch\n"

        with self.assertRaises(ValueError):
            self.store.repair(self.request(promote=True), first_manifest_sha)

        self.assertEqual(self.selector_path().read_bytes(), selector_bytes_before)
        with self.assertRaises(ValueError):
            # The selector's target was quarantined away by the repair
            # attempt and was never republished, so it must not verify.
            self.store.verify(self.source_sha, first_manifest_sha)


class RepairLeaseTests(PromoteRepairFixture):
    def test_repair_exits_75_when_the_package_is_already_leased(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        held = LeaseSet.acquire(
            lock_root=self.lease_root, resources=(self.package_dir(manifest_sha),)
        )
        self.addCleanup(held.close)

        with self.assertRaises(SystemExit) as raised:
            self.store.repair(self.request(), manifest_sha)

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        # The contended resource is identified via the chained cause, while
        # .code stays the plain SystemExit(75) temporary-failure convention.
        self.assertIsInstance(raised.exception.__cause__, ValueError)
        self.assertIn("renderer package", str(raised.exception.__cause__))
        # Only the initial (already-completed) install() built anything --
        # the repair attempt never reached its own rebuild.
        self.assertEqual(self.runner.make_calls, 1)
        self.assertEqual(self.quarantine_dirs(manifest_sha), [])

    def test_repair_exits_75_when_the_selector_is_already_leased(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha
        held = LeaseSet.acquire(lock_root=self.lease_root, resources=(self.selector_path(),))
        self.addCleanup(held.close)

        with self.assertRaises(SystemExit) as raised:
            self.store.repair(self.request(), manifest_sha)

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        self.assertIsInstance(raised.exception.__cause__, ValueError)
        self.assertIn("renderer selector", str(raised.exception.__cause__))
        self.assertEqual(self.runner.make_calls, 1)
        self.assertEqual(self.quarantine_dirs(manifest_sha), [])
        # The un-quarantined original package is exactly as it was.
        self.assertTrue(self.package_dir(manifest_sha).is_dir())


class RepairQuarantineHygieneTests(PromoteRepairFixture):
    def test_quarantine_directories_accumulate_and_are_never_removed(self):
        first = self.store.install(self.request())
        manifest_sha = first.verified.manifest_sha

        first.verified.executable.write_bytes(b"corruption one\n")
        self.store.repair(self.request(), manifest_sha)
        first_round = self.quarantine_dirs(manifest_sha)
        self.assertEqual(len(first_round), 1)

        restored_executable = self.package_dir(manifest_sha) / "echo-cli"
        restored_executable.write_bytes(b"corruption two\n")
        self.store.repair(self.request(), manifest_sha)
        second_round = self.quarantine_dirs(manifest_sha)

        self.assertEqual(len(second_round), 2)
        self.assertTrue(set(first_round).issubset(set(second_round)))
        for quarantine in second_round:
            self.assertTrue(quarantine.is_dir())


if __name__ == "__main__":
    unittest.main()
