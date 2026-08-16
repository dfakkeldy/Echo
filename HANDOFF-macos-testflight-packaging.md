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

## 2026-08-16 — Bootstrap DONE and verified; awaiting first CI proof

Done: PR #574 merged to nightly. Dan ran the bootstrap; verified independently
by cloning the match repo and decrypting with match's own
`MatchFileEncryption`: `certs/mac_installer_distribution/5RYGQ7NGGL.{cer,p12}`
decrypt cleanly, cert SHA-1 `F7:CF:59:28:…:2E:5E` matches the keychain identity,
expires 2027-06-20, and the .p12 both opens with an EMPTY password and holds a
private key. Added a preflight Ruby guard to the script — only rbenv **3.3.11**
can load this repo's vendored native gems (`.ruby-version` says 3.3.6 and is
NOT authoritative); the wrong Ruby previously crashed at the very last step,
after the manual export.

Next: trigger a nightly train and confirm the .pkg exports and uploads. Still
open: the `Echo macOS` `Info.plist` pbxproj asymmetry, and CI's unpinned
fastlane.

Resume:

```
Worktree: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/old-worktrees-salvage-d4912c
Branch: fix/mac-installer-cert-ruby-guard (based on origin/nightly)
Next: `gh workflow run release-trains.yml -f channel=nightly`, then read the
macOS export + second upload steps. Local fastlane needs
`export PATH="$HOME/.rbenv/versions/3.3.11/bin:$PATH"`.
```
