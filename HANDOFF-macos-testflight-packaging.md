# Handoff — macOS TestFlight packaging

## 2026-08-16 — Root cause fixed in code; one manual bootstrap still blocks CI

Done: Found why the Mac app never packaged: the .pkg needs a *second*
certificate (Mac Installer Distribution) that was never stored in the match
repo, so `exportArchive` died after a successful archive. Added
`additional_cert_types` (CI-only — non-readonly mints a new cert), a second
`upload_to_testflight` for the .pkg (internal testers only), a keychain-based
diagnostic, `Scripts/import_mac_installer_cert.sh`, and docs. Verified by
source-reading fastlane + `ruby -c` / `fastlane lanes`; NO macOS archive run
(outside the build-slot window).

Next: Dan runs the bootstrap script once (needs a Keychain Access private-key
export an agent must not perform), then dispatch a nightly train to prove it.
Open, not fixed: `Echo macOS` target lacks the `Info.plist` membership
exception the iOS target has — a plausible next export blocker; and the Gemfile
pins no fastlane version (`*.lock` is gitignored), so CI floats.

Resume:

```
Worktree: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/old-worktrees-salvage-d4912c
Branch: claude/macos-testflight-packaging-789ec4 (based on origin/nightly)
Next: confirm Scripts/import_mac_installer_cert.sh has been run, then
`gh workflow run release-trains.yml -f channel=nightly` and read the macOS
export + second upload steps in the run log.
```
