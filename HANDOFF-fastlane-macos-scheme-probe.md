# Handoff — fastlane macOS scheme probe

## 2026-08-13 — Probe fixed, macOS archive armed as warning-only

Done:
- Root cause proven: lane bodies run with cwd `fastlane/` (`Runner#execute`
  chdirs to `FastlaneFolder.path`); `sh` is `Actions.sh_no_action`, which has no
  `chdir`, so `xcodebuild -project 'Echo.xcodeproj' -list` never found the
  project and the bare `rescue` returned false on every run since inception.
- `scheme_exists?` now checks the committed shared-scheme file, anchored via a
  new `repo_root` helper (verified `true` from both fastlane/ and repo root);
  `rescue` now logs before returning false.
- Weekly macOS hard fail (`UI.user_error!`) demoted to a warning on all channels
  so an untested macOS signing path cannot abort the lane before the iOS upload.
- Corrected the false "uploads both .ipa and .pkg" claims in the Fastfile lane
  desc, the upload comment, and `.github/workflows/release-trains.yml`; pinned
  `app_platform: "ios"` on the single `upload_to_testflight` call.

Next:
- Manual **nightly** workflow_dispatch to observe the first real macOS archive
  attempt. Expect it to fail on signing (Mac Installer Distribution cert
  unresolved) and warn — the iOS upload must still complete.
- Do NOT merge to weekly immediately before an external ship.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/practical-perlman-39b35f,
branch claude/practical-perlman-39b35f. Next: dispatch the release-trains
workflow on the nightly channel and read the macOS archive step's warning.
```
