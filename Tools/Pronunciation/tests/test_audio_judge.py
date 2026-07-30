import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
import wave
from pathlib import Path
from unittest import mock

from Tools.Pronunciation import audio_judge
from Tools.Pronunciation.audio_judge import (
    CLIP_ID_PATTERN,
    MAXIMUM_ESTIMATED_COST_USD,
    MAXIMUM_REQUESTS,
    LedgerError,
    ManifestError,
    PermanentTransportError,
    ResponseValidationError,
    TransientTransportError,
    admit_manifest,
    build_request_body,
    encode_audio,
    enforce_prospective_cap,
    generate_clip_id,
    parse_verdict,
    read_attempt_state,
    record_attempt,
    record_rerender,
    run_evaluation,
    validate_clip_id,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY_ROOT / "Tools" / "Pronunciation" / "audio_judge.py"


class ClipIDTests(unittest.TestCase):
    def test_generated_clip_ids_are_canonical_random_uuid4_values(self):
        clip_ids = [generate_clip_id() for _ in range(32)]

        self.assertEqual(32, len(set(clip_ids)))
        for clip_id in clip_ids:
            self.assertRegex(clip_id, re.compile(CLIP_ID_PATTERN))
            parsed = uuid.UUID(clip_id.removeprefix("clip_"))
            self.assertEqual(4, parsed.version)
            self.assertEqual(uuid.RFC_4122, parsed.variant)
            self.assertEqual(clip_id, f"clip_{str(parsed)}")
            self.assertTrue(validate_clip_id(clip_id))


class ManifestAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_wav(self, clip_id, duration_seconds=0.25):
        path = self.directory / f"{clip_id}.wav"
        sample_rate = 8_000
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(b"\0\0" * int(sample_rate * duration_seconds))
        return path

    def transcode_mp3(self, source, clip_id):
        ffmpeg = shutil.which("ffmpeg")
        self.assertIsNotNone(ffmpeg, "ffmpeg is required for the MP3 contract test")
        path = self.directory / f"{clip_id}.mp3"
        subprocess.run(
            [
                ffmpeg,
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(source),
                str(path),
            ],
            check=True,
            capture_output=True,
        )
        return path

    def measured_duration(self, path):
        result = subprocess.run(
            [
                shutil.which("ffprobe") or "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return float(result.stdout.strip())

    def manifest_row(self, clip_id, path, duration_seconds, **overrides):
        row = {
            "clipID": clip_id,
            "provenance": "synthetic",
            "labelStatus": "provisional",
            "mediaType": "audio/wav" if path.suffix == ".wav" else "audio/mpeg",
            "durationSeconds": duration_seconds,
            "audioSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "deterministicExpectation": "pronunciation_acceptability",
            "sourceCommit": "a" * 40,
            "renderIdentity": f"sha256:{'b' * 64}",
        }
        row.update(overrides)
        return row

    def write_manifest(self, rows):
        path = self.directory / "manifest.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "corpusIdentity": "sha256:" + "c" * 64,
                    "clips": rows,
                }
            ),
            encoding="utf-8",
        )
        self.provenance_authority_path = (
            self.directory / "provenance-authority.json"
        )
        self.provenance_authority_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "authorizationPurpose":
                        "openai-pronunciation-audio-evaluation",
                    "clips": [
                        {
                            "clipID": row.get("clipID"),
                            "audioSHA256": row.get("audioSHA256"),
                            "durationSeconds": row.get("durationSeconds"),
                            "provenance": row.get("provenance"),
                        }
                        for row in rows
                    ],
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        return path

    def test_admits_measured_short_wav_and_mp3_with_exact_content_hashes(self):
        wav_id = generate_clip_id()
        wav_path = self.write_wav(wav_id)
        mp3_id = generate_clip_id()
        mp3_path = self.transcode_mp3(wav_path, mp3_id)
        rows = [
            self.manifest_row(wav_id, wav_path, 0.25),
            self.manifest_row(
                mp3_id,
                mp3_path,
                self.measured_duration(mp3_path),
                provenance="public-domain",
            ),
        ]

        clips = admit_manifest(self.write_manifest(rows))

        self.assertEqual([wav_id, mp3_id], [clip.clip_id for clip in clips])
        self.assertEqual(["wav", "mp3"], [clip.audio_format for clip in clips])
        for clip, path in zip(clips, [wav_path, mp3_path], strict=True):
            encoded = encode_audio(clip)
            self.assertEqual(path.read_bytes(), base64.b64decode(encoded["data"]))
        self.assertEqual("audio/wav", encode_audio(clips[0])["mediaType"])
        self.assertEqual("audio/mpeg", encode_audio(clips[1])["mediaType"])

    def test_rejects_ineligible_or_unverified_manifest_before_encoding(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        valid = self.manifest_row(clip_id, path, 0.25)
        invalid_rows = [
            {**valid, "provenance": "private"},
            {**valid, "provenance": "copyrighted"},
            {**valid, "durationSeconds": 0.5},
            {**valid, "durationSeconds": 15.01},
            {**valid, "audioSHA256": "0" * 64},
            {**valid, "rawText": "forbidden"},
            {**valid, "author": "forbidden"},
            {**valid, "localPath": str(path)},
        ]

        for row in invalid_rows:
            with self.subTest(row=row):
                with self.assertRaises(ManifestError):
                    admit_manifest(self.write_manifest([row]))

    def test_rejects_duplicate_or_noncanonical_clip_ids(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        row = self.manifest_row(clip_id, path, 0.25)

        with self.assertRaises(ManifestError):
            admit_manifest(self.write_manifest([row, row]))

        invalid_id = clip_id.upper()
        invalid_path = self.write_wav(invalid_id)
        invalid_row = self.manifest_row(invalid_id, invalid_path, 0.25)
        with self.assertRaises(ManifestError):
            admit_manifest(self.write_manifest([invalid_row]))

    def test_rejects_empty_corpus_caller_cost_estimates_and_tainted_identifiers(self):
        with self.assertRaises(ManifestError):
            admit_manifest(self.write_manifest([]))

        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        valid = self.manifest_row(clip_id, path, 0.25)
        invalid_rows = [
            {**valid, "estimatedTextInputTokens": 1},
            {**valid, "estimatedAudioInputTokens": 1},
            {**valid, "maxTextOutputTokens": 1},
            {**valid, "corpusID": "book-title-or-caller-label"},
            {**valid, "deterministicExpectation": "record.verb"},
            {**valid, "deterministicExpectation": "/private/book.m4b"},
            {**valid, "deterministicExpectation": ""},
        ]
        for row in invalid_rows:
            with self.subTest(row=row):
                with self.assertRaises(ManifestError):
                    admit_manifest(self.write_manifest([row]))

    def test_rejects_extension_and_media_type_that_do_not_match_container_and_codec(self):
        wav_id = generate_clip_id()
        wav_path = self.write_wav(wav_id)
        fake_mp3_id = generate_clip_id()
        fake_mp3 = self.directory / f"{fake_mp3_id}.mp3"
        shutil.copyfile(wav_path, fake_mp3)

        with self.assertRaises(ManifestError):
            admit_manifest(
                self.write_manifest(
                    [
                        self.manifest_row(
                            fake_mp3_id,
                            fake_mp3,
                            self.measured_duration(fake_mp3),
                        )
                    ]
                )
            )

        mp3_id = generate_clip_id()
        mp3_path = self.transcode_mp3(wav_path, mp3_id)
        fake_wav_id = generate_clip_id()
        fake_wav = self.directory / f"{fake_wav_id}.wav"
        shutil.copyfile(mp3_path, fake_wav)
        with self.assertRaises(ManifestError):
            admit_manifest(
                self.write_manifest(
                    [
                        self.manifest_row(
                            fake_wav_id,
                            fake_wav,
                            self.measured_duration(fake_wav),
                        )
                    ]
                )
            )

    def test_manifest_provenance_requires_a_separate_exact_external_authority(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        row = self.manifest_row(clip_id, path, 0.25)
        manifest = self.write_manifest([row])
        authority = self.provenance_authority_path
        valid_authority = json.loads(authority.read_text(encoding="utf-8"))

        authority.unlink()
        with self.assertRaisesRegex(ManifestError, "provenance authority"):
            admit_manifest(manifest)

        for field, value in (
            ("audioSHA256", "0" * 64),
            ("durationSeconds", 0.5),
            ("provenance", "public-domain"),
        ):
            with self.subTest(field=field):
                changed = json.loads(json.dumps(valid_authority))
                changed["clips"][0][field] = value
                authority.write_text(
                    json.dumps(changed, sort_keys=True),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    ManifestError,
                    "provenance authority",
                ):
                    admit_manifest(manifest)

        authority_target = self.directory / "authority-target.json"
        authority_target.write_text(
            json.dumps(valid_authority, sort_keys=True),
            encoding="utf-8",
        )
        authority.unlink(missing_ok=True)
        authority.symlink_to(authority_target)
        with self.assertRaisesRegex(ManifestError, "provenance authority"):
            admit_manifest(manifest)

        authority.unlink()
        authority_before = authority_target.read_bytes()
        os.link(authority_target, authority)
        with self.assertRaisesRegex(ManifestError, "provenance authority"):
            admit_manifest(manifest)
        self.assertEqual(authority_before, authority_target.read_bytes())

    def test_admission_rejects_non_exact_manifest_scalars_before_request_or_receipt(self):
        clip_id = generate_clip_id()
        audio_path = self.write_wav(clip_id)
        row = self.manifest_row(clip_id, audio_path, 0.25)
        invalid_values = (["nested"], {"nested": "invalid"}, True, 10**1000)
        probes = (
            ("manifest", "schemaVersion"),
            ("manifest", "corpusIdentity"),
            ("clip", "clipID"),
            ("clip", "provenance"),
            ("clip", "labelStatus"),
            ("clip", "mediaType"),
            ("clip", "durationSeconds"),
            ("clip", "audioSHA256"),
            ("clip", "deterministicExpectation"),
            ("clip", "sourceCommit"),
            ("clip", "renderIdentity"),
        )
        output_root = self.directory / "runs"
        transport = mock.Mock()

        for probe_index, (scope, field) in enumerate(probes):
            for value_index, value in enumerate(invalid_values):
                with self.subTest(scope=scope, field=field, value=value):
                    manifest_path = self.write_manifest([row])
                    manifest = json.loads(
                        manifest_path.read_text(encoding="utf-8")
                    )
                    target = manifest if scope == "manifest" else manifest["clips"][0]
                    target[field] = value
                    manifest_path.write_text(
                        json.dumps(manifest),
                        encoding="utf-8",
                    )
                    run_id = f"invalid-manifest-{probe_index}-{value_index}"

                    with self.assertRaises(ManifestError):
                        run_evaluation(
                            manifest_path=manifest_path,
                            run_id=run_id,
                            dry_run=False,
                            output_root=output_root,
                            environment={"OPENAI_API_KEY": "test-only-key"},
                            transport=transport,
                        )

                    self.assertFalse((output_root / run_id).exists())

        transport.assert_not_called()

    def test_admission_rejects_non_exact_authority_scalars_before_request_or_receipt(self):
        clip_id = generate_clip_id()
        audio_path = self.write_wav(clip_id)
        row = self.manifest_row(clip_id, audio_path, 0.25)
        invalid_values = (["nested"], {"nested": "invalid"}, True, 10**1000)
        probes = (
            ("authority", "schemaVersion"),
            ("authority", "authorizationPurpose"),
            ("binding", "clipID"),
            ("binding", "audioSHA256"),
            ("binding", "durationSeconds"),
            ("binding", "provenance"),
        )
        output_root = self.directory / "runs"
        transport = mock.Mock()

        for probe_index, (scope, field) in enumerate(probes):
            for value_index, value in enumerate(invalid_values):
                with self.subTest(scope=scope, field=field, value=value):
                    manifest_path = self.write_manifest([row])
                    authority_path = self.provenance_authority_path
                    authority = json.loads(
                        authority_path.read_text(encoding="utf-8")
                    )
                    target = (
                        authority
                        if scope == "authority"
                        else authority["clips"][0]
                    )
                    target[field] = value
                    authority_path.write_text(
                        json.dumps(authority),
                        encoding="utf-8",
                    )
                    run_id = f"invalid-authority-{probe_index}-{value_index}"

                    with self.assertRaises(ManifestError):
                        run_evaluation(
                            manifest_path=manifest_path,
                            run_id=run_id,
                            dry_run=False,
                            output_root=output_root,
                            environment={"OPENAI_API_KEY": "test-only-key"},
                            transport=transport,
                        )

                    self.assertFalse((output_root / run_id).exists())

        transport.assert_not_called()


class ResponseValidationTests(unittest.TestCase):
    def setUp(self):
        self.clip_id = generate_clip_id()
        self.valid = {
            "clipID": self.clip_id,
            "verdict": "pass",
            "confidence": 0.8,
            "category": "correct",
            "heard": "record",
            "note": "The expected pronunciation is audible.",
        }

    def test_accepts_only_the_closed_duplicate_free_verdict_shape(self):
        self.assertEqual(
            self.valid,
            parse_verdict(json.dumps(self.valid), expected_clip_id=self.clip_id),
        )

        invalid_payloads = [
            {**self.valid, "extra": True},
            {key: value for key, value in self.valid.items() if key != "verdict"},
            {**self.valid, "clipID": generate_clip_id()},
            {**self.valid, "verdict": "maybe"},
            {**self.valid, "confidence": True},
            {**self.valid, "confidence": -0.01},
            {**self.valid, "confidence": 1.01},
            {**self.valid, "category": "grammar"},
            {**self.valid, "heard": "x" * 161},
            {**self.valid, "note": "x" * 401},
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(ResponseValidationError):
                    parse_verdict(
                        json.dumps(payload),
                        expected_clip_id=self.clip_id,
                    )

        duplicate = (
            '{"clipID":"%s","verdict":"pass","verdict":"fail",'
            '"confidence":0.8,"category":"correct"}' % self.clip_id
        )
        malformed = [
            duplicate,
            f"```json\n{json.dumps(self.valid)}\n```",
            f"result: {json.dumps(self.valid)}",
            '{"clipID":"%s","verdict":"pass","confidence":NaN,'
            '"category":"correct"}' % self.clip_id,
        ]
        for payload in malformed:
            with self.subTest(payload=payload):
                with self.assertRaises(ResponseValidationError):
                    parse_verdict(payload, expected_clip_id=self.clip_id)

    def test_closed_vocabulary_accepts_boundary_confidence_and_optional_omission(self):
        for verdict in ("pass", "fail", "uncertain"):
            for confidence in (0.0, 1.0):
                for category in (
                    "correct",
                    "wrong_word",
                    "wrong_sense",
                    "stress",
                    "vowel",
                    "consonant",
                    "timing",
                    "artifact",
                    "inaudible",
                    "other",
                ):
                    payload = {
                        "clipID": self.clip_id,
                        "verdict": verdict,
                        "confidence": confidence,
                        "category": category,
                    }
                    self.assertEqual(
                        payload,
                        parse_verdict(
                            json.dumps(payload),
                            expected_clip_id=self.clip_id,
                        ),
                    )

    def test_nested_response_field_types_raise_controlled_validation_errors(self):
        for field in (
            "clipID",
            "verdict",
            "confidence",
            "category",
            "heard",
            "note",
        ):
            with self.subTest(field=field):
                payload = {
                    **self.valid,
                    field: {"nested-response-marker": "invalid"},
                }
                with self.assertRaises(ResponseValidationError):
                    parse_verdict(
                        json.dumps(payload),
                        expected_clip_id=self.clip_id,
                    )

    def test_unbounded_integer_confidence_raises_a_controlled_validation_error(self):
        payload = {
            **self.valid,
            "confidence": 10**1000,
        }

        with self.assertRaises(ResponseValidationError):
            parse_verdict(
                json.dumps(payload),
                expected_clip_id=self.clip_id,
            )


class EvaluationGateTests(ManifestAdmissionTests):
    def test_paid_transport_returning_none_is_malformed_and_never_passes(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="missing-paid-response",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=lambda _body, _key: None,
        )

        self.assertEqual("COMPLETED", receipt["status"])
        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(1, receipt["requestCount"])
        self.assertEqual(1, receipt["transportAttemptCount"])
        self.assertEqual(
            [
                {
                    "clipID": clip_id,
                    "queueCategory": "provisional_review",
                    "reasons": ["malformed_output"],
                }
            ],
            receipt["morningQueue"],
        )
        result = receipt["results"][0]
        self.assertIsNone(result["returnedModelID"])
        self.assertIsNone(result["verdict"])
        self.assertEqual({}, result["usage"])
        self.assertEqual("not_validated", result["validationOutcome"])
        self.assertNotIn("response", result)
        self.assertNotIn("content", result)
        self.assertNotIn("refusal", result)
        reservations = [
            json.loads(line)
            for line in (
                output_root
                / "missing-paid-response"
                / "request-reservations.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(1, len(reservations))
        self.assertEqual(1, reservations[0]["requestNumber"])
        self.assertEqual(clip_id, reservations[0]["clipID"])

    def test_api_message_array_is_controlled_and_never_leaves_running_receipt(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        api_response = mock.MagicMock()
        api_response.__enter__.return_value.read.return_value = json.dumps(
            {
                "model": "gpt-audio-1.5",
                "choices": [{"message": []}],
                "usage": {},
            }
        ).encode("utf-8")

        with mock.patch.object(
            audio_judge.urllib.request,
            "urlopen",
            return_value=api_response,
        ):
            receipt = run_evaluation(
                manifest_path=manifest,
                run_id="message-array",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=audio_judge._post_chat_completion,
            )

        self.assertEqual("COMPLETED", receipt["status"])
        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["transport_failure"],
            receipt["morningQueue"][0]["reasons"],
        )
        durable = json.loads(
            (output_root / "message-array" / "receipt.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual("COMPLETED", durable["status"])

    def test_falsey_non_null_refusal_scalars_are_malformed_and_never_pass(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        content = json.dumps(
            {
                "clipID": clip_id,
                "verdict": "pass",
                "confidence": 0.95,
                "category": "correct",
            }
        )

        for index, refusal in enumerate((False, [], {}, 0)):
            with self.subTest(refusal=refusal):
                receipt = run_evaluation(
                    manifest_path=manifest,
                    run_id=f"falsey-refusal-{index}",
                    dry_run=False,
                    output_root=self.directory / "runs",
                    environment={"OPENAI_API_KEY": "test-only-key"},
                    transport=mock.Mock(
                        return_value={
                            "model": "gpt-audio-1.5",
                            "content": content,
                            "refusal": refusal,
                            "usage": {},
                        }
                    ),
                )

                self.assertEqual(
                    "needs_review",
                    receipt["apiEvaluationStatus"],
                )
                self.assertEqual(
                    ["malformed_output"],
                    receipt["morningQueue"][0]["reasons"],
                )
                self.assertIsNone(receipt["results"][0]["verdict"])

    def test_unbounded_api_usage_integer_is_rejected_and_never_persisted(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        huge_count = 10**1000
        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="unbounded-usage",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(
                return_value={
                    "model": "gpt-audio-1.5",
                    "content": json.dumps(
                        {
                            "clipID": clip_id,
                            "verdict": "pass",
                            "confidence": 0.95,
                            "category": "correct",
                        }
                    ),
                    "usage": {"prompt_tokens": huge_count},
                }
            ),
        )

        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["malformed_output"],
            receipt["morningQueue"][0]["reasons"],
        )
        self.assertEqual({}, receipt["results"][0]["usage"])
        self.assertNotIn(str(huge_count), json.dumps(receipt))

    def test_oversized_json_integers_translate_at_every_parse_boundary(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        authority = self.provenance_authority_path
        huge_digits = "9" * 5000
        original_manifest = manifest.read_text(encoding="utf-8")
        original_authority = authority.read_text(encoding="utf-8")

        manifest.write_text(
            original_manifest.replace(
                '"schemaVersion": 1',
                f'"schemaVersion": {huge_digits}',
                1,
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ManifestError):
            admit_manifest(manifest)
        manifest.write_text(original_manifest, encoding="utf-8")

        authority.write_text(
            original_authority.replace(
                '"schemaVersion": 1',
                f'"schemaVersion": {huge_digits}',
                1,
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ManifestError):
            admit_manifest(manifest)
        authority.write_text(original_authority, encoding="utf-8")

        with self.assertRaises(ResponseValidationError):
            parse_verdict(
                (
                    f'{{"clipID":"{clip_id}","verdict":"pass",'
                    f'"confidence":{huge_digits},"category":"correct"}}'
                ),
                expected_clip_id=clip_id,
            )

        api_response = mock.MagicMock()
        api_response.__enter__.return_value.read.return_value = (
            (
                '{"model":"gpt-audio-1.5","choices":[{"message":'
                '{"content":"{}","refusal":null}}],"usage":'
                f'{{"prompt_tokens":{huge_digits}}}}}'
            ).encode("utf-8")
        )
        with (
            mock.patch.object(
                audio_judge.urllib.request,
                "urlopen",
                return_value=api_response,
            ),
            self.assertRaises(PermanentTransportError),
        ):
            audio_judge._post_chat_completion({}, "test-only-key")

    def test_non_string_run_identifiers_fail_controlled_before_regex_or_io(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        transport = mock.Mock(side_effect=AssertionError("must not be called"))

        for run_id in ([], True, {}):
            with self.subTest(run_id=run_id):
                with self.assertRaisesRegex(
                    ManifestError,
                    "run identifier is invalid",
                ):
                    run_evaluation(
                        manifest_path=manifest,
                        run_id=run_id,
                        dry_run=False,
                        output_root=output_root,
                        environment={"OPENAI_API_KEY": "test-only-key"},
                        transport=transport,
                    )

        transport.assert_not_called()
        self.assertFalse(output_root.exists())

    def test_receipt_binds_the_single_manifest_snapshot_admitted_before_replacement(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        admitted_bytes = manifest.read_bytes()
        admitted_identity = "sha256:" + "c" * 64
        replacement = self.directory / "replacement-manifest.json"
        replacement.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "corpusIdentity": "sha256:" + "d" * 64,
                    "clips": [
                        self.manifest_row(clip_id, path, 0.25)
                    ],
                }
            ),
            encoding="utf-8",
        )
        replacement_hash = hashlib.sha256(replacement.read_bytes()).hexdigest()
        real_admission = audio_judge._admit_manifest_with_authority

        def replace_after_admission(*args, **kwargs):
            admitted = real_admission(*args, **kwargs)
            replacement.replace(manifest)
            return admitted

        with mock.patch.object(
            audio_judge,
            "_admit_manifest_with_authority",
            side_effect=replace_after_admission,
        ):
            receipt = run_evaluation(
                manifest_path=manifest,
                run_id="manifest-snapshot",
                dry_run=True,
                output_root=self.directory / "runs",
            )

        self.assertEqual(admitted_identity, receipt["corpusIdentity"])
        self.assertEqual(
            hashlib.sha256(admitted_bytes).hexdigest(),
            receipt["manifestContentSHA256"],
        )
        self.assertNotEqual(replacement_hash, receipt["manifestContentSHA256"])

    def test_prospective_request_and_cost_caps_use_the_stricter_limit(self):
        enforce_prospective_cap(
            request_count=199,
            estimated_cost_usd=9.0,
            next_request_estimate_usd=1.0,
        )
        with self.assertRaises(ManifestError):
            enforce_prospective_cap(
                request_count=MAXIMUM_REQUESTS,
                estimated_cost_usd=0.0,
                next_request_estimate_usd=0.01,
            )
        with self.assertRaises(ManifestError):
            enforce_prospective_cap(
                request_count=0,
                estimated_cost_usd=MAXIMUM_ESTIMATED_COST_USD,
                next_request_estimate_usd=0.01,
            )

    def test_request_contains_direct_audio_and_no_local_metadata(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        clip = admit_manifest(
            self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        )[0]

        body = build_request_body(clip)

        serialized = json.dumps(body, sort_keys=True)
        self.assertEqual("gpt-audio-1.5", body["model"])
        self.assertEqual(["text"], body["modalities"])
        self.assertEqual(180, body["max_completion_tokens"])
        prompt = body["messages"][0]["content"][0]["text"]
        for value in ("pass", "fail", "uncertain"):
            self.assertIn(value, prompt)
        for value in (
            "correct",
            "wrong_word",
            "wrong_sense",
            "stress",
            "vowel",
            "consonant",
            "timing",
            "artifact",
            "inaudible",
            "other",
        ):
            self.assertIn(value, prompt)
        audio_item = body["messages"][0]["content"][1]
        self.assertEqual("input_audio", audio_item["type"])
        self.assertEqual("wav", audio_item["input_audio"]["format"])
        self.assertEqual(
            path.read_bytes(),
            base64.b64decode(audio_item["input_audio"]["data"]),
        )
        for forbidden in (
            str(path),
            "localPath",
            "bookTitle",
            "author",
            "userID",
            "Authorization",
            "OPENAI_API_KEY",
        ):
            self.assertNotIn(forbidden, serialized)
        self.assertNotIn("heard/note", serialized)

    def test_run_claim_and_request_reservation_are_durable_before_transport(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        observations = {}

        def transport(_body, _key):
            run_directory = output_root / "durable"
            observations["claim"] = json.loads(
                (run_directory / "run-claim.json").read_text(encoding="utf-8")
            )
            observations["reservations"] = [
                json.loads(line)
                for line in (
                    run_directory / "request-reservations.jsonl"
                ).read_text(encoding="utf-8").splitlines()
            ]
            observations["receipt"] = json.loads(
                (run_directory / "receipt.json").read_text(encoding="utf-8")
            )
            return {
                "model": "gpt-audio-1.5",
                "content": json.dumps(
                    {
                        "clipID": clip_id,
                        "verdict": "pass",
                        "confidence": 0.9,
                        "category": "correct",
                    }
                ),
                "usage": {},
            }

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="durable",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=transport,
        )

        self.assertEqual("durable", observations["claim"]["runID"])
        self.assertEqual(1, len(observations["reservations"]))
        self.assertEqual(1, observations["receipt"]["requestCount"])
        self.assertEqual("RUNNING", observations["receipt"]["status"])
        original_receipt_bytes = (
            output_root / "durable" / "receipt.json"
        ).read_bytes()
        with self.assertRaises(ManifestError):
            run_evaluation(
                manifest_path=manifest,
                run_id="durable",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=mock.Mock(side_effect=AssertionError("must not run")),
            )
        self.assertEqual(
            original_receipt_bytes,
            (output_root / "durable" / "receipt.json").read_bytes(),
        )
        self.assertEqual(1, receipt["requestCount"])

    def test_initial_and_retry_reservations_fsync_the_directory_before_transport(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        events = []
        transport_count = 0
        real_directory_fsync = audio_judge._fsync_directory

        def tracked_directory_fsync(directory):
            reservations = directory / "request-reservations.jsonl"
            if reservations.is_file():
                events.append(
                    "directory-fsync-"
                    + str(len(reservations.read_text(encoding="utf-8").splitlines()))
                )
            return real_directory_fsync(directory)

        def transport(_body, _key):
            nonlocal transport_count
            transport_count += 1
            events.append(f"transport-{transport_count}")
            if transport_count == 1:
                raise TransientTransportError()
            return {
                "model": "gpt-audio-1.5",
                "content": json.dumps(
                    {
                        "clipID": clip_id,
                        "verdict": "pass",
                        "confidence": 0.9,
                        "category": "correct",
                    }
                ),
                "usage": {},
            }

        with mock.patch.object(
            audio_judge,
            "_fsync_directory",
            side_effect=tracked_directory_fsync,
        ):
            run_evaluation(
                manifest_path=manifest,
                run_id="reservation-directory-fsync",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=transport,
            )

        self.assertEqual(
            [
                "directory-fsync-1",
                "transport-1",
                "directory-fsync-2",
                "transport-2",
            ],
            events,
        )

    def test_run_root_rejects_repository_and_symlink_paths_before_mutation(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        original_mkdir = Path.mkdir

        def reject_repository_mkdir(candidate, *args, **kwargs):
            if candidate == REPOSITORY_ROOT or candidate.is_relative_to(
                REPOSITORY_ROOT
            ):
                raise AssertionError("repository mutation attempted")
            return original_mkdir(candidate, *args, **kwargs)

        with mock.patch.object(Path, "mkdir", new=reject_repository_mkdir):
            with self.assertRaisesRegex(ManifestError, "outside the repository"):
                run_evaluation(
                    manifest_path=manifest,
                    run_id="forbidden-repository-root",
                    dry_run=True,
                    output_root=REPOSITORY_ROOT,
                    environment={},
                )

        actual_root = self.directory / "actual-runs"
        actual_root.mkdir()
        linked_root = self.directory / "linked-runs"
        linked_root.symlink_to(actual_root, target_is_directory=True)
        with self.assertRaisesRegex(ManifestError, "symlink"):
            run_evaluation(
                manifest_path=manifest,
                run_id="linked-root",
                dry_run=True,
                output_root=linked_root,
                environment={},
            )

    def test_preexisting_run_artifact_fails_closed_before_transport(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        preexisting = output_root / "claimed"
        preexisting.mkdir(parents=True)
        (preexisting / "receipt.json").write_text("do not overwrite", encoding="utf-8")
        transport = mock.Mock(side_effect=AssertionError("must not run"))

        with self.assertRaises(ManifestError):
            run_evaluation(
                manifest_path=manifest,
                run_id="claimed",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=transport,
            )

        transport.assert_not_called()
        self.assertEqual(
            "do not overwrite",
            (preexisting / "receipt.json").read_text(encoding="utf-8"),
        )

    def test_dry_run_and_missing_credential_never_construct_a_request(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        transport = mock.Mock(side_effect=AssertionError("must not be called"))

        dry_run = run_evaluation(
            manifest_path=manifest,
            run_id="dry-run",
            dry_run=True,
            output_root=output_root,
            environment={},
            transport=transport,
        )
        waiting = run_evaluation(
            manifest_path=manifest,
            run_id="waiting",
            dry_run=False,
            output_root=output_root,
            environment={},
            transport=transport,
        )

        transport.assert_not_called()
        self.assertEqual("DRY_RUN_COMPLETE", dry_run["status"])
        self.assertEqual("NOT_RUN_DRY_RUN", dry_run["apiEvaluationStatus"])
        self.assertEqual("WAITING_FOR_USER", waiting["status"])
        self.assertIsNone(waiting["apiEvaluationStatus"])
        self.assertNotIn("passed", json.dumps(waiting).casefold())
        self.assertNotIn("failed", json.dumps(waiting).casefold())

    def test_transient_transport_gets_one_retry_but_malformed_output_does_not(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    clip_id,
                    path,
                    0.25,
                    labelStatus="human-labelled",
                )
            ]
        )
        output_root = self.directory / "runs"
        response = {
            "model": "gpt-audio-1.5",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.95,
                    "category": "correct",
                }
            ),
            "usage": {
                "prompt_tokens": 42,
                "completion_tokens": 18,
                "total_tokens": 60,
            },
        }
        transient_then_success = mock.Mock(
            side_effect=[TransientTransportError(), response]
        )

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="retry",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=transient_then_success,
        )

        self.assertEqual(2, transient_then_success.call_count)
        self.assertEqual("COMPLETED", receipt["status"])
        self.assertEqual("passed", receipt["apiEvaluationStatus"])
        self.assertEqual(2, receipt["requestCount"])
        self.assertEqual(2, receipt["transportAttemptCount"])
        self.assertEqual("validated_after_retry", receipt["results"][0]["validationOutcome"])
        reservations = [
            json.loads(line)
            for line in (
                output_root / "retry" / "request-reservations.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual([1, 2], [row["requestNumber"] for row in reservations])
        self.assertEqual(
            receipt["estimatedCostUSD"],
            round(sum(row["estimatedCostUSD"] for row in reservations), 8),
        )

        malformed_transport = mock.Mock(
            return_value={
                "model": "gpt-audio-1.5",
                "content": "not json",
                "usage": {},
            }
        )
        malformed_receipt = run_evaluation(
            manifest_path=manifest,
            run_id="malformed",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=malformed_transport,
        )
        self.assertEqual(1, malformed_transport.call_count)
        self.assertEqual("needs_review", malformed_receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["malformed_output"],
            malformed_receipt["morningQueue"][0]["reasons"],
        )

    def test_unbounded_integer_confidence_routes_to_malformed_morning_review(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        huge_confidence = 10**1000
        transport = mock.Mock(
            return_value={
                "model": "gpt-audio-1.5",
                "content": json.dumps(
                    {
                        "clipID": clip_id,
                        "verdict": "pass",
                        "confidence": huge_confidence,
                        "category": "correct",
                    }
                ),
                "usage": {},
            }
        )

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="huge-confidence",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=transport,
        )

        self.assertEqual(1, transport.call_count)
        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["malformed_output"],
            receipt["morningQueue"][0]["reasons"],
        )
        self.assertIsNone(receipt["results"][0]["verdict"])
        self.assertNotIn(str(huge_confidence), json.dumps(receipt))

    def test_retry_is_blocked_before_it_would_exceed_the_hard_cost_cap(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    clip_id,
                    path,
                    0.25,
                    labelStatus="human-labelled",
                )
            ]
        )
        transport = mock.Mock(side_effect=TransientTransportError())

        with mock.patch(
            "Tools.Pronunciation.audio_judge.MAXIMUM_ESTIMATED_COST_USD",
            0.14,
        ):
            receipt = run_evaluation(
                manifest_path=manifest,
                run_id="retry-cost-cap",
                dry_run=False,
                output_root=self.directory / "runs",
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=transport,
            )

        self.assertEqual(1, transport.call_count)
        self.assertEqual(1, receipt["requestCount"])
        self.assertLessEqual(
            receipt["estimatedCostUSD"],
            MAXIMUM_ESTIMATED_COST_USD,
        )
        self.assertEqual(
            "retry_blocked_by_cap",
            receipt["results"][0]["retryOutcome"],
        )
        self.assertEqual(
            ["transport_failure"],
            receipt["morningQueue"][0]["reasons"],
        )

    def test_routes_every_machine_uncertainty_without_relabeling_provisional_data(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        uncertain = {
            "model": "gpt-audio-1.5",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "uncertain",
                    "confidence": 0.79,
                    "category": "other",
                }
            ),
            "usage": {},
        }

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="uncertain",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=uncertain),
        )

        self.assertEqual(
            ["low_confidence", "uncertain"],
            receipt["morningQueue"][0]["reasons"],
        )
        self.assertEqual(
            "provisional_review",
            receipt["morningQueue"][0]["queueCategory"],
        )
        result = receipt["results"][0]
        self.assertEqual("provisional_evidence", result["evidenceCategory"])
        for key in (
            "accuracyContribution",
            "humanLabelContribution",
            "humanListeningContribution",
            "qualificationContribution",
            "touchedFamilyGraduation",
            "phase3Graduation",
        ):
            self.assertFalse(result[key])

    def test_human_labelled_machine_verdict_never_contributes_accuracy_or_human_proof(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    clip_id,
                    path,
                    0.25,
                    labelStatus="human-labelled",
                )
            ]
        )
        response = {
            "model": "gpt-audio-1.5",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 1.0,
                    "category": "correct",
                }
            ),
            "usage": {},
        }

        result = run_evaluation(
            manifest_path=manifest,
            run_id="human-labelled-boundary",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )["results"][0]

        self.assertEqual("machine_evidence", result["evidenceCategory"])
        for key in (
            "accuracyContribution",
            "humanLabelContribution",
            "humanListeningContribution",
            "qualificationContribution",
            "touchedFamilyGraduation",
            "phase3Graduation",
        ):
            self.assertFalse(result[key])

    def test_optional_diagnostic_text_is_validated_but_never_persisted(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        secret_heard = "private-heard-marker"
        secret_note = "private-note-marker"
        response = {
            "model": "gpt-audio-1.5",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.9,
                    "category": "correct",
                    "heard": secret_heard,
                    "note": secret_note,
                }
            ),
            "usage": {},
        }
        output_root = self.directory / "runs"

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="diagnostic-redaction",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )

        self.assertEqual(
            {"clipID", "verdict", "confidence", "category"},
            set(receipt["results"][0]["verdict"]),
        )
        for artifact in output_root.joinpath("diagnostic-redaction").iterdir():
            if artifact.is_file():
                persisted = artifact.read_text(encoding="utf-8", errors="ignore")
                self.assertNotIn(secret_heard, persisted)
                self.assertNotIn(secret_note, persisted)

    def test_nested_verdict_vocabularies_never_escape_or_persist(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        for field_index, field in enumerate(("verdict", "category")):
            with self.subTest(field=field):
                verdict = {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.95,
                    "category": "correct",
                }
                verdict[field] = {
                    "nested-response-marker": "must-not-persist"
                }
                receipt = run_evaluation(
                    manifest_path=manifest,
                    run_id=f"nested-response-{field_index}",
                    dry_run=False,
                    output_root=output_root,
                    environment={"OPENAI_API_KEY": "test-only-key"},
                    transport=mock.Mock(
                        return_value={
                            "model": "gpt-audio-1.5",
                            "content": json.dumps(verdict),
                            "usage": {},
                        }
                    ),
                )

                self.assertEqual(
                    "malformed_output",
                    receipt["morningQueue"][0]["reasons"][0],
                )
                persisted = b"".join(
                    path.read_bytes()
                    for path in (
                        output_root / f"nested-response-{field_index}"
                    ).iterdir()
                    if path.is_file()
                )
                self.assertNotIn(b"nested-response-marker", persisted)

    def test_revalidates_content_container_and_duration_before_each_transport_attempt(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        transport_calls = 0

        def mutate_then_retry(_body, _key):
            nonlocal transport_calls
            transport_calls += 1
            self.write_wav(clip_id, duration_seconds=0.20)
            raise TransientTransportError()

        with self.assertRaises(ManifestError):
            run_evaluation(
                manifest_path=manifest,
                run_id="toctou",
                dry_run=False,
                output_root=self.directory / "runs",
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=mutate_then_retry,
            )

        self.assertEqual(1, transport_calls)
        durable = json.loads(
            (
                self.directory
                / "runs"
                / "toctou"
                / "receipt.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual("RUNNING", durable["status"])
        self.assertEqual(1, durable["requestCount"])

    def test_retry_rejects_a_symlinked_reservation_file_without_touching_target(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        sentinel = self.directory / "reservation-sentinel"
        sentinel.write_text("unchanged\n", encoding="utf-8")
        transport_count = 0

        def replace_reservation_with_symlink(_body, _key):
            nonlocal transport_count
            transport_count += 1
            if transport_count == 1:
                reservation = (
                    output_root
                    / "reservation-symlink"
                    / "request-reservations.jsonl"
                )
                reservation.unlink()
                reservation.symlink_to(sentinel)
                raise TransientTransportError()
            raise AssertionError("retry transport must not run")

        with self.assertRaisesRegex(ManifestError, "reservation"):
            run_evaluation(
                manifest_path=manifest,
                run_id="reservation-symlink",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=replace_reservation_with_symlink,
            )

        self.assertEqual(1, transport_count)
        self.assertEqual("unchanged\n", sentinel.read_text(encoding="utf-8"))

    def test_retry_rejects_a_hardlinked_reservation_file_without_touching_target(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        sentinel = self.directory / "reservation-hardlink-sentinel"
        sentinel.write_bytes(b"external sentinel must remain exact\n")
        sentinel_before = sentinel.read_bytes()
        transport_count = 0

        def replace_reservation_with_hardlink(_body, _key):
            nonlocal transport_count
            transport_count += 1
            if transport_count == 1:
                reservation = (
                    output_root
                    / "reservation-hardlink"
                    / "request-reservations.jsonl"
                )
                reservation.unlink()
                os.link(sentinel, reservation)
                raise TransientTransportError()
            raise AssertionError("retry transport must not run")

        with self.assertRaisesRegex(ManifestError, "reservation"):
            run_evaluation(
                manifest_path=manifest,
                run_id="reservation-hardlink",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=replace_reservation_with_hardlink,
            )

        self.assertEqual(1, transport_count)
        self.assertEqual(sentinel_before, sentinel.read_bytes())

    def test_evaluation_rejects_a_hardlinked_receipt_without_touching_target(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        sentinel = self.directory / "receipt-hardlink-sentinel"
        sentinel.write_bytes(b"external receipt sentinel must remain exact\n")
        sentinel_before = sentinel.read_bytes()

        def replace_receipt_with_hardlink(_body, _key):
            receipt = output_root / "receipt-hardlink" / "receipt.json"
            receipt.unlink()
            os.link(sentinel, receipt)
            return {
                "model": "gpt-audio-1.5",
                "content": json.dumps(
                    {
                        "clipID": clip_id,
                        "verdict": "pass",
                        "confidence": 0.95,
                        "category": "correct",
                    }
                ),
                "usage": {},
            }

        with self.assertRaisesRegex(ManifestError, "run artifact"):
            run_evaluation(
                manifest_path=manifest,
                run_id="receipt-hardlink",
                dry_run=False,
                output_root=output_root,
                environment={"OPENAI_API_KEY": "test-only-key"},
                transport=replace_receipt_with_hardlink,
            )

        self.assertEqual(sentinel_before, sentinel.read_bytes())

    def test_atomic_temp_rejects_a_hardlink_created_after_exclusive_open(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        output_root = self.directory / "runs"
        sentinel = self.directory / "temporary-hardlink-sentinel"
        fixed_hex = "f" * 32
        real_open = os.open
        linked = False

        def hardlink_temporary_after_open(candidate, flags, mode=0o777):
            nonlocal linked
            descriptor = real_open(candidate, flags, mode)
            if (
                not linked
                and Path(candidate).name
                == f".receipt.json.{fixed_hex}.tmp"
            ):
                os.link(candidate, sentinel)
                linked = True
            return descriptor

        with (
            mock.patch.object(
                audio_judge.uuid,
                "uuid4",
                return_value=mock.Mock(hex=fixed_hex),
            ),
            mock.patch.object(
                audio_judge.os,
                "open",
                side_effect=hardlink_temporary_after_open,
            ),
            self.assertRaisesRegex(ManifestError, "temporary run artifact"),
        ):
            run_evaluation(
                manifest_path=manifest,
                run_id="temporary-hardlink",
                dry_run=True,
                output_root=output_root,
            )

        self.assertTrue(linked)
        self.assertEqual(b"", sentinel.read_bytes())

    def test_routes_refusal_transport_failure_and_redacts_exception_details(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        refusal = run_evaluation(
            manifest_path=manifest,
            run_id="refusal",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(
                return_value={
                    "model": "gpt-audio-1.5",
                    "content": None,
                    "refusal": "No.",
                    "usage": {},
                }
            ),
        )
        transport_failure = run_evaluation(
            manifest_path=manifest,
            run_id="transport-failure",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(
                side_effect=PermanentTransportError(
                    "Bearer secret-key from /private/source/book.m4b"
                )
            ),
        )

        self.assertEqual(
            ["model_refusal"],
            refusal["morningQueue"][0]["reasons"],
        )
        self.assertEqual(
            ["transport_failure"],
            transport_failure["morningQueue"][0]["reasons"],
        )
        serialized = json.dumps(transport_failure)
        for forbidden in (
            "secret-key",
            "/private/source",
            "Authorization",
            "OPENAI_API_KEY",
        ):
            self.assertNotIn(forbidden, serialized)

    def test_receipt_records_models_usage_hashes_cost_and_render_provenance(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    clip_id,
                    path,
                    0.25,
                    labelStatus="human-labelled",
                )
            ]
        )
        response = {
            "model": "gpt-audio-1.5-2026-06-01",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.95,
                    "category": "correct",
                }
            ),
            "usage": {
                "prompt_tokens": 42,
                "completion_tokens": 18,
                "total_tokens": 60,
                "prompt_tokens_details": {
                    "audio_tokens": 40,
                    "sourcePath": "/private/source/book.m4b",
                },
                "requestHeaders": {"Authorization": "Bearer secret-key"},
            },
        }

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="receipt",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )

        self.assertEqual("gpt-audio-1.5", receipt["requestedModelID"])
        self.assertEqual(
            ["gpt-audio-1.5-2026-06-01"],
            receipt["returnedModelIDs"],
        )
        self.assertEqual("2026-07-29", receipt["pricing"]["checkDate"])
        result = receipt["results"][0]
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), result["audioSHA256"])
        self.assertEqual("a" * 40, result["sourceCommit"])
        self.assertEqual(f"sha256:{'b' * 64}", result["renderIdentity"])
        self.assertEqual(
            {
                "prompt_tokens": 42,
                "completion_tokens": 18,
                "total_tokens": 60,
                "prompt_tokens_details": {"audio_tokens": 40},
            },
            result["usage"],
        )
        self.assertNotIn("secret-key", json.dumps(receipt))
        self.assertNotIn("/private/source", json.dumps(receipt))
        self.assertEqual("validated", result["validationOutcome"])
        self.assertGreater(result["estimatedCostUSD"], 0)
        self.assertNotIn("corpusID", result)

    def test_tainted_model_and_non_integer_usage_are_not_persisted(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        response = {
            "model": "gpt-audio-1.5-private-book",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.9,
                    "category": "correct",
                }
            ),
            "usage": {
                "prompt_tokens": 12.5,
                "completion_tokens": -1,
                "total_tokens": True,
                "prompt_tokens_details": {
                    "audio_tokens": 4,
                    "cached_tokens": "private-marker",
                },
                "completion_tokens_details": {
                    "audio_tokens": 0,
                    "reasoning_tokens": 3,
                    "tainted": "private-marker",
                },
            },
        }

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="sanitized-api-evidence",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )

        self.assertEqual([], receipt["returnedModelIDs"])
        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["malformed_output"],
            receipt["morningQueue"][0]["reasons"],
        )
        result = receipt["results"][0]
        self.assertIsNone(result["returnedModelID"])
        self.assertIsNone(result["verdict"])
        self.assertEqual("not_validated", result["validationOutcome"])
        self.assertEqual({}, result["usage"])
        self.assertNotIn("private-marker", json.dumps(receipt))

    def test_missing_returned_model_cannot_produce_a_pass(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest([self.manifest_row(clip_id, path, 0.25)])
        response = {
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "pass",
                    "confidence": 0.95,
                    "category": "correct",
                }
            ),
            "usage": {},
        }

        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="missing-returned-model",
            dry_run=False,
            output_root=self.directory / "runs",
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )

        self.assertEqual([], receipt["returnedModelIDs"])
        self.assertEqual("needs_review", receipt["apiEvaluationStatus"])
        self.assertEqual(
            ["malformed_output"],
            receipt["morningQueue"][0]["reasons"],
        )
        self.assertIsNone(receipt["results"][0]["verdict"])


