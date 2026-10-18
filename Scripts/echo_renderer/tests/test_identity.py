from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

from echo_renderer.identity import (
    FileIdentity,
    ModelPolicy,
    RendererManifest,
    ResourceTreeIdentity,
    canonical_json_bytes,
    identify_regular_file,
    identify_resource_tree,
    manifest_payload,
    parse_manifest,
    strict_json_object,
)


VECTOR_ROOT = Path(__file__).parents[1] / "test_vectors"


def load_vector(name: str) -> dict[str, object]:
    with (VECTOR_ROOT / name).open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise AssertionError(f"{name} must contain a JSON object")
    return payload


def sample_manifest() -> RendererManifest:
    return RendererManifest(
        schema_version=1,
        echo_source_sha="0123456789abcdef0123456789abcdef01234567",
        installer_source_sha="89abcdef0123456789abcdef0123456789abcdef",
        executable_path="echo-cli",
        executable=FileIdentity(sha256="ab" * 32, byte_count=12345),
        resources_path="EchoNarrationResources",
        resources=ResourceTreeIdentity(sha256="cd" * 32, regular_file_count=4),
        render_version=15,
        build_configuration="Release",
        architectures=("arm64", "x86_64"),
        minimum_macos_version="15.0",
        model_policy=ModelPolicy(
            revision="kokoro-v1.0",
            expected_byte_count=325_566_778,
        ),
        capabilities=(
            "--cover",
            "--pronunciation-audit",
            "--pronunciation-mode",
            "--pronunciation-plan",
            "--pronunciation-reel",
        ),
    )


class CanonicalJSONTests(unittest.TestCase):
    def test_canonical_json_is_sorted_compact_utf8_with_one_newline(self):
        payload = {"z": "雪", "a": {"two": 2, "one": 1}}

        self.assertEqual(
            canonical_json_bytes(payload),
            b'{"a":{"one":1,"two":2},"z":"\xe9\x9b\xaa"}\n',
        )

    def test_strict_json_object_rejects_duplicate_keys_at_any_depth(self):
        for data in (
            b'{"value":1,"value":2}',
            b'{"outer":{"value":1,"value":2}}',
        ):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    strict_json_object(data)

    def test_strict_json_object_rejects_non_objects(self):
        for data in (b"[]", b"null", b'"text"'):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    strict_json_object(data)


