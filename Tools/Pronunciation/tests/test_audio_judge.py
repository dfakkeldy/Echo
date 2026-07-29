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
            "corpusID": "public-synthetic-v1",
            "deterministicExpectation": "record.verb",
            "sourceCommit": "a" * 40,
            "renderIdentity": f"sha256:{'b' * 64}",
            "estimatedTextInputTokens": 220,
            "estimatedAudioInputTokens": 400,
            "maxTextOutputTokens": 180,
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


class EvaluationGateTests(ManifestAdmissionTests):
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
                    estimatedTextInputTokens=1,
                    estimatedAudioInputTokens=200_000,
                    maxTextOutputTokens=1,
                )
            ]
        )
        transport = mock.Mock(side_effect=TransientTransportError())

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


if __name__ == "__main__":
    unittest.main()
