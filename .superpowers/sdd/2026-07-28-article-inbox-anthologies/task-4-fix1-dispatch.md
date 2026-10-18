# Task 4 fix round 1

Resume Task 4 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base task commit:

`99279a26`

The specification/security reviewer found three Important issues and three Minor proof gaps. Fix the Important findings test-first and strengthen the named tests.

## Important

1. **Qualified/unlisted active element text bypasses the fail-closed policy.**
   - Normalize and classify element local names with namespace processing enabled.
   - Use explicit allowlists for structural emitters and any transparent safe wrapper/inline elements that are necessary for readable XHTML.
   - Skip the entire subtree of every other element. This includes namespace-prefixed script-like content and unlisted active containers such as `audio`, `video`, and `canvas`.
   - Do not allow skipped-subtree text, attributes, descendants, captions, or URLs to leak into an allowed ancestor.
   - Add malicious regressions for namespace-prefixed script and representative unlisted active containers nested inside otherwise allowed content.

2. **Rejected images consume the retained image budget and emit empty image blocks.**
   - Increment `maxImages` accounting only for retained normalized HTTP(S) image candidates.
   - Do not emit empty image blocks for rejected/missing candidates.
   - Invalid/data/local images must not prevent later safe text or valid image candidates from being parsed.
   - If caption-only readable content is retained, count it only under the appropriate block/element limits and keep its representation deterministic.

3. **Caption-only readable content is classified as capture failed.**
   - Include normalized non-empty captions in the same usable/readable-content decision used to derive `ready`, `reviewSuggested`, or `captureFailed`.
   - Keep readiness semantics aligned with `CleanArticle.readableContentSHA256`.
   - Add a caption-only fixture/test.

## Minor proof gaps

- Reference `&xxe;` inside an otherwise allowed text block and prove neither external replacement bytes nor declaration/entity text survives. No file/network I/O may occur.
- Add direct `maxDOMElements` proof and a rejected-image-exhaustion test that verifies later safe content survives.
- Strengthen revision hash tests:
  - spoken text, caption, and block-order changes must change the hash;
  - metadata-only, block-ID-only, and URL-only changes must not change the readable/spoken hash.

Binding constraints:

- Preserve the typed immutable domain interfaces, stable IDs/ordinals, canonical snapshot hash, trim/exclusion ordering, and metadata overlay behavior.
- Keep external entities disabled and never evaluate/fetch/render content.
- Bounds must remain streaming/fail-closed without accumulating an unbounded DOM.
- Stay within Task 4 production, tests, and authored fixture files. Do not touch Task 1–3 storage, the Xcode project, narration files, or `ARCHITECTURE.md`.
- Run build/tests serially and verify no prior Xcode process is live before starting the next command.

Verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleBlockSanitizerTests`
- `make test-only FILTER=EchoTests/ArticleRevisionServiceTests`
- `git diff --check`

Commit subject:

`fix: harden article block sanitation`

Append a “Fix round 1” section to `task-4-report.md`, mapping each finding to code/tests and reporting exact serial receipts. Return the short status contract.
