"""Command-line entry points for installing, verifying, promoting, and
repairing versioned, content-addressed Echo renderer packages.

Four subcommands mirror ``RendererStore``'s operations one-to-one --
``install``, ``verify``, ``promote``, and ``repair`` -- and every exit code
distinguishes *why* the command failed so a caller (Make target or CI job)
can react without parsing stderr text:

* ``0``  -- success; stable ``key=value`` lines on stdout (sorted by key).
* ``64`` -- usage error: bad flags, a malformed SHA, an unknown subcommand.
* ``65`` -- verification/corruption/attestation failure (``ValueError``).
* ``69`` -- the renderer is incompatible with this host (a non-Release
  build, a missing capability, an unsupported architecture, or a
  deployment floor above the host's macOS version --
  ``RendererIncompatibleError``, a narrow subclass of ``ValueError``).
* ``75`` -- temporary failure: another process holds a live lease on the
  same resources. This is the existing ``SystemExit(75)`` from
  ``echo_renderer.lease`` passed straight through, uncaught.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Callable, Sequence

from echo_renderer.identity import validate_commit_sha, validate_sha256
from echo_renderer.store import (
    InstallRequest,
    RendererIncompatibleError,
    RendererStore,
    VerifiedRenderer,
)


_USAGE_EXIT_CODE = 64
_VERIFICATION_EXIT_CODE = 65
_INCOMPATIBLE_EXIT_CODE = 69

# The store methods this CLI drives (real ``RendererStore`` or an injected
# test double) all share this narrow shape.
StoreLike = object
StoreFactory = Callable[[Path], StoreLike]


class _StrictArgumentParser(argparse.ArgumentParser):
    """An ``ArgumentParser`` that reports usage errors with exit code 64.

    ``argparse``'s own default is exit code 2 for every parse failure --
    bad flags, an invalid SHA, a missing subcommand. Overriding only
    ``error()`` (not ``exit()``) keeps ``--help``'s own explicit
    ``exit(0)`` untouched while every error path funnels through here.
    ``add_subparsers()`` propagates this class to each subcommand parser
    (it defaults ``parser_class`` to ``type(self)``), so subcommand-level
    errors get the same treatment automatically.
    """

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(_USAGE_EXIT_CODE, f"{self.prog}: error: {message}\n")


def _commit_sha_argument(value: str) -> str:
    """Parse one full lowercase-hex commit SHA, or fail as a usage error."""
    try:
        return validate_commit_sha(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _sha256_argument(value: str) -> str:
    """Parse one full lowercase-hex SHA-256, or fail as a usage error."""
    try:
        return validate_sha256(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _default_renderer_root() -> Path:
    return Path("~/Library/Application Support/Echo/Renderers").expanduser()


def _default_build_gate() -> Path:
    home = os.environ.get("HOME") or str(Path.home())
    return Path(home) / ".claude" / "bin" / "xcode-build-gate.sh"


def _add_renderer_root_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--renderer-root",
        type=Path,
        default=_default_renderer_root(),
        help="Canonical renderer store root (default: %(default)s)",
    )


def _add_build_gate_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--build-gate",
        type=Path,
        default=_default_build_gate(),
        help="Path to the memory-pressure build gate script (default: %(default)s)",
    )


def _add_installer_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--installer-worktree", type=Path, required=True)
    parser.add_argument("--installer-sha", type=_commit_sha_argument, required=True)


def _add_source_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source-worktree", type=Path, required=True)
    parser.add_argument("--source-sha", type=_commit_sha_argument, required=True)


def _print_success(
    verified: VerifiedRenderer, *, selector_updated: bool | None = None
) -> None:
    """Print stable, sorted ``key=value`` success lines to stdout."""
    fields: dict[str, str] = {
        "executableSHA256": verified.manifest.executable.sha256,
        "installedPath": str(verified.build_root),
        "installerSourceSHA": verified.manifest.installer_source_sha,
        "manifestSHA256": verified.manifest_sha,
        "resourcesSHA256": verified.manifest.resources.sha256,
        "sourceSHA": verified.source_sha,
    }
    if selector_updated is not None:
        fields["selectorUpdated"] = "true" if selector_updated else "false"
    for key in sorted(fields):
        print(f"{key}={fields[key]}")


def _ensure_renderer_root(renderer_root: Path) -> None:
    """Create the renderer store root if nothing exists there yet.

    ``install`` and ``repair`` are how a package first lands on a fresh
    machine, so the default root (``~/Library/Application
    Support/Echo/Renderers``) not existing yet would otherwise make the
    very first ``install`` ever run fail before doing any work. ``verify``
    and ``promote`` deliberately do NOT call this: a missing root there
    honestly means "nothing has ever been installed", which stays a real
    exit-65 answer rather than something to paper over.

    Guarded to fail closed: any ``OSError`` -- the path already occupied by
    a regular file, an existing symlink, or anything else ``mkdir`` refuses
    -- is swallowed here and left entirely to ``RendererStore.__init__``'s
    own canonicality check (``_require_canonical_directory``), which
    remains the sole authority for accepting or rejecting the resulting
    path. Nothing already at an occupied path is ever deleted or replaced.
    """
    try:
        renderer_root.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass


def _handle_install(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    _ensure_renderer_root(args.renderer_root)
    store = store_factory(args.renderer_root)
    request = InstallRequest(
        installer_worktree=args.installer_worktree,
        installer_sha=args.installer_sha,
        source_worktree=args.source_worktree,
        source_sha=args.source_sha,
        renderer_root=args.renderer_root,
        build_gate=args.build_gate,
        promote=args.promote,
    )
    result = store.install(request)
    _print_success(result.verified, selector_updated=result.selector_updated)
    return 0


def _handle_verify(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    store = store_factory(args.renderer_root)
    verified = store.verify(args.source_sha, args.manifest_sha)
    _print_success(verified)
    return 0


def _handle_promote(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    store = store_factory(args.renderer_root)
    # ``promote()`` returns only the selector path it wrote, so re-verify
    # afterward to report the same stable identity fields as every other
    # subcommand -- it also re-attests the package fresh rather than
    # trusting whatever ``promote()`` last observed.
    store.promote(args.source_sha, args.manifest_sha)
    verified = store.verify(args.source_sha, args.manifest_sha)
    _print_success(verified)
    return 0


def _handle_repair(args: argparse.Namespace, store_factory: StoreFactory) -> int:
    _ensure_renderer_root(args.renderer_root)
    store = store_factory(args.renderer_root)
    request = InstallRequest(
        installer_worktree=args.installer_worktree,
        installer_sha=args.installer_sha,
        source_worktree=args.source_worktree,
        source_sha=args.source_sha,
        renderer_root=args.renderer_root,
        build_gate=args.build_gate,
        # The repair command contract has no --promote flag: repair only
        # restores a package at its requested identity, it never changes
        # what the selector points at.
        promote=False,
    )
    result = store.repair(request, args.manifest_sha)
    _print_success(result.verified, selector_updated=result.selector_updated)
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the ``echo_renderer.cli`` parser for install/verify/promote/repair."""
    parser = _StrictArgumentParser(
        prog="python3 -m echo_renderer.cli",
        description="Install, verify, promote, and repair versioned Echo renderers.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser(
        "install", help="Build, stage, verify, and publish one renderer package"
    )
    _add_installer_arguments(install_parser)
    _add_source_arguments(install_parser)
    _add_renderer_root_argument(install_parser)
    _add_build_gate_argument(install_parser)
    install_parser.add_argument(
        "--promote", action="store_true", help="Also point the selector at the result"
    )
    install_parser.set_defaults(handler=_handle_install)

    verify_parser = subparsers.add_parser(
        "verify", help="Strictly re-verify one published renderer package"
    )
    verify_parser.add_argument("--source-sha", type=_commit_sha_argument, required=True)
    verify_parser.add_argument("--manifest-sha", type=_sha256_argument, required=True)
    _add_renderer_root_argument(verify_parser)
    verify_parser.set_defaults(handler=_handle_verify)

    promote_parser = subparsers.add_parser(
        "promote", help="Point the selector at one verified renderer package"
    )
    promote_parser.add_argument("--source-sha", type=_commit_sha_argument, required=True)
    promote_parser.add_argument("--manifest-sha", type=_sha256_argument, required=True)
    _add_renderer_root_argument(promote_parser)
    promote_parser.set_defaults(handler=_handle_promote)

    repair_parser = subparsers.add_parser(
        "repair", help="Quarantine and rebuild one renderer package identity"
    )
    _add_installer_arguments(repair_parser)
    _add_source_arguments(repair_parser)
    repair_parser.add_argument("--manifest-sha", type=_sha256_argument, required=True)
    _add_renderer_root_argument(repair_parser)
    _add_build_gate_argument(repair_parser)
    repair_parser.set_defaults(handler=_handle_repair)

    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    store_factory: StoreFactory = RendererStore,
) -> int:
    """Parse ``argv``, dispatch to ``store_factory``, and return an exit code.

    Usage errors (64) exit directly from argument parsing, before any
    store is constructed. Temporary lease contention (75) is the existing
    ``SystemExit`` from ``echo_renderer.lease`` -- a ``BaseException``, not
    caught here, so it passes straight through uncaught. Everything else a
    dispatched handler raises is a ``ValueError``: ``RendererIncompatibleError``
    (a narrow ``ValueError`` subclass) maps to 69, and any other
    ``ValueError`` maps to 65.
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args, store_factory)
    except RendererIncompatibleError as error:
        print(str(error), file=sys.stderr)
        return _INCOMPATIBLE_EXIT_CODE
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return _VERIFICATION_EXIT_CODE


if __name__ == "__main__":
    sys.exit(main())
