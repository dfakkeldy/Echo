# Task 11 Report — Deterministic interoperable EPUB 3.3 build and preflight

## Scope and frozen base

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Branch: `codex/article-anthology-design`
- Frozen base: `9fa50389664cb0f0b14bccefdcefb623b8110a7a`
- Changed only the six Task 11 implementation/test files named in the brief, plus this report.
- Did not change the Xcode project, architecture, narration files, Task 12 import/UI, sibling worktrees, or any physical device.
- ZIPFoundation 0.9.20 was already resolved and linked before this task; no dependency was added.

## TDD evidence

- Initial focused RED: the builder suite had 5 tests, 0 passing, 5 failing (7 reported issues) because the builder/preflight types did not exist.
- Preflight boundary RED: after the archive writer existed, 1 builder test passed and 4 failed until runtime preflight and validation were implemented.
- Review fix round 1 compile RED: `make build-tests` failed with exactly 2 missing-type errors before the throwing bounded extraction consumer existed.
- Review fix round 1 behavioral RED: 4/5 declared preflight tests passed, while the 20-case tamper matrix failed with exactly 7 issues because remote chapter/image/style references, stylesheet changes, renamed OPF structures, and wrong XHTML roots/namespaces were accepted.
- Final focused builder suite: 6/6 tests passed.
- Final focused preflight suite: 5/5 declared tests passed. Its parameterized tamper test exercised and rejected all 20 tamper cases; the independent extraction-buffer test proved the first over-budget chunk throws without being appended.
- One pre-fix final preflight launch was killed by the simulator test host before any test began. It produced no test count and is not treated as passing or failing evidence. The immediate retry passed the then-current 4/4 suite.

## Implemented behavior

- Emits deterministic EPUB 3.3 archives with byte-identical results for identical manifests.
- Writes `mimetype` first and uncompressed; all entries receive the manifest timestamp.
- Emits the required container, EPUB package, navigation, cover, stylesheet, and stable-slot chapter paths.
- Uses manifest identity, revision, modified time, language, creator, title, subtitle, navigation order, and spine order.
- Emits reserved narration block IDs and skips narration for the safe source link.
- Escapes XML/XHTML text and attributes and rejects invalid XML characters.
- Emits deterministic generated SVG covers or bounded, digest-named managed covers read without following symlinks.
- Writes only the caller-provided destination, refuses an existing destination, and removes its own partial output after failure.
- Runtime preflight reopens the archive, applies entry-count limits, aborts decompression on the first over-budget chunk, validates archive paths and closure, parses XML with external resolution disabled, validates exact container/OPF/XHTML roots and direct structure, compares all generated text resources byte-for-byte against the manifest-derived output, validates IDs/references/media types/metadata/stable slots/source URLs, and recomputes both EPUB and manifest receipts.
- Builder and preflight compile out on targets where ZIPFoundation is not linked, preserving the shared-source watch/widget builds.

## Image asset boundary

Task 10's frozen manifest contains remote article image candidate URLs, but it does not contain a durable mapping from an image block to a managed local file, safe archive-relative path, media type, and digest. Task 11 therefore cannot safely copy article images without refetching, guessing, or persisting arbitrary paths. The builder fails closed with `missingImageAssetMapping` for any article image block. Actual local article-image inclusion remains an explicit upstream manifest/capture contract dependency; it is not silently dropped or claimed complete.

## Verification

- `make build-tests`: passed after final formatting and warning cleanup.
- `make test-only FILTER=EchoTests/AnthologyEPUBBuilderTests`: 6/6 passed.
- `make test-only FILTER=EchoTests/AnthologyEPUBPreflightTests`: 5/5 declared tests passed; the tamper matrix rejected 20/20 cases.
- Determinism: the builder test creates two EPUBs from one fixed manifest and confirms byte-for-byte equality plus equal SHA-256 receipts.
- Hostile fixtures: XML metacharacters in text/attributes, source URL credentials, remote or undeclared chapter resources, external stylesheet references, stylesheet content injection, renamed OPF manifest/spine structures, wrong XHTML roots/namespaces, invalid manifests, unsafe managed covers, unmapped images, unsafe ZIP paths, duplicate normalized paths, extraction overflow, and result-digest mismatch are covered.
- Affected Article Workshop regression run: 63/63 tests passed across `AnthologyBuilderViewModelTests`, `AnthologyCoverStoreTests`, `AnthologyServiceTests`, `ArticleWorkshopFileStoreTests`, and `SchemaV37ArticleWorkshopTests`.
- `git diff --check`: clean.
- Strict Swift format lint on all six owned source/test files: clean.
- Privacy/source scan: no network-fetch API, user-specific path, embedded credential, token, or secret. Matches were limited to credential rejection logic, the deliberate hostile credential fixture, and bounded test-only reads of generated EPUBs.
- EPUBCheck: unavailable locally (`epubcheck` is not installed and the repository provides no Task 11 local runner). This is pending, not passing.

## Review

- Implementer self-review: complete; confirmed issues were fixed before the final gates.
- Initial read-only specification review of `b1f3d1d3665a770516a2200b782d68a92cb2b873`: FAIL. It confirmed permissive OPF/XHTML structure validation and the separate upstream article-image mapping dependency.
- Initial read-only implementation/adversarial review of `b1f3d1d3665a770516a2200b782d68a92cb2b873`: FAIL. It confirmed unsafe/undeclared generated-resource references, non-aborting extraction overflow, and permissive XML structure checks.
- Implementer fix round 1: all confirmed core preflight/extraction defects were fixed and covered by independent regressions. The article-image mapping dependency was not broadened into upstream schema/capture work.
- Read-only specification re-review of `c07efac0cb84867966fbae78efa48ee63716f9fa`: `WAITING_FOR_DEPENDENCY`. It confirmed the structural defect is fixed and no core EPUB/preflight defect remains; the only incomplete specification item is the upstream managed article-image mapping contract.
- Read-only implementation/adversarial re-review of `c07efac0cb84867966fbae78efa48ee63716f9fa`: PASS. It independently passed 5/5 preflight tests, all 20/20 tamper cases, the extraction-overflow regression, and `git diff --check`, with no confirmed implementation defect.
- VERIFY only: a descriptor-backed single-file validation design would further narrow path-based TOCTOU exposure; standalone watch/widget scheme builds have not been run. Neither is claimed passing.

## Proof status

- Local core EPUB implementation and preflight: passed the checks listed above.
- Task 11 specification completion: waiting for the explicit upstream managed article-image mapping contract.
- Hosted CI: not run.
- Physical iPhone/iPad capture or acceptance: pending; device unavailable and not accessed.
- CloudKit cross-device proof: pending and outside Task 11.
- Task 12 atomic publication/import and stable import proof: pending.
- External reader compatibility and EPUBCheck: pending.
- M4B generation/playback: not part of Task 11; pending in later tasks.
- Human listening: not part of Task 11; pending.
- Merge, installation, and release: pending.
