# Task 6 fix round 5

Resume Task 6 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`e1120e9d`

Only one Important authentication-classification finding remains. Fix it test-first and keep the round strictly scoped.

## Scoped semantic form analysis

For each password-containing form:

- Parse/check the form `action` attribute separately from all other form attributes.
  - Recognize login path components such as `login`, `signin`, `sign-in`, `auth`, `authenticate`, and `authentication`.
  - `action="/auth"` must classify authentication-required.
- Do **not** search arbitrary form/class/style/data attributes for login words.
  - `class="login-demo"` must not qualify by itself.
- Inspect only semantically relevant control attributes:
  - `value`, `aria-label`, `title`, `name`, and `id` on input/button controls.
  - Do not let `class="login-demo"` satisfy the signal.
- Inspect descendant visible text of `button`, `label`, and heading elements after stripping nested tags and normalizing whitespace.
  - `<button><span>Log in</span></button>` must qualify.
- Require the existing password input plus at least one independent login/auth/sign-in/log-in semantic signal from action, selected control attributes, or normalized visible control/label/heading text.
- Keep the immediate outside-heading fallback, but normalize nested text consistently.

## Required regressions

Add before production change:

1. password form with `action="/auth"` classifies authentication-required;
2. password-strength/demo form with `class="login-demo"` and non-login controls remains capturable;
3. nested `<button><span>Log in</span></button>` classifies authentication-required;
4. existing generic update-password submit remains capturable;
5. existing semantic submit remains authentication-required.

Do not broaden into a DOM parser or general HTML subsystem. A small bounded helper over the already bounded HTML response is sufficient. Avoid catastrophic regex/backtracking patterns and unbounded copies.

## Verification

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests`
- `git diff --check`

Preserve every previously accepted Task 6 behavior and the separate Task 5 resource dependency. No project, share extension, image, ingestion, WebKit, vendor, narration, or architecture production edits.

Commit subject:

`fix: scope article login detection`

Append “Fix round 5” to `task-6-report.md`, record RED/GREEN receipts, and return only when committed and complete.
