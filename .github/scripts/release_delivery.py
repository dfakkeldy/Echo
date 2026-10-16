#!/usr/bin/env python3
"""Compare immutable build inputs with successful per-channel delivery receipts.

No Apple access and no repository writes. GitHub artifacts are evidence, not a
cache hit: their originating workflow attempt must also have succeeded.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def git_tree(root, ref="HEAD"):
    raw = subprocess.check_output(["git", "-C", str(root), "ls-tree", "-rz", ref])
    result = {}
    for entry in raw.split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            mode, kind, oid = meta.decode().split()
            result[path.decode()] = [mode, kind, oid]
    return result


def under(path, root):
    return path == root or path.startswith(root + "/")


def build_input(path, config, platform):
    if path in config.get("exclude_files", []):
        return False
    if any(under(path, root) for root in config["exclude_roots"]):
        return False
    if "/" not in path and path.endswith(".md"):
        return path in config.get("bundled_root_documents", [])
    if path == ".DS_Store":
        return False
    if path.startswith("fastlane/"):
        return path.split("/")[1] in {
            "Fastfile", "Appfile", "Gymfile", "Matchfile", "Pluginfile", "lib"
        }
    return not any(under(path, root) for root in config["platform_excludes"].get(platform, []))


def load_workflow(path):
    # Ruby and its YAML/JSON standard libraries are present on the hosted
    # Ubuntu and macOS images. Avoid installing a Python YAML dependency.
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))", str(path)
    ], text=True))


def build_recipe(workflow, config):
    job = workflow["jobs"][config["delivery_job"]]
    steps = []
    for step in job["steps"]:
        command = step.get("run", "")
        action = step.get("uses", "")
        if ("xcodebuild" in command or "swift test" in command or "bundle exec fastlane" in command
                or "setup-xcode@" in action or "ruby/setup-ruby@" in action):
            selected = {key: value for key, value in step.items()
                        if key in {"uses", "with", "run", "env", "shell", "working-directory"}}
            # Receipt bookkeeping cannot change the archive. Keep it out of the
            # recipe while retaining the actual Fastlane invocation and its env.
            if "run" in selected:
                selected["run"] = "\n".join(line for line in selected["run"].splitlines()
                                              if "RELEASE_CONTROL_SCRIPT" not in line
                                              and "release_delivery.py" not in line)
            if "env" in selected:
                selected["env"] = {key: value for key, value in selected["env"].items()
                                   if key not in {"RELEASE_PLAN", "RELEASE_CONTROL_SCRIPT"}}
            steps.append(selected)
    env = dict(workflow.get("env", {}), **job.get("env", {}))
    return json.loads(json.dumps({"runner": job["runs-on"], "steps": steps,
            "defaults": {"workflow": workflow.get("defaults", {}), "job": job.get("defaults", {})},
            "env": {key: env[key] for key in config["build_env"] if key in env}}))


def fingerprint(source, controller, config, platform, recipe):
    effective = dict(source)
    for path, entry in controller.items():
        if any(under(path, root) for root in config["controller_overlays"]):
            effective[path] = entry
    inputs = {path: entry for path, entry in effective.items() if build_input(path, config, platform)}
    if not inputs:
        raise ValueError("No build inputs selected")
    payload = {"schema": 1, "platform": platform, "files": inputs, "recipe": recipe}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def github_api(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def artifacts(repository, api=github_api):
    result = []
    page = 1
    while True:
        batch = api(f"repos/{repository}/actions/artifacts?per_page=100&page={page}")["artifacts"]
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def allowed_run(run, workflow_path):
    if run["event"] not in {"schedule", "workflow_dispatch", "push"}:
        return False
    return (run["head_branch"] in {"nightly", "weekly", "main"}
            or (workflow_path == ".github/workflows/app-store-release.yml"
                and run["event"] == "push" and run["head_branch"].startswith("v")))


def baseline(repository, channel, platform, history, workflow_path, current_run, api=github_api):
    pattern = re.compile(rf"release-delivery-v1-{re.escape(channel)}-{re.escape(platform)}-(\d+)-([0-9a-f]{{64}})")
    for artifact in sorted(history, key=lambda row: (row["created_at"], row["id"]), reverse=True):
        match = pattern.fullmatch(artifact["name"])
        run_id = artifact.get("workflow_run", {}).get("id")
        if not match or not run_id or str(run_id) == str(current_run):
            continue
        run = api(f"repos/{repository}/actions/runs/{run_id}")
        if (run["status"] == "completed" and run["conclusion"] == "success"
                and run["run_attempt"] == int(match[1])
                and run["path"].split("@")[0] == workflow_path
                and allowed_run(run, workflow_path)):
            if artifact["expired"]:
                return None
            return {"fingerprint": match[2], "run_id": run_id, "artifact_id": artifact["id"],
                    "created_at": artifact["created_at"]}
    return None


def successful_runs(repository, workflow_path, api=github_api):
    result, page = [], 1
    while True:
        rows = api(f"repos/{repository}/actions/workflows/{workflow_path.rsplit('/', 1)[1]}/runs?status=success&per_page=100&page={page}")["workflow_runs"]
        result.extend(rows)
        if len(rows) < 100:
            return result
        page += 1


def receipt_is_latest(repository, previous, channel, platform, runs, api=github_api,
                      workflow_path=".github/workflows/release-trains.yml"):
    """A removed newer artifact must never make an older delivery look current."""
    if previous is None:
        return False
    witness = f"Retain successful {channel} {platform} delivery receipt"
    for run in runs:
        if (run["id"] == previous["run_id"] or run["updated_at"] <= previous["created_at"]
                or not allowed_run(run, workflow_path)):
            continue
        # Read all jobs in the latest attempt, including a matrix or future
        # split into more than 100 jobs. Run-list rows are successful only.
        page = 1
        while True:
            jobs = api(f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100&page={page}")["jobs"]
            if any(step.get("name") == witness and step.get("conclusion") == "success"
                   for job in jobs for step in job.get("steps", [])):
                return False
            if len(jobs) < 100:
                break
            page += 1
    return True


def decision(current, previous, force=False):
    if force:
        return True, "intentional force"
    if previous is None:
        return True, "no successful retained delivery receipt"
    if current != previous["fingerprint"]:
        return True, "build inputs changed"
    return False, f"unchanged since successful delivery run {previous['run_id']}"


def output(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
        handle.write(f"{key}={value}\n")


def plan(args):
    root = Path.cwd()
    control = Path(args.controller).resolve()
    config = json.loads((control / ".github/release-inputs.json").read_text())
    workflow_path = ".github/workflows/" + args.workflow
    workflow = load_workflow(control / workflow_path)
    recipe = build_recipe(workflow, dict(config, delivery_job=args.job))
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    source, controller = git_tree(root), git_tree(control)
    # Force is a recovery path for missing history as well as an intentional
    # rebuild. It skips only baseline lookup, never build-input validation.
    history = [] if args.force == "true" else artifacts(os.environ["GITHUB_REPOSITORY"])
    runs = successful_runs(os.environ["GITHUB_REPOSITORY"], workflow_path) if history else []
    result = {"schema": 1, "source_sha": source_sha, "channel": args.channel, "platforms": {}}
    for platform in config["platform_excludes"]:
        current = fingerprint(source, controller, config, platform, recipe)
        previous = baseline(os.environ["GITHUB_REPOSITORY"], args.channel, platform, history,
                            workflow_path, os.environ["GITHUB_RUN_ID"])
        if previous and not receipt_is_latest(os.environ["GITHUB_REPOSITORY"], previous, args.channel, platform, runs, workflow_path=workflow_path):
            previous = None
        build, reason = decision(current, previous, args.force == "true")
        result["platforms"][platform] = {"fingerprint": current, "build": build, "reason": reason, "baseline": previous}
        output(platform, str(build).lower())
        output("fingerprint_" + platform, current)
        print(f"{platform}/{args.channel}: {reason}")
    output("source_sha", source_sha)
    output("should_run", str(any(row["build"] for row in result["platforms"].values())).lower())
    output("plan", json.dumps(result, separators=(",", ":")))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
        handle.write("### Delivery decision\n\n")
        for platform, row in result["platforms"].items():
            handle.write(f"- {platform}/{args.channel}: {row['reason']}.\n")
        handle.write(f"\nSource: `{source_sha}`. Skipping delivery does not claim fresh tests or Apple approval.\n")


def record(args):
    plan_data = json.loads(os.environ["RELEASE_PLAN"])
    row = plan_data["platforms"][args.platform]
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if not row["build"] or head != plan_data["source_sha"]:
        raise ValueError("Receipt does not match the planned source/platform")
    receipt = dict(plan_data, platform=args.platform, fingerprint=row["fingerprint"],
                   run_id=os.environ["GITHUB_RUN_ID"], run_attempt=os.environ["GITHUB_RUN_ATTEMPT"])
    directory = Path(os.environ["RUNNER_TEMP"]) / "release-receipts"
    directory.mkdir(exist_ok=True)
    (directory / (args.platform + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
    output(args.platform + "_delivered", "true")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    p = subparsers.add_parser("plan")
    p.add_argument("--controller", required=True)
    p.add_argument("--workflow", default="release-trains.yml")
    p.add_argument("--job", default="ship")
    p.add_argument("--channel", choices=["nightly", "weekly", "appstore"], required=True)
    p.add_argument("--force", choices=["true", "false"], default="false")
    r = subparsers.add_parser("record")
    r.add_argument("--platform", choices=["ios", "macos"], required=True)
    args = parser.parse_args()
    try:
        {"plan": plan, "record": record}[args.command](args)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"::error::Delivery guard failed; no delivery authorized: {error}", file=sys.stderr)
        sys.exit(1)
