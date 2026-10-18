import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPO_ROOT / "Tools/Pronunciation/fetch_mini_bart_g2p.py"
REVISION = "a" * 40


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_tool():
    spec = importlib.util.spec_from_file_location("fetch_mini_bart_g2p", TOOL_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FixtureResponse(contextlib.AbstractContextManager):
    def __init__(self, data: bytes, final_url: str):
        self._stream = io.BytesIO(data)
        self._final_url = final_url

    def read(self, size: int = -1) -> bytes:
        return self._stream.read(size)

    def geturl(self) -> str:
        return self._final_url

    def __exit__(self, exc_type, exc_value, traceback):
        self._stream.close()


class FetchMiniBartG2PTests(unittest.TestCase):
    def setUp(self):
        self.model = b"fixture-model"
        self.license = b"fixture-license"

    def lock_payload(self):
        return {
            "schema_version": 1,
            "model": "example/mini-bart-g2p",
            "revision": REVISION,
            "license_path": "LICENSE",
            "artifacts": [
                {
                    "path": "onnx/model.onnx",
                    "url": f"https://example.invalid/models/{REVISION}/onnx/model.onnx",
                    "size": len(self.model),
                    "sha256": sha256(self.model),
                },
                {
                    "path": "LICENSE",
                    "url": f"https://example.invalid/models/{REVISION}/LICENSE",
                    "size": len(self.license),
                    "sha256": sha256(self.license),
                },
            ],
        }

    def write_lock(self, root: Path, payload=None) -> Path:
        path = root / "lock.json"
        path.write_text(json.dumps(payload or self.lock_payload()), encoding="utf-8")
        return path

    def write_fetched_files(self, destination: Path):
        (destination / "onnx").mkdir(parents=True)
        (destination / "onnx/model.onnx").write_bytes(self.model)
        (destination / "LICENSE").write_bytes(self.license)

    def test_rejects_moving_revision(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            payload = self.lock_payload()
            payload["revision"] = "main"
            lock_path = self.write_lock(Path(temporary), payload)

            with self.assertRaisesRegex(tool.ContractError, "immutable 40-character"):
                tool.load_lock(lock_path)

    def test_rejects_url_without_pinned_revision(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            payload = self.lock_payload()
            payload["artifacts"][0]["url"] = (
                "https://example.invalid/models/main/onnx/model.onnx"
            )
            lock_path = self.write_lock(Path(temporary), payload)

            with self.assertRaisesRegex(tool.ContractError, "pinned revision"):
                tool.load_lock(lock_path)

    def test_rejects_http_url(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            payload = self.lock_payload()
            payload["artifacts"][0]["url"] = payload["artifacts"][0]["url"].replace(
                "https://", "http://"
            )
            lock_path = self.write_lock(Path(temporary), payload)

            with self.assertRaisesRegex(tool.ContractError, "HTTPS"):
                tool.load_lock(lock_path)

    def test_rejects_lock_without_license_artifact(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            payload = self.lock_payload()
            payload["artifacts"] = payload["artifacts"][:-1]
            lock_path = self.write_lock(Path(temporary), payload)

            with self.assertRaisesRegex(tool.ContractError, "license_path"):
                tool.load_lock(lock_path)

    def test_rejects_path_traversal(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            payload = self.lock_payload()
            payload["artifacts"][0]["path"] = "../outside.onnx"
            lock_path = self.write_lock(Path(temporary), payload)

            with self.assertRaisesRegex(tool.ContractError, "safe relative path"):
                tool.load_lock(lock_path)

    def test_check_rejects_size_mismatch_without_network(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"
            self.write_fetched_files(destination)
            (destination / "onnx/model.onnx").write_bytes(self.model + b"!")

            with mock.patch.object(
                tool.urllib.request,
                "urlopen",
                side_effect=AssertionError("check attempted network access"),
            ):
                with self.assertRaisesRegex(tool.VerificationError, "size mismatch"):
                    tool.check(lock_path, destination)

    def test_check_rejects_hash_mismatch_without_network(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"
            self.write_fetched_files(destination)
            (destination / "onnx/model.onnx").write_bytes(b"x" * len(self.model))

            with mock.patch.object(
                tool.urllib.request,
                "urlopen",
                side_effect=AssertionError("check attempted network access"),
            ):
                with self.assertRaisesRegex(tool.VerificationError, "SHA-256 mismatch"):
                    tool.check(lock_path, destination)

    def test_check_rejects_symlinked_artifact(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"
            self.write_fetched_files(destination)
            target = root / "outside"
            target.write_bytes(self.model)
            (destination / "onnx/model.onnx").unlink()
            (destination / "onnx/model.onnx").symlink_to(target)

            with self.assertRaisesRegex(tool.FetchError, "symlink"):
                tool.check(lock_path, destination)

    def test_fetch_rejects_destination_inside_unrelated_repository(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            unrelated_repo = Path(temporary) / "other"
            (unrelated_repo / ".git").mkdir(parents=True)
            lock_path = self.write_lock(Path(temporary))

            with self.assertRaisesRegex(tool.DestinationError, "unrelated Git"):
                tool.fetch(lock_path, unrelated_repo / "models", opener=lambda _: None)

    def test_fetch_rejects_symlinked_destination(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_destination = root / "real"
            real_destination.mkdir()
            linked_destination = root / "linked"
            linked_destination.symlink_to(real_destination, target_is_directory=True)
            lock_path = self.write_lock(root)

            with self.assertRaisesRegex(tool.DestinationError, "symlink"):
                tool.fetch(lock_path, linked_destination, opener=lambda _: None)

    def test_fetch_rejects_symlinked_intermediate_destination_component(self):
        tool = load_tool()
        fixtures = {
            f"https://example.invalid/models/{REVISION}/onnx/model.onnx": self.model,
            f"https://example.invalid/models/{REVISION}/LICENSE": self.license,
        }

        def opener(request):
            return FixtureResponse(fixtures[request.full_url], request.full_url)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            container = root / "container"
            container.mkdir()
            (container / "linked").symlink_to(outside, target_is_directory=True)
            lock_path = self.write_lock(root)

            with self.assertRaisesRegex(tool.DestinationError, "symlink"):
                tool.fetch(
                    lock_path,
                    container / "linked/nested",
                    opener=opener,
                )

    def test_fetch_rejects_redirect_to_non_https_url(self):
        tool = load_tool()
        fixtures = {
            f"https://example.invalid/models/{REVISION}/onnx/model.onnx": self.model,
            f"https://example.invalid/models/{REVISION}/LICENSE": self.license,
        }

        def opener(request):
            final_url = request.full_url
            if request.full_url.endswith("model.onnx"):
                final_url = "http://cdn.example.invalid/model.onnx"
            return FixtureResponse(fixtures[request.full_url], final_url)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"

            with self.assertRaisesRegex(tool.VerificationError, "redirected to non-HTTPS"):
                tool.fetch(lock_path, destination, opener=opener)

            self.assertFalse((destination / "onnx/model.onnx").exists())

    def test_fetch_streams_validated_artifacts_then_offline_check_succeeds(self):
        tool = load_tool()
        fixtures = {
            f"https://example.invalid/models/{REVISION}/onnx/model.onnx": self.model,
            f"https://example.invalid/models/{REVISION}/LICENSE": self.license,
        }

        def opener(request):
            return FixtureResponse(fixtures[request.full_url], request.full_url)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"

            tool.fetch(lock_path, destination, opener=opener)

            self.assertEqual((destination / "onnx/model.onnx").read_bytes(), self.model)
            self.assertEqual((destination / "LICENSE").read_bytes(), self.license)
            self.assertFalse(any(destination.rglob("*.part")))
            with mock.patch.object(
                tool.urllib.request,
                "urlopen",
                side_effect=AssertionError("check attempted network access"),
            ):
                tool.check(lock_path, destination)

    def test_failed_fetch_does_not_install_or_leave_partial_file(self):
        tool = load_tool()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = self.lock_payload()
            payload["artifacts"] = [payload["artifacts"][0], payload["artifacts"][1]]
            lock_path = self.write_lock(root, payload)
            destination = root / "model"

            def opener(request):
                data = (
                    self.model + b"!"
                    if request.full_url.endswith("model.onnx")
                    else self.license
                )
                return FixtureResponse(data, request.full_url)

            with self.assertRaisesRegex(tool.VerificationError, "size mismatch"):
                tool.fetch(lock_path, destination, opener=opener)

            self.assertFalse((destination / "onnx/model.onnx").exists())
            self.assertFalse(any(destination.rglob("*.part")))

    def test_check_cli_reports_verified_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock_path = self.write_lock(root)
            destination = root / "model"
            self.write_fetched_files(destination)

            result = subprocess.run(
                [
                    sys.executable,
                    str(TOOL_PATH),
                    "check",
                    "--lock",
                    str(lock_path),
                    "--destination",
                    str(destination),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("verified 2 artifacts", result.stdout)


if __name__ == "__main__":
    unittest.main()
