"""Cross-repository leases for shared Echo renderer resources."""

from __future__ import annotations

import fcntl
import hashlib
import os
import pwd
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


TEMPORARY_FAILURE = 75


def canonical_account_home() -> Path:
    """Return the effective user's account home, independent of ``$HOME``."""
    return Path(pwd.getpwuid(os.geteuid()).pw_dir).resolve(strict=True)


def canonical_lease_root() -> Path:
    """Return the one lease namespace shared with Explainer Audiobooks."""
    return (
        canonical_account_home()
        / ".cache"
        / "explainer-audiobooks"
        / "echo-pronunciation-leases"
    )


def canonical_resource(path: Path) -> str:
    """Return the canonical absolute identity of one shared resource."""
    return str(path.resolve())


def lock_path(lock_root: Path, resource: Path) -> Path:
    """Map one canonical resource to its shared SHA-256 lock filename."""
    digest = hashlib.sha256(canonical_resource(resource).encode("utf-8")).hexdigest()
    return lock_root / f"{digest}.lock"


@dataclass(frozen=True)
class _LeaseEntry:
    resource: str
    path: Path
    file_descriptor: int


def _open_lock(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    file_descriptor = os.open(path, flags, 0o600)
    try:
        descriptor_metadata = os.fstat(file_descriptor)
        path_metadata = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(descriptor_metadata.st_mode):
            raise OSError(f"lease is not a regular file: {path}")
        if not stat.S_ISREG(path_metadata.st_mode):
            raise OSError(f"lease path is not a regular file: {path}")
        if (
            descriptor_metadata.st_dev != path_metadata.st_dev
            or descriptor_metadata.st_ino != path_metadata.st_ino
        ):
            raise OSError(f"lease path changed while opening: {path}")
        return file_descriptor
    except BaseException:
        os.close(file_descriptor)
        raise


class LeaseSet:
    """A deterministically acquired set of FD-backed renderer leases."""

    def __init__(self, entries: Sequence[_LeaseEntry]) -> None:
        self._entries = list(entries)

    @classmethod
    def acquire(
        cls,
        *,
        lock_root: Path,
        resources: Sequence[Path],
        wait: bool = False,
    ) -> "LeaseSet":
        """Acquire all canonical resources or fail without retaining a subset."""
        lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        root_metadata = lock_root.lstat()
        if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(
            root_metadata.st_mode
        ):
            raise OSError(f"malformed renderer lease root: {lock_root}")

        canonical_resources = sorted({canonical_resource(path) for path in resources})
        entries: list[_LeaseEntry] = []
        try:
            for resource in canonical_resources:
                path = lock_path(lock_root, Path(resource))
                file_descriptor = _open_lock(path)
                operation = fcntl.LOCK_EX
                if not wait:
                    operation |= fcntl.LOCK_NB
                try:
                    fcntl.flock(file_descriptor, operation)
                except BaseException:
                    os.close(file_descriptor)
                    raise
                entries.append(
                    _LeaseEntry(
                        resource=resource,
                        path=path,
                        file_descriptor=file_descriptor,
                    )
                )
        except BlockingIOError:
            cls(entries).close()
            raise SystemExit(TEMPORARY_FAILURE) from None
        except BaseException:
            cls(entries).close()
            raise
        return cls(entries)

    def assert_held(self) -> None:
        """Raise if any inherited descriptor no longer proves its lock."""
        for entry in self._entries:
            inherited_metadata = os.fstat(entry.file_descriptor)
            if not stat.S_ISREG(inherited_metadata.st_mode):
                raise OSError(f"inherited lease FD is not regular: {entry.resource}")

            flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            comparison_descriptor = os.open(entry.path, flags)
            try:
                comparison_metadata = os.fstat(comparison_descriptor)
                if not stat.S_ISREG(comparison_metadata.st_mode):
                    raise OSError(f"lease path is not regular: {entry.resource}")
                if (
                    inherited_metadata.st_dev != comparison_metadata.st_dev
                    or inherited_metadata.st_ino != comparison_metadata.st_ino
                ):
                    raise OSError(
                        f"inherited lease FD has the wrong inode: {entry.resource}"
                    )
                try:
                    fcntl.flock(
                        comparison_descriptor,
                        fcntl.LOCK_EX | fcntl.LOCK_NB,
                    )
                except BlockingIOError:
                    pass
                else:
                    fcntl.flock(comparison_descriptor, fcntl.LOCK_UN)
                    raise OSError(
                        f"inherited lease FD does not hold the lock: {entry.resource}"
                    )
            finally:
                os.close(comparison_descriptor)

    def close(self) -> None:
        """Release every descriptor exactly once."""
        entries = self._entries
        self._entries = []
        first_error: OSError | None = None
        for entry in entries:
            try:
                os.close(entry.file_descriptor)
            except OSError as error:
                if first_error is None:
                    first_error = error
        if first_error is not None:
            raise first_error
