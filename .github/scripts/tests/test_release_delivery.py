import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("release_delivery", ROOT / ".github/scripts/release_delivery.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
CONFIG = json.loads((ROOT / ".github/release-inputs.json").read_text())
HASH_A, HASH_B = "a" * 64, "b" * 64


def artifact(identifier, fingerprint=HASH_A, channel="nightly", platform="ios", attempt=1, **extra):
    return dict(id=identifier, name=f"release-delivery-v1-{channel}-{platform}-{attempt}-{fingerprint}",
                created_at=f"2026-10-{identifier:02d}T00:00:00Z", expired=False,
                workflow_run={"id": identifier}, **extra)


def run(**extra):
    return dict(dict(id=1, status="completed", conclusion="success", run_attempt=1,
                     updated_at="2026-10-01T01:00:00Z", path=".github/workflows/release-trains.yml",
                     event="schedule", head_branch="main"), **extra)


class DeliveryHistoryTests(unittest.TestCase):
    def previous(self, history, runs=None, **args):
        return guard.baseline("owner/repo", args.get("channel", "nightly"), args.get("platform", "ios"),
                              history, ".github/workflows/release-trains.yml", 999,
                              lambda endpoint: (runs or {}).get(int(endpoint.split("/actions/runs/")[1].split("/")[0]), run()))

    def test_first_run_builds(self):
        self.assertEqual(guard.decision(HASH_A, self.previous([]))[0], True)

    def test_unchanged_skips(self):
        self.assertFalse(guard.decision(HASH_A, self.previous([artifact(1)]))[0])

    def test_changed_builds(self):
        self.assertTrue(guard.decision(HASH_B, self.previous([artifact(1)]))[0])

    def test_force_builds_unchanged(self):
        self.assertTrue(guard.decision(HASH_A, self.previous([artifact(1)]), force=True)[0])

    def test_latest_delivery_controls_reverts(self):
        self.assertTrue(guard.decision(HASH_A, self.previous([artifact(1), artifact(2, HASH_B)]))[0])

    def test_failed_cancelled_and_partial_delivery_retry(self):
        for conclusion in ["failure", "cancelled", "timed_out", "skipped"]:
            with self.subTest(conclusion=conclusion):
                failed = run()
                failed["conclusion"] = conclusion
                previous = self.previous([artifact(1), artifact(2, HASH_B)], {2: failed})
                self.assertTrue(guard.decision(HASH_B, previous)[0])

    def test_compile_only_success_cannot_create_a_baseline(self):
        self.assertIsNone(self.previous([]))

    def test_in_progress_delivery_cannot_create_a_baseline(self):
        running = run()
        running.update(status="in_progress", conclusion=None)
        self.assertIsNone(self.previous([artifact(1)], {1: running}))

    def test_platform_and_channel_are_independent(self):
        history = [artifact(1), artifact(2, channel="weekly"), artifact(3, platform="macos")]
        self.assertEqual(self.previous(history)["run_id"], 1)
        self.assertEqual(self.previous(history, channel="weekly")["run_id"], 2)
        self.assertEqual(self.previous(history, platform="macos")["run_id"], 3)

    def test_partial_echo_delivery_leaves_mac_retryable(self):
        self.assertIsNone(self.previous([artifact(1)], platform="macos"))

    def test_expired_receipt_does_not_skip(self):
        expired = artifact(1)
        expired["expired"] = True
        self.assertIsNone(self.previous([expired]))

    def test_expired_latest_receipt_never_falls_back_to_stale_inputs(self):
        latest = artifact(2, HASH_B)
        latest["expired"] = True
        self.assertIsNone(self.previous([artifact(1), latest]))

    def test_deleted_latest_receipt_is_detected_from_successful_job_history(self):
        previous = self.previous([artifact(1)])
        history = [run(id=2, updated_at="2026-10-02T01:00:00Z")]
        api = lambda endpoint: {"jobs": [{"steps": [{"name": "Retain successful nightly ios delivery receipt", "conclusion": "success"}]}]}
        self.assertFalse(guard.receipt_is_latest("owner/repo", previous, "nightly", "ios", history, api))
        # A newer Mac success does not advance the iOS delivery baseline.
        self.assertTrue(guard.receipt_is_latest("owner/repo", previous, "nightly", "macos", history, api))

    def test_run_history_is_paginated_without_filtering_out_retrying_runs(self):
        pages = []
        def api(endpoint):
            pages.append(endpoint)
            return {"workflow_runs": [{"id": 1, "status": "completed", "conclusion": "success"}] * 100 if len(pages) == 1 else []}
        self.assertEqual(len(guard.workflow_runs("owner/repo", ".github/workflows/release-trains.yml", api)), 100)
        self.assertTrue(pages[-1].endswith("page=2"))
        self.assertNotIn("status=", pages[-1])

    def test_deleted_receipt_in_later_attempt_of_same_run_is_detected(self):
        previous = self.previous([artifact(1)])
        history = [run(run_attempt=2, updated_at="2026-10-02T01:00:00Z")]
        api = lambda endpoint: {"jobs": [{"steps": [{"name": "Retain successful nightly ios delivery receipt", "conclusion": "success"}]}]}
        self.assertFalse(guard.receipt_is_latest("owner/repo", previous, "nightly", "ios", history, api))

    def test_hidden_successful_intermediate_attempt_prevents_stale_fallback(self):
        previous = self.previous([artifact(1)])
        for latest_status, latest_conclusion in [("in_progress", None), ("completed", "failure"), ("completed", "success")]:
            with self.subTest(latest=latest_conclusion):
                history = [run(run_attempt=3, status=latest_status, conclusion=latest_conclusion,
                               updated_at="2026-10-03T01:00:00Z")]
                def api(endpoint):
                    if endpoint.endswith("/attempts/2"):
                        return run(run_attempt=2, updated_at="2026-10-02T01:00:00Z")
                    if "/attempts/2/jobs?" in endpoint:
                        return {"jobs": [{"steps": [{"name": "Retain successful nightly ios delivery receipt", "conclusion": "success"}]}]}
                    return {"jobs": []}
                self.assertFalse(guard.receipt_is_latest("owner/repo", previous, "nightly", "ios", history, api))

    def test_unverifiable_prior_attempt_does_not_skip(self):
        rerun = run()
        rerun["run_attempt"] = 2
        self.assertIsNone(self.previous([artifact(1)], {1: rerun}))

    def test_successful_prior_attempt_is_kept_when_retrying_same_run(self):
        # Echo can have a successful iOS receipt and a retryable Mac warning.
        # Re-running that workflow must retain iOS's completed prior attempt.
        endpoints = []
        def api(endpoint):
            endpoints.append(endpoint)
            result = run()
            if "/attempts/" not in endpoint:
                result.update(status="in_progress", conclusion=None, run_attempt=2)
            return result
        previous = guard.baseline("owner/repo", "nightly", "ios", [artifact(1)],
                                  ".github/workflows/release-trains.yml", 1, api, current_attempt=2)
        self.assertIsNotNone(previous)
        self.assertFalse(guard.decision(HASH_A, previous)[0])
        self.assertTrue(any(endpoint.endswith("/attempts/1") for endpoint in endpoints))

    def test_failed_later_attempt_does_not_erase_successful_delivery(self):
        def api(endpoint):
            result = run()
            if "/attempts/" not in endpoint:
                result.update(conclusion="failure", run_attempt=2)
            return result
        previous = guard.baseline("owner/repo", "nightly", "ios", [artifact(1)],
                                  ".github/workflows/release-trains.yml", 999, api)
        self.assertFalse(guard.decision(HASH_A, previous)[0])

    def test_receipt_from_untrusted_workflow_or_feature_branch_does_not_skip(self):
        for field, value in [("path", ".github/workflows/ci.yml"), ("head_branch", "feature/test"), ("event", "pull_request")]:
            changed = run()
            changed[field] = value
            self.assertIsNone(self.previous([artifact(1)], {1: changed}))

    def test_history_is_fully_paginated(self):
        pages = []
        def api(endpoint):
            pages.append(endpoint)
            return {"artifacts": [artifact(1)] * 100 if len(pages) == 1 else [artifact(2)]}
        self.assertEqual(len(guard.artifacts("owner/repo", api)), 101)
        self.assertTrue(pages[1].endswith("page=2"))


class BuildInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release guard tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.paths = CONFIG["test_inputs"]
        for path in self.paths + ["README.md", "docs/release.md", ".github/workflows/ci.yml"]:
            self.write(path, "initial")
        self.commit()
        self.original = guard.git_tree(self.repo)
        self.recipe = {"runner": "macos-26", "xcode": "26"}

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.DEVNULL)

    def write(self, path, value):
        dest = self.repo / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(value)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")

    def fingerprint(self, source=None, controller=None, platform="ios", recipe=None):
        return guard.fingerprint(source or guard.git_tree(self.repo), controller or {}, CONFIG,
                                 platform, self.recipe if recipe is None else recipe)

    def test_docs_and_controller_only_commits_skip(self):
        before = self.fingerprint()
        for path in ["README.md", "docs/release.md", ".github/workflows/ci.yml"]:
            self.write(path, "changed controller or prose")
        self.commit()
        self.assertEqual(before, self.fingerprint())

    def test_receipt_helper_and_non_build_controls_do_not_create_binaries(self):
        before = self.fingerprint()
        changed = dict(self.original)
        for path in CONFIG.get("exclude_files", []):
            changed[path] = ["100644", "blob", "controller bookkeeping change"]
        self.assertEqual(before, self.fingerprint(changed))

    def test_source_resources_projects_dependencies_and_configuration_build(self):
        before = self.fingerprint()
        for path in self.paths:
            with self.subTest(path=path):
                changed = dict(self.original)
                changed[path] = ["100644", "blob", "different content"]
                self.assertNotEqual(before, self.fingerprint(changed))

    def test_resource_deletion_and_rename_build(self):
        before = self.fingerprint()
        path = self.paths[1]
        (self.repo / path).unlink()
        self.commit()
        self.assertNotEqual(before, self.fingerprint())
        self.write(path + ".renamed", "initial")
        self.commit()
        self.assertNotEqual(before, self.fingerprint())

    def test_file_mode_and_submodule_revision_build(self):
        before = self.fingerprint()
        for entry in [["100755", "blob", self.original[self.paths[0]][2]], ["160000", "commit", "revision"]]:
            changed = dict(self.original)
            changed[self.paths[0]] = entry
            self.assertNotEqual(before, self.fingerprint(changed))

    def test_toolchain_and_build_recipe_change_build(self):
        self.assertNotEqual(self.fingerprint(), self.fingerprint(recipe={"runner": "macos-26", "xcode": "27"}))

    def test_effective_controller_overlay_is_compared_by_content(self):
        for path in CONFIG["controller_overlays"]:
            if path == "fastlane":
                path = "fastlane/Fastfile"
            entry = ["100644", "blob", "same"]
            source = dict(self.original, **{path: entry})
            before = self.fingerprint(source, {path: entry})
            self.assertEqual(before, self.fingerprint(source, {path: entry}))
            self.assertNotEqual(before, self.fingerprint(source, {path: ["100644", "blob", "new build configuration"]}))

    def test_platform_exclusions_do_not_rebuild_other_platform(self):
        for platform, excluded in CONFIG["platform_excludes"].items():
            for root in excluded:
                source = dict(self.original)
                source[root + "/Changed.swift"] = ["100644", "blob", "new"]
                self.assertEqual(self.fingerprint(platform=platform), self.fingerprint(source, platform=platform))


