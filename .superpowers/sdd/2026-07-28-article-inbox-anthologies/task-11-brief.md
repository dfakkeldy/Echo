# Task 11 — Deterministic interoperable EPUB 3.3 build and preflight

## Frozen base

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Branch: `codex/article-anthology-design`
- Base commit: `9fa50389664cb0f0b14bccefdcefb623b8110a7a`
- Plan: `docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`, Task 11
- Task 10 manifest contract is frozen and reviewed.

## Ownership and exclusions

Create only the Task 11 EPUB implementation/tests under:

- `Shared/ArticleWorkshop/AnthologyCoverRenderer.swift`
- `Shared/ArticleWorkshop/EPUBXMLWriter.swift`
- `Shared/ArticleWorkshop/AnthologyEPUBBuilder.swift`
- `Shared/ArticleWorkshop/AnthologyEPUBPreflight.swift`
- `EchoTests/ArticleWorkshop/AnthologyEPUBBuilderTests.swift`
- `EchoTests/ArticleWorkshop/AnthologyEPUBPreflightTests.swift`

Small, demonstrated Task 11 changes to an existing Article Workshop model/test helper are allowed if required, but report them explicitly.

Do not touch:

- `Echo.xcodeproj/project.pbxproj`
- `ARCHITECTURE.md`
- `EchoCore/Services/Narration/NarrationService.swift`
- `EchoCore/Services/Narration/NarrationFileNaming.swift`
- `EchoTests/NarrationFileNamingTests.swift`
- the sibling Global Pronunciation worktree
- Task 12 import/UI integration
- any physical device

## Required behavior

Use test-driven development. First prove RED for missing EPUB builder/preflight, then implement the smallest compatible design.

Build a deterministic EPUB 3.3 archive from `AnthologyBuildManifest`:

- `mimetype` must be first and stored without compression.
- `META-INF/container.xml` must point to `EPUB/package.opf`.
- Use the manifest `epubIdentifier`; `dcterms:modified` comes from manifest `modifiedAt`.
- Assign every ZIP entry the same manifest timestamp so an identical manifest produces byte-identical output.
- Chapter filenames use stable slots: `EPUB/articles/article-s<stableSlot>.xhtml`.
- Navigation and spine order use `chapter.order`.
- XHTML block IDs use `echo-s<slot>-b<index>` with reserved indices:
  - 0 title
  - 1 byline
  - 2 publication/site/date
  - 1000 + `ArticleBlock.stableOrdinal` body
  - 900000 source/capture note
- Source links are present, escaped, HTTP(S)-only, credential-free, and carry `data-echo-narration="skip"`.
- Escape all XML/XHTML content and attributes, including title, creator, URLs, metadata, alt text, and block text.
- Local images must be copied as declared manifest assets with correct media types and safe unique relative paths.
- Generated default cover must be deterministic for fixed input. User-selected managed covers must be safely read and included without persisting arbitrary external paths.
- No absolute path, backslash traversal, empty component, dot component, `..`, duplicate normalized path, undeclared asset, or unsafe href may enter the archive.
- Avoid unbounded reads/decode. Reuse existing bounded Article Workshop file primitives where possible.
- Do not introduce a third-party dependency. Confirm ZIPFoundation is already present before using it.

Runtime preflight must reopen the emitted archive and fail closed on:

- missing/duplicate/unsafe entries;
- incorrect first/uncompressed `mimetype`;
- missing required container/package/nav/chapter/cover/assets;
- malformed XML/XHTML;
- duplicate IDs or hrefs;
- package/spine/nav references that do not close over declared manifest items;
- media-type mismatch or undeclared assets;
- invalid stable IDs/slots/order;
- identifier or revision mismatch;
- credential-bearing or non-HTTP(S) source links;
- manifest/result digest mismatch.

`AnthologyEPUBBuildResult` must contain the temporary URL, EPUB SHA-256, manifest SHA-256, identifier, and revision. The builder writes only to the caller-provided temporary destination; Task 12 owns atomic publication/import.

## Verification

At minimum:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyEPUBBuilderTests
make test-only FILTER=EchoTests/AnthologyEPUBPreflightTests
```

Also run affected Article Workshop regressions and:

- two builds from the same manifest compare byte-for-byte and SHA-for-SHA;
- hostile string/path/URL/image fixtures;
- a tampered archive matrix;
- `git diff --check`;
- formatting/source privacy scan;
- EPUBCheck if the repository already provides it locally. If unavailable, report it as unavailable, not passing, and leave external compatibility gates pending.

Do not claim physical-device, external-reader, import, hosted-CI, merge, install, or release proof.

## Review and commit

Self-review first. Then obtain separate read-only specification and implementation/adversarial reviews against a frozen commit. The implementer—not reviewers—fixes confirmed issues, maximum five fix rounds.

Write the report to:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-11-report.md`

Commit subject:

`feat: build article anthology epubs`

Return the exact commit SHA, clean status, exact test counts, preflight/tamper evidence, EPUBCheck status, reviewer verdicts, and every pending proof gate.
