from __future__ import annotations

import fcntl
import hashlib
import json
import os
import pwd
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import echo_renderer.lease as lease_module
from echo_renderer.lease import (
    TEMPORARY_FAILURE,
    LeaseSet,
    canonical_account_home,
    canonical_lease_root,
    canonical_resource,
    lock_path,
)


VECTOR_ROOT = Path(__file__).parents[1] / "test_vectors"


def load_vector(name: str) -> dict[str, object]:
    with (VECTOR_ROOT / name).open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise AssertionError(f"{name} must contain a JSON object")
    return payload


class CanonicalLeaseIdentityTests(unittest.TestCase):
    def test_uses_effective_account_home_and_shared_explainer_namespace(self):
        expected_home = Path(pwd.getpwuid(os.geteuid()).pw_dir).resolve(strict=True)
        with tempfile.TemporaryDirectory() as temporary_directory:
            with mock.patch.dict(os.environ, {"HOME": temporary_directory}):
                self.assertEqual(canonical_account_home(), expected_home)
                self.assertEqual(
                    canonical_lease_root(),
                    expected_home
                    / ".cache"
                    / "explainer-audiobooks"
                    / "echo-pronunciation-leases",
                )

    def test_canonical_resource_is_an_absolute_resolved_path(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            resource = root / "nested" / ".." / "renderer"

            self.assertEqual(canonical_resource(resource), str((root / "renderer").resolve()))

    def test_checked_in_vectors_lock_every_resource_to_lock_path_pair(self):
        vector = load_vector("lease-identities-v1.json")
        self.assertEqual(vector["schemaVersion"], 1)
        self.assertEqual(vector["canonicalResource"], "resolved-absolute-path-utf8")
        self.assertEqual(vector["digest"], "sha256")
        self.assertEqual(vector["suffix"], ".lock")

        cases = vector["cases"]
        self.assertIsInstance(cases, list)
        self.assertGreater(len(cases), 0)
        lock_root = Path("/var/tmp/echo-lease-vector")
        for case in cases:
            with self.subTest(resource=case["resource"]):
                resource = Path(case["resource"])
                expected_digest = hashlib.sha256(
                    case["resource"].encode("utf-8")
                ).hexdigest()
                self.assertEqual(canonical_resource(resource), case["resource"])
                self.assertEqual(expected_digest, case["sha256"])
                self.assertEqual(
                    lock_path(lock_root, resource),
                    lock_root / case["lockFileName"],
                )


class LeaseAcquisitionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock_root = self.root / "leases"

    def test_acquires_unique_resources_in_sorted_canonical_order_with_no_follow(self):
        resources = (
            self.root / "z-resource",
            self.root / "a-resource",
            self.root / "middle" / ".." / "m-resource",
            self.root / "a-resource",
        )
        expected_resources = sorted({canonical_resource(path) for path in resources})
        expected_paths = [lock_path(self.lock_root, Path(path)) for path in expected_resources]
        original_open = os.open
        opened: list[tuple[Path, int]] = []

        def recording_open(path: os.PathLike[str] | str, flags: int, mode: int = 0o777) -> int:
            opened.append((Path(path), flags))
            return original_open(path, flags, mode)

        with mock.patch.object(lease_module.os, "open", recording_open):
            lease = LeaseSet.acquire(lock_root=self.lock_root, resources=resources)
        self.addCleanup(lease.close)

        self.assertEqual([path for path, _ in opened], expected_paths)
        if hasattr(os, "O_NOFOLLOW"):
            self.assertTrue(all(flags & os.O_NOFOLLOW for _, flags in opened))

    def test_nonblocking_contention_exits_75_without_retaining_a_subset(self):
        first = self.root / "a-resource"
        contended = self.root / "z-resource"
        owner = LeaseSet.acquire(lock_root=self.lock_root, resources=(contended,))
        self.addCleanup(owner.close)

        with self.assertRaises(SystemExit) as raised:
            LeaseSet.acquire(
                lock_root=self.lock_root,
                resources=(contended, first),
            )

        self.assertEqual(raised.exception.code, TEMPORARY_FAILURE)
        available = LeaseSet.acquire(lock_root=self.lock_root, resources=(first,))
        available.close()

    def test_waiting_blocks_until_the_existing_lease_is_released(self):
        resource = self.root / "resource"
        owner = LeaseSet.acquire(lock_root=self.lock_root, resources=(resource,))

        def release_owner() -> None:
            time.sleep(0.1)
            owner.close()

        release_thread = threading.Thread(target=release_owner)
        release_thread.start()
        started = time.monotonic()
        waiter = LeaseSet.acquire(
            lock_root=self.lock_root,
            resources=(resource,),
            wait=True,
        )
        elapsed = time.monotonic() - started
        release_thread.join(timeout=2)
        self.addCleanup(waiter.close)

        self.assertFalse(release_thread.is_alive())
        self.assertGreaterEqual(elapsed, 0.05)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "O_NOFOLLOW is unavailable")
    def test_rejects_a_symbolic_link_lock_file(self):
        self.lock_root.mkdir()
        resource = self.root / "resource"
        target = self.root / "target"
        target.write_text("do not open through the link", encoding="utf-8")
        lock_path(self.lock_root, resource).symlink_to(target)

        with self.assertRaises(OSError):
            LeaseSet.acquire(lock_root=self.lock_root, resources=(resource,))

        self.assertEqual(target.read_text(encoding="utf-8"), "do not open through the link")

    def test_rejects_a_non_regular_lock_file(self):
        self.lock_root.mkdir()
        resource = self.root / "resource"
        os.mkfifo(lock_path(self.lock_root, resource))

        with self.assertRaises(OSError):
            LeaseSet.acquire(lock_root=self.lock_root, resources=(resource,))

    def test_rejects_an_inode_swap_during_lock_open(self):
        resource = self.root / "resource"
        expected_path = lock_path(self.lock_root, resource)
        original_open = os.open
        swapped = False

        def swapping_open(path: os.PathLike[str] | str, flags: int, mode: int = 0o777) -> int:
            nonlocal swapped
            descriptor = original_open(path, flags, mode)
            if Path(path) == expected_path and not swapped:
                swapped = True
                Path(path).unlink()
                Path(path).write_bytes(b"replacement")
            return descriptor

        with mock.patch.object(lease_module.os, "open", swapping_open):
            with self.assertRaises(OSError):
                LeaseSet.acquire(lock_root=self.lock_root, resources=(resource,))


class HeldLeaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock_root = self.root / "leases"
        self.resource = self.root / "resource"

    def test_assert_held_revalidates_the_current_lock_path_inode(self):
        lease = LeaseSet.acquire(lock_root=self.lock_root, resources=(self.resource,))
        self.addCleanup(lease.close)
        path = lock_path(self.lock_root, self.resource)
        path.unlink()
        path.write_bytes(b"replacement")

        with self.assertRaises(OSError):
            lease.assert_held()

    def test_assert_held_rejects_a_descriptor_that_no_longer_holds_the_lock(self):
        lease = LeaseSet.acquire(lock_root=self.lock_root, resources=(self.resource,))
        self.addCleanup(lease.close)
        fcntl.flock(lease._entries[0].file_descriptor, fcntl.LOCK_UN)

        with self.assertRaises(OSError):
            lease.assert_held()

    @unittest.skipUnless(hasattr(os, "fork"), "fork is unavailable")
    def test_inherited_descriptors_still_prove_the_lease(self):
        lease = LeaseSet.acquire(lock_root=self.lock_root, resources=(self.resource,))
        self.addCleanup(lease.close)
        read_fd, write_fd = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(read_fd)
            result = b"ok"
            try:
                lease.assert_held()
                lease.close()
            except BaseException as error:
                result = f"{type(error).__name__}: {error}".encode("utf-8")
            os.write(write_fd, result)
            os.close(write_fd)
            os._exit(0)

        os.close(write_fd)
        result = os.read(read_fd, 4096)
        os.close(read_fd)
        _, status = os.waitpid(child, 0)

        self.assertEqual(status, 0)
        self.assertEqual(result, b"ok")

    def test_close_releases_each_descriptor_once_and_is_idempotent(self):
        lease = LeaseSet.acquire(lock_root=self.lock_root, resources=(self.resource,))
        descriptor = lease._entries[0].file_descriptor
        original_close = os.close
        closed_descriptors: list[int] = []

        def recording_close(file_descriptor: int) -> None:
            closed_descriptors.append(file_descriptor)
            original_close(file_descriptor)

        with mock.patch.object(lease_module.os, "close", recording_close):
            lease.close()
            lease.close()

        self.assertEqual(closed_descriptors, [descriptor])
        replacement = LeaseSet.acquire(
            lock_root=self.lock_root,
            resources=(self.resource,),
        )
        replacement.close()


if __name__ == "__main__":
    unittest.main()