class WorkflowContractTests(unittest.TestCase):
    def test_preflight_is_serialized_before_expensive_job_and_pins_source(self):
        workflow = guard.load_workflow(ROOT / ".github/workflows/release-trains.yml")
        self.assertEqual(workflow["concurrency"]["group"], "release-trains")
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        self.assertEqual(workflow["concurrency"]["queue"], "max")
        changes = workflow["jobs"]["changes"]
        self.assertEqual(changes["runs-on"], "ubuntu-latest")
        ship = workflow["jobs"]["ship"]
        self.assertIn("changes", ship["needs"])
        self.assertIn("needs.changes.outputs.should_run == 'true'", ship["if"])
        checkout = ship["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ needs.changes.outputs.source_sha }}")
        dispatch = workflow.get("on", workflow.get("true"))["workflow_dispatch"]["inputs"]
        self.assertFalse(dispatch["force"]["default"])

    def test_controller_schedule_change_does_not_change_build_recipe(self):
        workflow = guard.load_workflow(ROOT / ".github/workflows/release-trains.yml")
        config = dict(CONFIG, delivery_job="ship")
        before = guard.build_recipe(workflow, config)
        workflow["concurrency"]["group"] = "changed-controller"
        workflow["jobs"]["changes"]["steps"].append({"run": "echo guard change"})
        self.assertEqual(before, guard.build_recipe(workflow, config))
        for step in workflow["jobs"]["ship"]["steps"]:
            if "setup-xcode@" in step.get("uses", ""):
                step["with"]["xcode-version"] = "new SDK"
                break
        self.assertNotEqual(before, guard.build_recipe(workflow, config))

    def test_receipts_require_successful_real_delivery_outputs(self):
        workflow = guard.load_workflow(ROOT / ".github/workflows/release-trains.yml")
        steps = workflow["jobs"]["ship"]["steps"]
        receipts = [s for s in steps if s.get("uses", "").startswith("actions/upload-artifact") and "release-delivery" in s.get("with", {}).get("name", "")]
        self.assertEqual(len(receipts), len(CONFIG["platform_excludes"]))
        for step in receipts:
            self.assertIn("success()", step["if"])
            self.assertIn("_delivered == 'true'", step["if"])
            self.assertEqual(step["with"]["if-no-files-found"], "error")

    def test_ruby_lane_flags_and_step_environment_are_build_inputs(self):
        workflow = guard.load_workflow(ROOT / ".github/workflows/release-trains.yml")
        config = dict(CONFIG, delivery_job="ship")
        before = guard.build_recipe(workflow, config)
        steps = workflow["jobs"]["ship"]["steps"]
        ruby = next(s for s in steps if "ruby/setup-ruby@" in s.get("uses", ""))
        ruby["with"]["ruby-version"] = "new Ruby"
        self.assertNotEqual(before, guard.build_recipe(workflow, config))
        before = guard.build_recipe(workflow, config)
        lane = next(s for s in steps if "bundle exec fastlane" in s.get("run", ""))
        lane["run"] += "\nbundle exec fastlane beta clean:true\n"
        self.assertNotEqual(before, guard.build_recipe(workflow, config))
        before = guard.build_recipe(workflow, config)
        build = next(s for s in steps if "xcodebuild" in s.get("run", ""))
        build["env"] = {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "CHANGED"}
        self.assertNotEqual(before, guard.build_recipe(workflow, config))

    def test_record_rejects_wrong_source_or_skipped_platform(self):
        with tempfile.TemporaryDirectory() as temp:
            plan = {"source_sha": "not the current head", "platforms": {"ios": {"build": True}}}
            env = {"RELEASE_PLAN": json.dumps(plan), "RUNNER_TEMP": temp}
            with patch.dict(os.environ, env), self.assertRaises(ValueError):
                guard.record(type("Args", (), {"platform": "ios"})())