class FileIdentityTests(unittest.TestCase):
    def test_identifies_regular_file_bytes(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "echo-cli"
            path.write_bytes(b"renderer bytes\n")

            self.assertEqual(
                identify_regular_file(path),
                FileIdentity(
                    sha256=hashlib.sha256(b"renderer bytes\n").hexdigest(),
                    byte_count=15,
                ),
            )

    def test_rejects_non_regular_files_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            regular = root / "regular"
            regular.write_bytes(b"bytes")
            link = root / "link"
            link.symlink_to(regular)
            fifo = root / "fifo"
            os.mkfifo(fifo)

            for path in (root, link, fifo):
                with self.subTest(path=path.name):
                    with self.assertRaises(ValueError):
                        identify_regular_file(path)


class ResourceTreeIdentityTests(unittest.TestCase):
    def test_checked_in_vectors_lock_the_resource_tree_protocol(self):
        vector = load_vector("resource-tree-v1.json")
        self.assertEqual(vector["schemaVersion"], 1)
        self.assertEqual(
            vector["framing"],
            {
                "fileDigest": "sha256-raw-32-bytes",
                "pathEncoding": "utf-8",
                "pathLength": "uint64-big-endian",
                "sort": "normalized-posix-relative-path",
            },
        )
        cases = vector["cases"]
        self.assertIsInstance(cases, list)
        self.assertEqual(
            {case["name"] for case in cases},
            {"empty", "nested", "unicode", "path-order"},
        )

        for case in cases:
            with self.subTest(case=case["name"]):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    for fixture in case["files"]:
                        path = root.joinpath(*fixture["path"].split("/"))
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(bytes.fromhex(fixture["contentHex"]))

                    expected = case["expected"]
                    self.assertEqual(
                        identify_resource_tree(root),
                        ResourceTreeIdentity(
                            sha256=expected["sha256"],
                            regular_file_count=expected["regularFileCount"],
                        ),
                    )

    def test_rejects_symlinked_root_and_entries(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            parent = Path(temporary_directory)
            root = parent / "resources"
            root.mkdir()
            (root / "voice.bin").write_bytes(b"voice")
            root_link = parent / "resources-link"
            root_link.symlink_to(root, target_is_directory=True)

            with self.assertRaises(ValueError):
                identify_resource_tree(root_link)

            (root / "voice-link.bin").symlink_to(root / "voice.bin")
            with self.assertRaises(ValueError):
                identify_resource_tree(root)

    def test_rejects_special_files(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            os.mkfifo(root / "resource.fifo")

            with self.assertRaises(ValueError):
                identify_resource_tree(root)


class ManifestTests(unittest.TestCase):
    def test_checked_in_vector_locks_canonical_manifest_bytes_and_sha(self):
        vector = load_vector("canonical-manifest-v1.json")
        payload = vector["payload"]
        expected_bytes = vector["canonicalUTF8"].encode("utf-8")

        self.assertEqual(canonical_json_bytes(payload), expected_bytes)
        self.assertEqual(hashlib.sha256(expected_bytes).hexdigest(), vector["sha256"])

        parsed = parse_manifest(expected_bytes)
        self.assertEqual(manifest_payload(parsed), payload)

    def test_manifest_round_trips_every_schema_v1_field(self):
        manifest = sample_manifest()
        data = canonical_json_bytes(manifest_payload(manifest))

        parsed = parse_manifest(data)

        self.assertEqual(parsed, manifest)
        self.assertIsInstance(parsed.architectures, tuple)
        self.assertIsInstance(parsed.capabilities, tuple)

    def test_rejects_unknown_manifest_and_nested_keys(self):
        payload = manifest_payload(sample_manifest())
        payload["unknown"] = True
        with self.assertRaises(ValueError):
            parse_manifest(canonical_json_bytes(payload))

        for field in ("executable", "resources", "modelPolicy"):
            with self.subTest(field=field):
                payload = manifest_payload(sample_manifest())
                payload[field]["unknown"] = True
                with self.assertRaises(ValueError):
                    parse_manifest(canonical_json_bytes(payload))

    def test_rejects_duplicate_manifest_keys(self):
        data = canonical_json_bytes(manifest_payload(sample_manifest()))
        forged = data[:-2] + b',"schemaVersion":1}\n'

        with self.assertRaises(ValueError):
            parse_manifest(forged)

    def test_rejects_invalid_sha_values(self):
        cases = (
            ("echoSourceSHA", "a" * 39),
            ("echoSourceSHA", "A" * 40),
            ("installerSourceSHA", "b" * 41),
            ("executable.sha256", "a" * 63),
            ("executable.sha256", "A" * 64),
            ("resources.sha256", "g" * 64),
        )
        for field, value in cases:
            with self.subTest(field=field, value=value):
                payload = manifest_payload(sample_manifest())
                if "." in field:
                    parent, child = field.split(".")
                    payload[parent][child] = value
                else:
                    payload[field] = value
                with self.assertRaises(ValueError):
                    parse_manifest(canonical_json_bytes(payload))

    def test_rejects_unsafe_relative_paths(self):
        unsafe_paths = (
            "/absolute/echo-cli",
            ".",
            "..",
            "./echo-cli",
            "bin/../echo-cli",
            "bin//echo-cli",
            "bin\\echo-cli",
            "echo-cli/",
        )
        for key in ("executablePath", "resourcesPath"):
            for unsafe_path in unsafe_paths:
                with self.subTest(key=key, path=unsafe_path):
                    payload = manifest_payload(sample_manifest())
                    payload[key] = unsafe_path
                    with self.assertRaises(ValueError):
                        parse_manifest(canonical_json_bytes(payload))

    def test_rejects_empty_architecture_and_capability_lists(self):
        for key in ("architectures", "capabilities"):
            payload = manifest_payload(sample_manifest())
            payload[key] = []
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    parse_manifest(canonical_json_bytes(payload))

    def test_rejects_non_positive_or_non_integer_render_versions(self):
        for value in (0, -1, True, False, "rv15", 15.0, None):
            with self.subTest(value=value):
                payload = manifest_payload(sample_manifest())
                payload["renderVersion"] = value
                with self.assertRaises(ValueError):
                    parse_manifest(canonical_json_bytes(payload))

    def test_accepts_a_positive_integer_render_version(self):
        payload = manifest_payload(sample_manifest())
        payload["renderVersion"] = 42
        parsed = parse_manifest(canonical_json_bytes(payload))
        self.assertEqual(parsed.render_version, 42)
        self.assertIsInstance(parsed.render_version, int)

    def test_rejects_attested_or_non_boolean_model_bytes(self):
        for value in (True, 0, None, "false"):
            with self.subTest(value=value):
                payload = manifest_payload(sample_manifest())
                payload["modelPolicy"]["modelBytesAttested"] = value
                with self.assertRaises(ValueError):
                    parse_manifest(canonical_json_bytes(payload))


if __name__ == "__main__":
    unittest.main()