class AttemptLedgerTests(ManifestAdmissionTests):
    def failing_run(self, *, run_id="ledger"):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    clip_id,
                    path,
                    0.25,
                    labelStatus="human-labelled",
                )
            ]
        )
        response = {
            "model": "gpt-audio-1.5",
            "content": json.dumps(
                {
                    "clipID": clip_id,
                    "verdict": "fail",
                    "confidence": 0.95,
                    "category": "wrong_sense",
                }
            ),
            "usage": {},
        }
        output_root = self.directory / "runs"
        run_evaluation(
            manifest_path=manifest,
            run_id=run_id,
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=mock.Mock(return_value=response),
        )
        return clip_id, output_root

    def run_recovery_cli(self, *, run_id, output_root):
        environment = dict(os.environ)
        environment["OPENAI_API_KEY"] = "must-not-be-used-by-recovery"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "recover",
                "--run-id",
                run_id,
                "--output-root",
                str(output_root),
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def run_file_bytes(run_directory):
        return {
            path.relative_to(run_directory).as_posix(): path.read_bytes()
            for path in sorted(run_directory.rglob("*"))
            if path.is_file()
        }

    def terminal_morning_run(self, *, run_id):
        clip_id, output_root = self.failing_run(run_id=run_id)
        record_attempt(
            run_id=run_id,
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        record_rerender(
            run_id=run_id,
            clip_id=clip_id,
            render_content_sha256="5" * 64,
            audio_retest_receipt="6" * 64,
            family_regression_receipt="7" * 64,
            outcome="fail",
            output_root=output_root,
        )
        record_attempt(
            run_id=run_id,
            clip_id=clip_id,
            source_commit="e" * 40,
            red_test_receipt="8" * 64,
            green_test_receipt="9" * 64,
            negative_guard_receipt="a" * 64,
            implementation_review_receipt="b" * 64,
            output_root=output_root,
        )
        record_rerender(
            run_id=run_id,
            clip_id=clip_id,
            render_content_sha256="c" * 64,
            audio_retest_receipt="d" * 64,
            family_regression_receipt="e" * 64,
            outcome="fail",
            output_root=output_root,
        )
        return clip_id, output_root

    def test_oversized_run_claim_integer_is_controlled_without_cli_mutation(self):
        run_id = "oversized-claim-integer"
        _clip_id, output_root = self.failing_run(run_id=run_id)
        run_directory = output_root / run_id
        claim_path = run_directory / "run-claim.json"
        huge_digits = "9" * 5000
        claim_path.write_text(
            (
                f'{{"schemaVersion":{huge_digits},"runID":"{run_id}",'
                '"state":"claimed"}'
            ),
            encoding="utf-8",
        )
        (run_directory / ".attempt-ledger.lock").unlink()
        before = self.run_file_bytes(run_directory)

        caught = None
        try:
            audio_judge._validate_run_claim_bytes(
                claim_path.read_bytes(),
                run_id,
            )
        except Exception as error:
            caught = error
        completed = self.run_recovery_cli(
            run_id=run_id,
            output_root=output_root,
        )

        self.assertIsInstance(caught, LedgerError)
        self.assertEqual("judge-owned run claim is invalid", str(caught))
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual("", completed.stdout)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertNotIn(huge_digits, completed.stderr)
        self.assertEqual(before, self.run_file_bytes(run_directory))
        self.assertFalse(
            (run_directory / ".attempt-ledger.lock").exists()
        )

    def test_oversized_ledger_integer_is_controlled_without_cli_mutation(self):
        run_id = "oversized-ledger-integer"
        _clip_id, output_root = self.failing_run(run_id=run_id)
        run_directory = output_root / run_id
        ledger_path = run_directory / "attempt-ledger.jsonl"
        huge_digits = "9" * 5000
        ledger_path.write_text(
            f'{{"schemaVersion":{huge_digits}}}\n',
            encoding="utf-8",
        )
        (run_directory / ".attempt-ledger.lock").unlink()
        before = self.run_file_bytes(run_directory)

        caught = None
        try:
            audio_judge._decode_ledger_events(ledger_path.read_bytes())
        except Exception as error:
            caught = error
        completed = self.run_recovery_cli(
            run_id=run_id,
            output_root=output_root,
        )

        self.assertIsInstance(caught, LedgerError)
        self.assertEqual("attempt ledger is invalid", str(caught))
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual("", completed.stdout)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertNotIn(huge_digits, completed.stderr)
        self.assertEqual(before, self.run_file_bytes(run_directory))
        self.assertFalse(
            (run_directory / ".attempt-ledger.lock").exists()
        )

    def test_oversized_queue_integer_is_controlled_without_cli_mutation(self):
        run_id = "oversized-queue-integer"
        _clip_id, output_root = self.terminal_morning_run(run_id=run_id)
        run_directory = output_root / run_id
        queue_path = run_directory / "morning-queue.json"
        huge_digits = "9" * 5000
        queue_path.write_text(
            f'[{{"ledgerEventSequence":{huge_digits}}}]',
            encoding="utf-8",
        )
        (run_directory / ".attempt-ledger.lock").unlink()
        before = self.run_file_bytes(run_directory)

        caught = None
        try:
            audio_judge._decode_morning_queue(queue_path.read_bytes())
        except Exception as error:
            caught = error
        completed = self.run_recovery_cli(
            run_id=run_id,
            output_root=output_root,
        )

        self.assertIsInstance(caught, LedgerError)
        self.assertEqual("morning queue is invalid", str(caught))
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual("", completed.stdout)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertNotIn(huge_digits, completed.stderr)
        self.assertEqual(before, self.run_file_bytes(run_directory))
        self.assertFalse(
            (run_directory / ".attempt-ledger.lock").exists()
        )

    def test_recover_cli_restores_committed_proposal_without_media_or_transport(self):
        clip_id = generate_clip_id()
        audio_path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, audio_path, 0.25)]
        )
        authority_path = self.provenance_authority_path
        output_root = self.directory / "runs"
        run_evaluation(
            manifest_path=manifest,
            run_id="cli-recover-proposal",
            dry_run=True,
            output_root=output_root,
        )
        run_directory = output_root / "cli-recover-proposal"
        with mock.patch.object(
            audio_judge,
            "_write_attempt_snapshot",
            side_effect=LedgerError("simulated publication failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "simulated"):
                audio_judge._emit_proposal(
                    run_id="cli-recover-proposal",
                    clip_id=clip_id,
                    category="wrong_sense",
                    output_root=output_root,
                )
        ledger_before = (run_directory / "attempt-ledger.jsonl").read_bytes()
        receipt_before = (run_directory / "receipt.json").read_bytes()
        manifest.unlink()
        authority_path.unlink()
        audio_path.unlink()

        completed = self.run_recovery_cli(
            run_id="cli-recover-proposal",
            output_root=output_root,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(
            {
                "schemaVersion": 1,
                "runID": "cli-recover-proposal",
                "status": "RECOVERED",
                "ledgerEventCount": 1,
                "clipStateCount": 1,
                "attemptStatePublished": True,
                "morningQueueEntryCount": 0,
                "requestCount": 0,
                "transportAttemptCount": 0,
            },
            json.loads(completed.stdout),
        )
        self.assertNotIn(str(output_root), completed.stdout + completed.stderr)
        self.assertEqual(
            ledger_before,
            (run_directory / "attempt-ledger.jsonl").read_bytes(),
        )
        self.assertEqual(
            receipt_before,
            (run_directory / "receipt.json").read_bytes(),
        )
        self.assertFalse(
            (run_directory / "request-reservations.jsonl").exists()
        )
        snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "proposal_emitted",
            snapshot["clips"][clip_id]["state"],
        )
        state = record_attempt(
            run_id="cli-recover-proposal",
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        self.assertEqual("rerender_pending", state["state"])

    def test_recover_cli_restores_attempt_snapshot_and_terminal_queue_once(self):
        clip_id, output_root = self.failing_run(run_id="cli-recover-workflow")
        run_directory = output_root / "cli-recover-workflow"
        record_attempt(
            run_id="cli-recover-workflow",
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        (run_directory / "attempt-state.json").unlink()

        attempt_recovery = self.run_recovery_cli(
            run_id="cli-recover-workflow",
            output_root=output_root,
        )

        self.assertEqual(0, attempt_recovery.returncode, attempt_recovery.stderr)
        attempt_snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "rerender_pending",
            attempt_snapshot["clips"][clip_id]["state"],
        )
        record_rerender(
            run_id="cli-recover-workflow",
            clip_id=clip_id,
            render_content_sha256="5" * 64,
            audio_retest_receipt="6" * 64,
            family_regression_receipt="7" * 64,
            outcome="fail",
            output_root=output_root,
        )
        record_attempt(
            run_id="cli-recover-workflow",
            clip_id=clip_id,
            source_commit="e" * 40,
            red_test_receipt="8" * 64,
            green_test_receipt="9" * 64,
            negative_guard_receipt="a" * 64,
            implementation_review_receipt="b" * 64,
            output_root=output_root,
        )
        record_rerender(
            run_id="cli-recover-workflow",
            clip_id=clip_id,
            render_content_sha256="c" * 64,
            audio_retest_receipt="d" * 64,
            family_regression_receipt="e" * 64,
            outcome="fail",
            output_root=output_root,
        )
        ledger_before = (run_directory / "attempt-ledger.jsonl").read_bytes()
        reservations_before = (
            run_directory / "request-reservations.jsonl"
        ).read_bytes()
        (run_directory / "attempt-state.json").unlink()
        (run_directory / "morning-queue.json").unlink()

        first = self.run_recovery_cli(
            run_id="cli-recover-workflow",
            output_root=output_root,
        )
        second = self.run_recovery_cli(
            run_id="cli-recover-workflow",
            output_root=output_root,
        )

        self.assertEqual(0, first.returncode, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(
            ledger_before,
            (run_directory / "attempt-ledger.jsonl").read_bytes(),
        )
        self.assertEqual(
            reservations_before,
            (run_directory / "request-reservations.jsonl").read_bytes(),
        )
        terminal_snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "morning_review",
            terminal_snapshot["clips"][clip_id]["state"],
        )
        queue = json.loads(
            (run_directory / "morning-queue.json").read_text(encoding="utf-8")
        )
        self.assertEqual(1, len(queue))
        self.assertEqual(
            ["repeated_regression_failure"],
            queue[0]["reasons"],
        )
        self.assertEqual(5, queue[0]["ledgerEventSequence"])

    def test_recover_cli_rejects_invalid_runs_without_mutation(self):
        output_root = self.directory / "runs"
        output_root.mkdir()
        unclaimed = output_root / "unclaimed-recovery"
        unclaimed.mkdir()
        (unclaimed / "sentinel").write_bytes(b"unchanged")

        for run_id, ledger_bytes in (
            ("empty-recovery", None),
            ("malformed-recovery", b"{not-json\n"),
        ):
            clip_id = generate_clip_id()
            audio_path = self.write_wav(clip_id)
            manifest = self.write_manifest(
                [self.manifest_row(clip_id, audio_path, 0.25)]
            )
            run_evaluation(
                manifest_path=manifest,
                run_id=run_id,
                dry_run=True,
                output_root=output_root,
            )
            run_directory = output_root / run_id
            if ledger_bytes is not None:
                (run_directory / "attempt-ledger.jsonl").write_bytes(
                    ledger_bytes
                )

        conflicting_run = output_root / "conflicting-recovery"
        conflicting_run.mkdir()
        (conflicting_run / "run-claim.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runID": "conflicting-recovery",
                    "state": "claimed",
                }
            ),
            encoding="utf-8",
        )
        conflicting_events = [
            {
                "schemaVersion": 1,
                "eventType": "proposal_emitted",
                "clipID": generate_clip_id(),
                "state": "proposal_emitted",
                "attemptCount": 0,
                "proposalCategory": "wrong_sense",
                "productionMutationAuthorized": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            },
            {
                "schemaVersion": 1,
                "eventType": "proposal_emitted",
                "clipID": generate_clip_id(),
                "state": "proposal_emitted",
                "attemptCount": 0,
                "proposalCategory": "stress",
                "productionMutationAuthorized": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            },
        ]
        with (conflicting_run / "attempt-ledger.jsonl").open("wb") as ledger:
            for event in conflicting_events:
                ledger.write(
                    json.dumps(
                        event,
                        sort_keys=True,
                        separators=(",", ":"),
                    ).encode("utf-8")
                    + b"\n"
                )
            ledger.flush()
            os.fsync(ledger.fileno())

        for run_id in (
            "unclaimed-recovery",
            "empty-recovery",
            "malformed-recovery",
            "conflicting-recovery",
        ):
            with self.subTest(run_id=run_id):
                run_directory = output_root / run_id
                before = self.run_file_bytes(run_directory)

                completed = self.run_recovery_cli(
                    run_id=run_id,
                    output_root=output_root,
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertEqual("", completed.stdout)
                self.assertEqual(before, self.run_file_bytes(run_directory))

    def test_recover_lock_open_is_anchored_against_pathname_swap(self):
        run_id = "directory-lock-swap"
        _clip_id, output_root = self.failing_run(run_id=run_id)
        run_directory = output_root / run_id
        replacement_root = self.directory / "replacement-runs"
        replacement_root.mkdir()
        replacement_directory = replacement_root / run_id
        shutil.copytree(run_directory, replacement_directory)
        (run_directory / "attempt-state.json").write_bytes(
            b"original stale snapshot\n"
        )
        (replacement_directory / "attempt-state.json").write_bytes(
            b"replacement stale snapshot\n"
        )
        (replacement_directory / ".attempt-ledger.lock").unlink()
        original_before = self.run_file_bytes(run_directory)
        replacement_before = self.run_file_bytes(replacement_directory)
        displaced_directory = output_root / f"{run_id}-displaced"
        real_open = audio_judge.os.open
        swapped = False

        def swap_during_lock_open(
            path,
            flags,
            mode=0o777,
            *,
            dir_fd=None,
        ):
            nonlocal swapped
            if (
                not swapped
                and Path(path).name == ".attempt-ledger.lock"
            ):
                run_directory.rename(displaced_directory)
                replacement_directory.rename(run_directory)
                swapped = True
            return real_open(
                path,
                flags,
                mode,
                dir_fd=dir_fd,
            )

        caught = None
        with mock.patch.object(
            audio_judge.os,
            "open",
            side_effect=swap_during_lock_open,
        ):
            try:
                audio_judge.recover_run(
                    run_id=run_id,
                    output_root=output_root,
                )
            except Exception as error:
                caught = error

        self.assertIsInstance(caught, LedgerError)
        self.assertEqual(
            original_before,
            self.run_file_bytes(displaced_directory),
        )
        self.assertEqual(
            replacement_before,
            self.run_file_bytes(run_directory),
        )
        self.assertFalse(
            (run_directory / ".attempt-ledger.lock").exists()
        )

    def test_recover_snapshot_publish_is_anchored_against_pathname_swap(self):
        run_id = "directory-publish-swap"
        _clip_id, output_root = self.failing_run(run_id=run_id)
        run_directory = output_root / run_id
        replacement_root = self.directory / "publish-replacement-runs"
        replacement_root.mkdir()
        replacement_directory = replacement_root / run_id
        shutil.copytree(run_directory, replacement_directory)
        (run_directory / "attempt-state.json").write_bytes(
            b"original stale snapshot\n"
        )
        (replacement_directory / "attempt-state.json").write_bytes(
            b"replacement stale snapshot\n"
        )
        original_before = self.run_file_bytes(run_directory)
        replacement_before = self.run_file_bytes(replacement_directory)
        displaced_directory = output_root / f"{run_id}-displaced"
        real_open = audio_judge.os.open
        swapped = False

        def swap_during_snapshot_temp_open(
            path,
            flags,
            mode=0o777,
            *,
            dir_fd=None,
        ):
            nonlocal swapped
            name = Path(path).name
            if (
                not swapped
                and name.startswith(".attempt-state.json.")
                and name.endswith(".tmp")
            ):
                run_directory.rename(displaced_directory)
                replacement_directory.rename(run_directory)
                swapped = True
            return real_open(
                path,
                flags,
                mode,
                dir_fd=dir_fd,
            )

        caught = None
        with mock.patch.object(
            audio_judge.os,
            "open",
            side_effect=swap_during_snapshot_temp_open,
        ):
            try:
                audio_judge.recover_run(
                    run_id=run_id,
                    output_root=output_root,
                )
            except Exception as error:
                caught = error

        self.assertIsInstance(caught, LedgerError)
        self.assertEqual(
            original_before,
            self.run_file_bytes(displaced_directory),
        )
        self.assertEqual(
            replacement_before,
            self.run_file_bytes(run_directory),
        )

    def test_recover_requires_existing_lock_without_creating_one(self):
        run_id = "missing-recovery-lock"
        _clip_id, output_root = self.failing_run(run_id=run_id)
        run_directory = output_root / run_id
        lock_path = run_directory / ".attempt-ledger.lock"
        lock_path.unlink()
        before = self.run_file_bytes(run_directory)

        completed = self.run_recovery_cli(
            run_id=run_id,
            output_root=output_root,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertEqual("", completed.stdout)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertEqual(before, self.run_file_bytes(run_directory))
        self.assertFalse(lock_path.exists())

    def test_recover_rejects_non_exact_json_types_without_mutation_or_traceback(self):
        probes = (
            "claim-schema-bool",
            "ledger-schema-bool",
            "queue-category-object",
            "proposal-category-object",
            "outcome-object",
            "source-commit-object",
        )

        def corrupt(run_directory, probe):
            if probe == "claim-schema-bool":
                claim_path = run_directory / "run-claim.json"
                claim = json.loads(claim_path.read_text(encoding="utf-8"))
                claim["schemaVersion"] = True
                claim_path.write_text(json.dumps(claim), encoding="utf-8")
            elif probe == "queue-category-object":
                queue_path = run_directory / "morning-queue.json"
                queue = json.loads(queue_path.read_text(encoding="utf-8"))
                queue[0]["queueCategory"] = {"nested": "invalid"}
                queue_path.write_text(json.dumps(queue), encoding="utf-8")
            else:
                ledger_path = run_directory / "attempt-ledger.jsonl"
                events = [
                    json.loads(line)
                    for line in ledger_path.read_text(
                        encoding="utf-8"
                    ).splitlines()
                ]
                if probe == "ledger-schema-bool":
                    events[0]["schemaVersion"] = True
                elif probe == "proposal-category-object":
                    events[0]["proposalCategory"] = {"nested": "invalid"}
                elif probe == "outcome-object":
                    events[2]["outcome"] = {"nested": "invalid"}
                else:
                    events[1]["sourceCommit"] = {"nested": "invalid"}
                ledger_path.write_text(
                    "".join(
                        json.dumps(
                            event,
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n"
                        for event in events
                    ),
                    encoding="utf-8",
                )
            (run_directory / "attempt-state.json").write_bytes(
                b"stale snapshot sentinel\n"
            )
            (run_directory / ".attempt-ledger.lock").unlink()

        for probe_index, probe in enumerate(probes):
            for surface in ("local", "shipped-cli"):
                with self.subTest(probe=probe, surface=surface):
                    run_id = f"exact-type-{probe_index}-{surface}"
                    _clip_id, output_root = self.terminal_morning_run(
                        run_id=run_id
                    )
                    run_directory = output_root / run_id
                    corrupt(run_directory, probe)
                    before = self.run_file_bytes(run_directory)

                    if surface == "local":
                        caught = None
                        try:
                            audio_judge.recover_run(
                                run_id=run_id,
                                output_root=output_root,
                            )
                        except Exception as error:
                            caught = error
                        self.assertIsInstance(caught, LedgerError)
                    else:
                        completed = self.run_recovery_cli(
                            run_id=run_id,
                            output_root=output_root,
                        )
                        self.assertNotEqual(0, completed.returncode)
                        self.assertEqual("", completed.stdout)
                        self.assertNotIn("Traceback", completed.stderr)

                    self.assertEqual(
                        before,
                        self.run_file_bytes(run_directory),
                    )
                    self.assertFalse(
                        (run_directory / ".attempt-ledger.lock").exists()
                    )

    def test_recover_cli_rejects_queue_collisions_before_any_mutation(self):
        probes = (
            "same-sequence-different-hash",
            "same-hash-different-sequence",
            "same-identity-conflicting-fields",
            "malformed-queue",
            "invalid-reasons",
        )
        for index, probe in enumerate(probes):
            with self.subTest(probe=probe):
                run_id = f"queue-preflight-{index}"
                _clip_id, output_root = self.terminal_morning_run(
                    run_id=run_id
                )
                run_directory = output_root / run_id
                queue_path = run_directory / "morning-queue.json"
                queue = json.loads(queue_path.read_text(encoding="utf-8"))
                authoritative = next(
                    item for item in queue if "ledgerEventSHA256" in item
                )
                if probe == "same-sequence-different-hash":
                    queue_path.write_text(
                        json.dumps(
                            [{**authoritative, "ledgerEventSHA256": "0" * 64}],
                            sort_keys=True,
                        ),
                        encoding="utf-8",
                    )
                elif probe == "same-hash-different-sequence":
                    queue_path.write_text(
                        json.dumps(
                            [
                                {
                                    **authoritative,
                                    "ledgerEventSequence":
                                        authoritative["ledgerEventSequence"] + 1,
                                }
                            ],
                            sort_keys=True,
                        ),
                        encoding="utf-8",
                    )
                elif probe == "same-identity-conflicting-fields":
                    queue_path.write_text(
                        json.dumps(
                            [
                                {
                                    **authoritative,
                                    "clipID": generate_clip_id(),
                                    "queueCategory": "provisional_review",
                                    "reasons": ["low_confidence"],
                                }
                            ],
                            sort_keys=True,
                        ),
                        encoding="utf-8",
                    )
                elif probe == "malformed-queue":
                    queue_path.write_bytes(b"{not-json\n")
                else:
                    queue_path.write_text(
                        json.dumps(
                            [
                                {
                                    "clipID": generate_clip_id(),
                                    "queueCategory": "morning_review",
                                    "reasons": [{}],
                                }
                            ],
                            sort_keys=True,
                        ),
                        encoding="utf-8",
                    )
                (run_directory / "attempt-state.json").write_bytes(
                    b"stale snapshot sentinel\n"
                )
                (run_directory / ".attempt-ledger.lock").unlink()
                before = self.run_file_bytes(run_directory)

                completed = self.run_recovery_cli(
                    run_id=run_id,
                    output_root=output_root,
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertEqual("", completed.stdout)
                self.assertNotIn("Traceback", completed.stderr)
                self.assertEqual(before, self.run_file_bytes(run_directory))
                self.assertFalse(
                    (run_directory / ".attempt-ledger.lock").exists()
                )

    def test_recover_cli_preserves_valid_evaluation_queue_rows(self):
        _clip_id, output_root = self.terminal_morning_run(
            run_id="queue-preservation"
        )
        run_directory = output_root / "queue-preservation"
        queue_path = run_directory / "morning-queue.json"
        queue_before = queue_path.read_bytes()
        queue = json.loads(queue_before)
        self.assertTrue(
            any("ledgerEventSHA256" not in item for item in queue)
        )
        self.assertTrue(
            any("ledgerEventSHA256" in item for item in queue)
        )

        completed = self.run_recovery_cli(
            run_id="queue-preservation",
            output_root=output_root,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(queue_before, queue_path.read_bytes())

    def test_attempt_requires_reviewed_receipts_and_never_increments_while_pending(self):
        clip_id, output_root = self.failing_run()
        initial = read_attempt_state(
            run_id="ledger",
            clip_id=clip_id,
            output_root=output_root,
        )
        self.assertEqual("proposal_emitted", initial["state"])
        self.assertEqual(0, initial["attemptCount"])

        with self.assertRaises(LedgerError):
            record_attempt(
                run_id="ledger",
                clip_id=clip_id,
                source_commit=None,
                red_test_receipt="1" * 64,
                green_test_receipt="2" * 64,
                negative_guard_receipt="3" * 64,
                implementation_review_receipt="4" * 64,
                output_root=output_root,
            )
        self.assertEqual(
            0,
            read_attempt_state(
                run_id="ledger",
                clip_id=clip_id,
                output_root=output_root,
            )["attemptCount"],
        )

        state = record_attempt(
            run_id="ledger",
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        self.assertEqual("rerender_pending", state["state"])
        self.assertEqual(1, state["attemptCount"])
        with self.assertRaises(LedgerError):
            record_attempt(
                run_id="ledger",
                clip_id=clip_id,
                source_commit="e" * 40,
                red_test_receipt="5" * 64,
                green_test_receipt="6" * 64,
                negative_guard_receipt="7" * 64,
                implementation_review_receipt="8" * 64,
                output_root=output_root,
            )

    def test_committed_attempt_recovers_snapshot_once_and_rejects_conflicting_replay(self):
        clip_id, output_root = self.failing_run(run_id="attempt-recovery")
        arguments = {
            "run_id": "attempt-recovery",
            "clip_id": clip_id,
            "source_commit": "d" * 40,
            "red_test_receipt": "1" * 64,
            "green_test_receipt": "2" * 64,
            "negative_guard_receipt": "3" * 64,
            "implementation_review_receipt": "4" * 64,
            "output_root": output_root,
        }
        run_directory = output_root / "attempt-recovery"

        with mock.patch.object(
            audio_judge,
            "_write_attempt_snapshot",
            side_effect=LedgerError("simulated snapshot publication failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "simulated"):
                record_attempt(**arguments)

        ledger_before_recovery = (
            run_directory / "attempt-ledger.jsonl"
        ).read_bytes()
        stale_snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "proposal_emitted",
            stale_snapshot["clips"][clip_id]["state"],
        )
        with self.assertRaisesRegex(LedgerError, "conflicting replay"):
            record_attempt(
                **{
                    **arguments,
                    "source_commit": "e" * 40,
                }
            )

        recovered = record_attempt(**arguments)

        self.assertEqual("rerender_pending", recovered["state"])
        self.assertEqual(1, recovered["attemptCount"])
        self.assertEqual(
            ledger_before_recovery,
            (run_directory / "attempt-ledger.jsonl").read_bytes(),
        )
        repaired_snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "rerender_pending",
            repaired_snapshot["clips"][clip_id]["state"],
        )

    def test_committed_proposal_recovers_snapshot_and_rejects_category_conflict(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        run_evaluation(
            manifest_path=manifest,
            run_id="proposal-recovery",
            dry_run=True,
            output_root=output_root,
        )
        run_directory = output_root / "proposal-recovery"

        with mock.patch.object(
            audio_judge,
            "_write_attempt_snapshot",
            side_effect=LedgerError("simulated snapshot publication failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "simulated"):
                audio_judge._emit_proposal(
                    run_id="proposal-recovery",
                    clip_id=clip_id,
                    category="wrong_sense",
                    output_root=output_root,
                )

        ledger_before_recovery = (
            run_directory / "attempt-ledger.jsonl"
        ).read_bytes()
        self.assertFalse((run_directory / "attempt-state.json").exists())
        with self.assertRaisesRegex(LedgerError, "conflicting replay"):
            audio_judge._emit_proposal(
                run_id="proposal-recovery",
                clip_id=clip_id,
                category="stress",
                output_root=output_root,
            )

        self.assertTrue(
            audio_judge._emit_proposal(
                run_id="proposal-recovery",
                clip_id=clip_id,
                category="wrong_sense",
                output_root=output_root,
            )
        )

        self.assertEqual(
            ledger_before_recovery,
            (run_directory / "attempt-ledger.jsonl").read_bytes(),
        )
        snapshot = json.loads(
            (run_directory / "attempt-state.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "proposal_emitted",
            snapshot["clips"][clip_id]["state"],
        )

    def test_record_workflow_requires_a_judge_owned_claim_before_creating_artifacts(self):
        output_root = self.directory / "runs"
        run_directory = output_root / "unclaimed"
        run_directory.mkdir(parents=True)
        clip_id = generate_clip_id()
        before = list(run_directory.iterdir())

        with self.assertRaisesRegex(LedgerError, "run claim"):
            record_attempt(
                run_id="unclaimed",
                clip_id=clip_id,
                source_commit="d" * 40,
                red_test_receipt="1" * 64,
                green_test_receipt="2" * 64,
                negative_guard_receipt="3" * 64,
                implementation_review_receipt="4" * 64,
                output_root=output_root,
            )
        with self.assertRaisesRegex(LedgerError, "run claim"):
            record_rerender(
                run_id="unclaimed",
                clip_id=clip_id,
                render_content_sha256="5" * 64,
                audio_retest_receipt="6" * 64,
                family_regression_receipt="7" * 64,
                outcome="pass",
                output_root=output_root,
            )

        self.assertEqual(before, list(run_directory.iterdir()))

    def test_record_workflow_rejects_repository_output_root_before_mkdir(self):
        clip_id = generate_clip_id()
        original_mkdir = Path.mkdir

        def reject_repository_mkdir(candidate, *args, **kwargs):
            if candidate == REPOSITORY_ROOT or candidate.is_relative_to(
                REPOSITORY_ROOT
            ):
                raise AssertionError("repository mutation attempted")
            return original_mkdir(candidate, *args, **kwargs)

        with mock.patch.object(Path, "mkdir", new=reject_repository_mkdir):
            with self.assertRaisesRegex(LedgerError, "outside the repository"):
                record_attempt(
                    run_id="forbidden-record-root",
                    clip_id=clip_id,
                    source_commit="d" * 40,
                    red_test_receipt="1" * 64,
                    green_test_receipt="2" * 64,
                    negative_guard_receipt="3" * 64,
                    implementation_review_receipt="4" * 64,
                    output_root=REPOSITORY_ROOT,
                )

    def test_record_workflow_rejects_symlinked_lock_without_touching_target(self):
        clip_id, output_root = self.failing_run(run_id="symlinked-lock")
        lock_path = output_root / "symlinked-lock" / ".attempt-ledger.lock"
        lock_path.unlink()
        sentinel = self.directory / "lock-sentinel"
        sentinel.write_text("unchanged\n", encoding="utf-8")
        lock_path.symlink_to(sentinel)

        with self.assertRaisesRegex(LedgerError, "lock"):
            read_attempt_state(
                run_id="symlinked-lock",
                clip_id=clip_id,
                output_root=output_root,
            )

        self.assertEqual("unchanged\n", sentinel.read_text(encoding="utf-8"))

    def test_record_workflow_rejects_hardlinked_mutable_state_before_mutation(self):
        for artifact_name in (
            ".attempt-ledger.lock",
            "attempt-state.json",
            "morning-queue.json",
        ):
            with self.subTest(artifact=artifact_name):
                run_id = (
                    "hardlink-"
                    + artifact_name.strip(".").replace(".", "-")
                )
                clip_id, output_root = self.failing_run(run_id=run_id)
                run_directory = output_root / run_id
                artifact = run_directory / artifact_name
                artifact.unlink()
                sentinel = self.directory / f"{run_id}-sentinel"
                sentinel.write_bytes(b"external mutable sentinel stays exact\n")
                sentinel_before = sentinel.read_bytes()
                os.link(sentinel, artifact)
                ledger_before = (
                    run_directory / "attempt-ledger.jsonl"
                ).read_bytes()

                with self.assertRaisesRegex(LedgerError, "hardlink"):
                    record_attempt(
                        run_id=run_id,
                        clip_id=clip_id,
                        source_commit="d" * 40,
                        red_test_receipt="1" * 64,
                        green_test_receipt="2" * 64,
                        negative_guard_receipt="3" * 64,
                        implementation_review_receipt="4" * 64,
                        output_root=output_root,
                    )

                self.assertEqual(sentinel_before, sentinel.read_bytes())
                self.assertEqual(
                    ledger_before,
                    (run_directory / "attempt-ledger.jsonl").read_bytes(),
                )

    def test_proposal_rejects_a_hardlinked_ledger_before_external_mutation(self):
        clip_id, output_root = self.failing_run(run_id="hardlink-ledger")
        run_directory = output_root / "hardlink-ledger"
        ledger = run_directory / "attempt-ledger.jsonl"
        ledger.unlink()
        sentinel = self.directory / "ledger-hardlink-sentinel"
        sentinel.write_bytes(b"")
        sentinel_before = sentinel.read_bytes()
        os.link(sentinel, ledger)

        with self.assertRaisesRegex(LedgerError, "hardlink"):
            audio_judge._emit_proposal(
                run_id="hardlink-ledger",
                clip_id=generate_clip_id(),
                category="wrong_sense",
                output_root=output_root,
            )

        self.assertEqual(sentinel_before, sentinel.read_bytes())

    def test_record_workflow_rejects_a_hardlinked_run_claim(self):
        clip_id, output_root = self.failing_run(run_id="hardlink-claim")
        run_directory = output_root / "hardlink-claim"
        claim = run_directory / "run-claim.json"
        claim_bytes = claim.read_bytes()
        claim.unlink()
        sentinel = self.directory / "claim-hardlink-sentinel"
        sentinel.write_bytes(claim_bytes)
        sentinel_before = sentinel.read_bytes()
        os.link(sentinel, claim)

        with self.assertRaisesRegex(LedgerError, "hardlink"):
            read_attempt_state(
                run_id="hardlink-claim",
                clip_id=clip_id,
                output_root=output_root,
            )

        self.assertEqual(sentinel_before, sentinel.read_bytes())

    def test_second_failed_rerender_forces_morning_review_and_blocks_a_third_attempt(self):
        clip_id, output_root = self.failing_run()
        first = {
            "source_commit": "d" * 40,
            "red_test_receipt": "1" * 64,
            "green_test_receipt": "2" * 64,
            "negative_guard_receipt": "3" * 64,
            "implementation_review_receipt": "4" * 64,
        }
        record_attempt(
            run_id="ledger",
            clip_id=clip_id,
            output_root=output_root,
            **first,
        )
        state = record_rerender(
            run_id="ledger",
            clip_id=clip_id,
            render_content_sha256="5" * 64,
            audio_retest_receipt="6" * 64,
            family_regression_receipt="7" * 64,
            outcome="fail",
            output_root=output_root,
        )
        self.assertEqual("proposal_emitted", state["state"])
        self.assertEqual(1, state["attemptCount"])

        with self.assertRaises(LedgerError):
            record_attempt(
                run_id="ledger",
                clip_id=clip_id,
                source_commit="e" * 40,
                red_test_receipt="8" * 64,
                green_test_receipt="9" * 64,
                negative_guard_receipt="a" * 64,
                implementation_review_receipt="4" * 64,
                output_root=output_root,
            )
        record_attempt(
            run_id="ledger",
            clip_id=clip_id,
            source_commit="e" * 40,
            red_test_receipt="8" * 64,
            green_test_receipt="9" * 64,
            negative_guard_receipt="a" * 64,
            implementation_review_receipt="b" * 64,
            output_root=output_root,
        )
        state = record_rerender(
            run_id="ledger",
            clip_id=clip_id,
            render_content_sha256="c" * 64,
            audio_retest_receipt="d" * 64,
            family_regression_receipt="e" * 64,
            outcome="fail",
            output_root=output_root,
        )
        self.assertEqual("morning_review", state["state"])
        self.assertEqual(2, state["attemptCount"])
        with self.assertRaises(LedgerError):
            record_attempt(
                run_id="ledger",
                clip_id=clip_id,
                source_commit="f" * 40,
                red_test_receipt="0" * 64,
                green_test_receipt="1" * 64,
                negative_guard_receipt="2" * 64,
                implementation_review_receipt="3" * 64,
                output_root=output_root,
            )
        queue = json.loads(
            (output_root / "ledger" / "morning-queue.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertIn(
            "repeated_regression_failure",
            queue[-1]["reasons"],
        )
        ledger_lines = (
            output_root / "ledger" / "attempt-ledger.jsonl"
        ).read_text(encoding="utf-8").splitlines()
        self.assertEqual(5, len(ledger_lines))

    def test_committed_morning_review_recovers_queue_exactly_once(self):
        clip_id, output_root = self.failing_run(run_id="queue-recovery")
        run_directory = output_root / "queue-recovery"
        record_attempt(
            run_id="queue-recovery",
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        record_rerender(
            run_id="queue-recovery",
            clip_id=clip_id,
            render_content_sha256="5" * 64,
            audio_retest_receipt="6" * 64,
            family_regression_receipt="7" * 64,
            outcome="fail",
            output_root=output_root,
        )
        record_attempt(
            run_id="queue-recovery",
            clip_id=clip_id,
            source_commit="e" * 40,
            red_test_receipt="8" * 64,
            green_test_receipt="9" * 64,
            negative_guard_receipt="a" * 64,
            implementation_review_receipt="b" * 64,
            output_root=output_root,
        )
        arguments = {
            "run_id": "queue-recovery",
            "clip_id": clip_id,
            "render_content_sha256": "c" * 64,
            "audio_retest_receipt": "d" * 64,
            "family_regression_receipt": "e" * 64,
            "outcome": "fail",
            "output_root": output_root,
        }

        with mock.patch.object(
            audio_judge,
            "_publish_morning_queue_plan",
            side_effect=LedgerError("simulated queue publication failure"),
        ):
            with self.assertRaisesRegex(LedgerError, "simulated"):
                record_rerender(**arguments)

        ledger_before_recovery = (
            run_directory / "attempt-ledger.jsonl"
        ).read_bytes()
        with self.assertRaisesRegex(LedgerError, "conflicting replay"):
            record_rerender(
                **{
                    **arguments,
                    "family_regression_receipt": "f" * 64,
                }
            )

        recovered = record_rerender(**arguments)
        recovered_again = record_rerender(**arguments)

        self.assertEqual("morning_review", recovered["state"])
        self.assertEqual(recovered, recovered_again)
        self.assertEqual(
            ledger_before_recovery,
            (run_directory / "attempt-ledger.jsonl").read_bytes(),
        )
        queue = json.loads(
            (run_directory / "morning-queue.json").read_text(encoding="utf-8")
        )
        repeated_failures = [
            item
            for item in queue
            if item.get("clipID") == clip_id
            and item.get("reasons") == ["repeated_regression_failure"]
        ]
        self.assertEqual(1, len(repeated_failures))
        self.assertEqual(5, repeated_failures[0]["ledgerEventSequence"])
        self.assertRegex(
            repeated_failures[0]["ledgerEventSHA256"],
            r"^[0-9a-f]{64}$",
        )

    def test_successful_rerender_resolves_without_graduating_the_family(self):
        clip_id, output_root = self.failing_run()
        record_attempt(
            run_id="ledger",
            clip_id=clip_id,
            source_commit="d" * 40,
            red_test_receipt="1" * 64,
            green_test_receipt="2" * 64,
            negative_guard_receipt="3" * 64,
            implementation_review_receipt="4" * 64,
            output_root=output_root,
        )
        state = record_rerender(
            run_id="ledger",
            clip_id=clip_id,
            render_content_sha256="5" * 64,
            audio_retest_receipt="6" * 64,
            family_regression_receipt="7" * 64,
            outcome="pass",
            output_root=output_root,
        )

        self.assertEqual("resolved", state["state"])
        self.assertFalse(state["touchedFamilyGraduation"])
        self.assertFalse(state["phase3Graduation"])

    def test_ledger_is_authoritative_and_rejects_impossible_or_malformed_transitions(self):
        output_root = self.directory / "runs"
        run_directory = output_root / "invalid-ledger"
        run_directory.mkdir(parents=True)
        (run_directory / "run-claim.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runID": "invalid-ledger",
                    "state": "claimed",
                }
            ),
            encoding="utf-8",
        )
        clip_id = generate_clip_id()
        invalid_events = [
            {
                "schemaVersion": 1,
                "eventType": "rerender_recorded",
                "clipID": clip_id,
                "state": "resolved",
                "attemptCount": 1,
                "renderContentSHA256": "1" * 64,
                "audioRetestReceipt": "2" * 64,
                "familyRegressionReceipt": "3" * 64,
                "outcome": "pass",
                "productionMutationPerformedByJudge": False,
                "touchedFamilyGraduation": False,
                "phase3Graduation": False,
            }
        ]
        (run_directory / "attempt-ledger.jsonl").write_text(
            "\n".join(json.dumps(event) for event in invalid_events) + "\n",
            encoding="utf-8",
        )
        (run_directory / "attempt-state.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "clips": {
                        clip_id: {
                            "clipID": clip_id,
                            "state": "resolved",
                            "attemptCount": 1,
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

        with self.assertRaises(LedgerError):
            read_attempt_state(
                run_id="invalid-ledger",
                clip_id=clip_id,
                output_root=output_root,
            )

        invalid_events[0] = {
            "schemaVersion": 1,
            "eventType": "proposal_emitted",
            "clipID": clip_id,
            "state": "proposal_emitted",
            "attemptCount": 0,
            "proposalCategory": "wrong_sense",
            "productionMutationAuthorized": False,
            "touchedFamilyGraduation": False,
            "phase3Graduation": False,
            "unexpected": "must fail closed",
        }
        (run_directory / "attempt-ledger.jsonl").write_text(
            json.dumps(invalid_events[0]) + "\n",
            encoding="utf-8",
        )
        with self.assertRaises(LedgerError):
            read_attempt_state(
                run_id="invalid-ledger",
                clip_id=clip_id,
                output_root=output_root,
            )

    def test_only_one_unresolved_proposal_exists_globally_per_run(self):
        first_id = generate_clip_id()
        first_path = self.write_wav(first_id)
        second_id = generate_clip_id()
        second_path = self.write_wav(second_id)
        manifest = self.write_manifest(
            [
                self.manifest_row(
                    first_id,
                    first_path,
                    0.25,
                    labelStatus="human-labelled",
                ),
                self.manifest_row(
                    second_id,
                    second_path,
                    0.25,
                    labelStatus="human-labelled",
                ),
            ]
        )

        def failing_response(body, _key):
            prompt = body["messages"][0]["content"][0]["text"]
            matched = re.search(r"clip_[0-9a-f-]{36}", prompt)
            self.assertIsNotNone(matched)
            return {
                "model": "gpt-audio-1.5",
                "content": json.dumps(
                    {
                        "clipID": matched.group(0),
                        "verdict": "fail",
                        "confidence": 0.95,
                        "category": "wrong_sense",
                    }
                ),
                "usage": {},
            }

        output_root = self.directory / "runs"
        receipt = run_evaluation(
            manifest_path=manifest,
            run_id="one-proposal",
            dry_run=False,
            output_root=output_root,
            environment={"OPENAI_API_KEY": "test-only-key"},
            transport=failing_response,
        )

        events = [
            json.loads(line)
            for line in (
                output_root / "one-proposal" / "attempt-ledger.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(1, len(events))
        self.assertEqual(first_id, events[0]["clipID"])
        self.assertEqual(
            ["deterministic_disagreement", "proposal_blocked_by_existing"],
            receipt["morningQueue"][1]["reasons"],
        )
        with self.assertRaises(LedgerError):
            read_attempt_state(
                run_id="one-proposal",
                clip_id=second_id,
                output_root=output_root,
            )

    def test_cli_missing_credential_records_waiting_without_secret_or_path(self):
        clip_id = generate_clip_id()
        path = self.write_wav(clip_id)
        manifest = self.write_manifest(
            [self.manifest_row(clip_id, path, 0.25)]
        )
        output_root = self.directory / "runs"
        environment = dict(os.environ)
        environment.pop("OPENAI_API_KEY", None)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "evaluate",
                "--manifest",
                str(manifest),
                "--provenance-authority",
                str(self.provenance_authority_path),
                "--run-id",
                "cli-waiting",
                "--output-root",
                str(output_root),
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )

        receipt = json.loads(result.stdout)
        self.assertEqual("WAITING_FOR_USER", receipt["status"])
        serialized = result.stdout + result.stderr
        self.assertNotIn(str(manifest), serialized)
        self.assertNotIn("OPENAI_API_KEY", serialized)
        self.assertTrue(
            (output_root / "cli-waiting" / "receipt.json").is_file()
        )

        repeated = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "evaluate",
                "--manifest",
                str(manifest),
                "--provenance-authority",
                str(self.provenance_authority_path),
                "--run-id",
                "cli-waiting",
                "--output-root",
                str(output_root),
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(0, repeated.returncode)
        self.assertIn("run identifier is already claimed", repeated.stderr)
        self.assertNotIn(str(manifest), repeated.stderr)


if __name__ == "__main__":
    unittest.main()