class CommandLineTests(unittest.TestCase):
    def test_real_cli_decisions_and_docs_commit_without_external_services(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            repo, binary = temp / "source", temp / "bin"
            repo.mkdir()
            binary.mkdir()
            def git(*args, **kwargs):
                return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL, **kwargs)
            git("init", "-q")
            git("config", "user.name", "Release guard fixture")
            git("config", "user.email", "tests@example.invalid")
            path = repo / CONFIG["test_inputs"][0]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture source")
            git("add", "-A")
            git("commit", "-qm", "initial source")
            workflow = guard.load_workflow(ROOT / ".github/workflows/release-trains.yml")
            recipe = guard.build_recipe(workflow, dict(CONFIG, delivery_job="ship"))
            fingerprints = {p: guard.fingerprint(guard.git_tree(repo), guard.git_tree(ROOT), CONFIG, p, recipe)
                            for p in CONFIG["platform_excludes"]}
            fake = binary / "gh"
            fake.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
state = json.load(open(os.environ["GUARD_API_FIXTURE"]))
endpoint = sys.argv[2]
if "actions/artifacts?" in endpoint:
    result = {"artifacts": state["artifacts"]}
elif "/actions/workflows/" in endpoint:
    result = {"workflow_runs": []}
elif "/actions/runs/" in endpoint:
    result = state["run"]
