# Release Workflow

Use this workflow only for an explicitly authorized release action. Preparing
documentation does not authorize a promotion, upload, submission, price change,
legal declaration, or agreement acceptance.

1. Inspect branch/upstream/dirt and preserve unrelated work in an isolated
   worktree. Follow `feature/* → nightly → weekly → main`. Do not backport a
   feature directly to weekly/main to make a gate pass.
2. Record the candidate's exact SHA, source branch, version/build, completed CI
   steps, current TestFlight upload/processing and external review state, and
   physical-device acceptance. Resolve known core-journey blockers before
   proposing `nightly → weekly` or `weekly → main` promotion.
3. Complete [the store checklist](../../docs/release-checklist.md). Prepare copy,
   screenshots and review instructions before the owner's ASC session. Keep
   private audit notes, contacts, tester identities and credentials out of public
   PRs. Do not infer legal answers or product states from source defaults.
4. Present the exact remaining action and candidate for authorization. If a
   version change is required and no version was authorized, obtain that value;
   do not invent it. Update `MARKETING_VERSION` consistently across shipping
   targets on the authorized release branch. The beta lane derives a monotonic
   build number from TestFlight and overrides `CURRENT_PROJECT_VERSION` in the
   archive; the checked-in number is not an upload receipt.
5. Stage only the intended files, use a Conventional Commit, and open the PR to
   the correct destination. Report hosted checks independently from merge,
   upload, review, release and device acceptance.
6. Execute only the approved promotion/upload/submission/release actions. The
   current repository has no tag-triggered App Store submission workflow and no
   Fastlane `release` lane. A tag is a source marker, not proof of a store action.