else:
    raise SystemExit("unexpected endpoint")
print(json.dumps(result))
''')
            fake.chmod(0o755)
            state_path = temp / "api.json"
            state = {"artifacts": [artifact(1, value, platform=p) for p, value in fingerprints.items()], "run": run()}
            def invoke(force="false"):
                state_path.write_text(json.dumps(state))
                output_path = temp / "output.txt"
                output_path.write_text("")
                env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                           GUARD_API_FIXTURE=str(state_path), GITHUB_OUTPUT=str(output_path),
                           GITHUB_STEP_SUMMARY=str(temp / "summary.md"), GITHUB_REPOSITORY="owner/repo",
                           GITHUB_RUN_ID="999", GITHUB_RUN_ATTEMPT="1")
                subprocess.run([sys.executable, str(ROOT / ".github/scripts/release_delivery.py"), "plan",
                                "--controller", str(ROOT), "--channel", "nightly", "--force", force],
                               cwd=repo, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                return dict(line.split("=", 1) for line in output_path.read_text().splitlines())
            self.assertEqual(invoke()["should_run"], "false")
            # Actual source SHA changes while build inputs remain the same.
            (repo / "README.md").write_text("documentation only")
            git("add", "-A")
            git("commit", "-qm", "docs only")
            self.assertEqual(invoke()["should_run"], "false")
            self.assertEqual(invoke("true")["should_run"], "true")
            state["run"]["conclusion"] = "failure"
            self.assertEqual(invoke()["should_run"], "true")
            state["run"]["conclusion"] = "success"
            path.write_text("changed build input")
            git("add", "-A")
            git("commit", "-qm", "change source")
            self.assertEqual(invoke()["should_run"], "true")

    def test_force_needs_no_github_history_access(self):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(GITHUB_OUTPUT=temp + "/output", GITHUB_STEP_SUMMARY=temp + "/summary",
                       GITHUB_REPOSITORY="owner/repo", GITHUB_RUN_ID="999")
            args = type("Args", (), dict(controller=str(ROOT), workflow="release-trains.yml", job="ship", channel="nightly", force="true"))()
            with patch.dict(os.environ, env), patch.object(guard, "artifacts", side_effect=AssertionError("history must not be called")):
                guard.plan(args)
            values = dict(line.split("=", 1) for line in Path(env["GITHUB_OUTPUT"]).read_text().splitlines())
            self.assertEqual(values["should_run"], "true")


if __name__ == "__main__":
    unittest.main()
