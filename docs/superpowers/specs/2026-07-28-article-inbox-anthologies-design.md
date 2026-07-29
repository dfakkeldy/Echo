# Echo Article Inbox and Anthologies

- **Status:** Approved design, pending implementation plan
- **Date:** 2026-07-28
- **Author:** Dan Fakkeldy with Codex
- **Branch base:** `origin/nightly` at `33c17fda`
- **Origin:** Product-design session prompted by Instapaper-style article collection, extended to a private Echo workflow that turns several captured articles into a chaptered EPUB and, through Echo's existing narration pipeline, a chaptered M4B.

## 1. Summary

Echo will gain an **Article Inbox** and **Anthologies** workspace inside the existing Library. A user captures the rendered article they can legitimately view, keeps a private inactive snapshot, optionally performs structural cleanup, orders several articles into a mini-book, and builds a standards-compliant EPUB. Echo imports that EPUB as an ordinary book, making its existing reader, per-chapter on-device narration, pronunciation tools, and chaptered M4B export available without creating a parallel audiobook system.

The product is local-first and snapshot-first:

1. Capture the rendered article into durable local staging.
2. Convert the inactive capture into typed article blocks using a pinned Mozilla Readability build plus Echo's own sanitizer.
3. Keep the immutable capture separate from reversible cleanup edits.
4. Build only from those saved snapshots; never silently refetch a page.
5. Import the generated EPUB through Echo's normal book pipeline.
6. Reuse existing narration and M4B export, invalidating only chapters whose spoken content or voice changed.

Private iCloud sync carries captures, cleanup edits, images, and anthology drafts between the user's devices. Generated EPUB and M4B files remain explicit local products or exports rather than silently synchronized binaries.

## 2. Product outcome

The feature should make this ordinary workflow possible:

> Save several articles during the week on an iPhone, review or trim the awkward captures when useful, arrange them into a small book on an iPad or Mac, read it as an EPUB, and optionally produce a chaptered audiobook.

The user should not need to understand web extraction, EPUB packaging, narration caches, or M4B tagging. The visible model is:

- **Inbox** — saved article snapshots.
- **Anthologies** — ordered projects made from those articles.
- **Books** — built editions ready to read or listen to.

## 3. Existing Echo foundations

The design deliberately reuses these verified repository capabilities:

- [`LibraryView`](../../../EchoCore/Views/Library/LibraryView.swift) and [`MacLibraryView`](../../../Echo%20macOS/Views/MacLibraryView.swift) already provide the cross-platform collection surface.
- [`EPUBImportService`](../../../EchoCore/Services/EPUBImportService.swift), [`EPUBBlockParser`](../../../Shared/EPUBBlockParser.swift), and `EPUBImportCoordinator` already turn an EPUB into Echo's readable block model.
- [`NarrationService`](../../../EchoCore/Services/Narration/NarrationService.swift) already renders EPUB chapters on-device, with per-chapter voices and pronunciation handling.
- [`AudioExportService`](../../../EchoCore/Services/Export/AudioExportService.swift) already produces a single chaptered M4B from ordered narration audio on iOS and macOS.
- `ZIPFoundation` is already linked to the relevant Echo targets and can be reused by the EPUB builder; this design introduces no new archive dependency.
- [`CloudKitSyncService`](../../../EchoCore/Services/CloudKitSyncService.swift) uses the **public** CloudKit database for community alignment anchors. It is not an appropriate transport for private article content and must not be reused as such.

This feature adds capture, workshop persistence, private sync, and EPUB authoring. It does not replace Echo's importer, reader, narrator, or M4B writer.

## 4. Approved decisions

| Area | Approved choice |
|---|---|
| Product placement | Integrated into Echo, not a separate side app |
| Library navigation | One Library with **Books · Inbox · Anthologies** modes |
| Source model | A local snapshot captured at a point in time |
| Capture entitlement | Anything the user can legitimately view, including signed-in pages, when DRM-free; no bypass |
| Primary capture | Safari rendered-page capture on iPhone, iPad, and Mac |
| Other applications | URL fallback; authenticated URL-only captures direct the user to open Safari and share there |
| Extraction | A pinned vendored Mozilla Readability build, explicitly approved as a third-party component |
| Editing | Structural cleanup only in version one |
| Cleanup timing | On demand; clean captures can go straight into an anthology |
| Book pipeline | EPUB-first, followed by Echo's normal import and narration |
| EPUB | Required export |
| M4B | Required export through Echo's existing chaptered exporter |
| Sync | Private cross-device iCloud sync for captures and projects |
| Generated files | Explicit products/exports; not silently synced workshop data |
| Refetch policy | No silent refetch during cleanup, build, rebuild, narration, or export |

## 5. Goals and non-goals

### Goals

- Capture the text and meaningful images of the rendered article the user is viewing, including authorized signed-in content when Safari supplies the rendered page.
- Preserve an immutable, inactive, private source snapshot.
- Make successful captures immediately usable without requiring an editing step.
- Offer bounded structural cleanup: remove a block or image, trim the beginning or end, and correct title/byline/publication metadata.
- Reuse one saved article in multiple anthologies.
- Build a reflowable EPUB 3.3 with a cover, title page, table of contents, one chapter document per article, local images, and source attribution.
- Keep article, block, and anthology identities stable across rebuilding so unchanged narration and study state survive.
- Import a built edition into Echo and expose the normal narration, reading, study, and M4B paths.
- Sync private workshop source material between the user's Apple devices without a cloud extractor or Echo account.
- Report capture, build, narration, and export as distinct states.

### Non-goals for version one

- RSS or Atom subscriptions, newsletters, automatic digests, or background harvesting.
- Chrome or Firefox extensions capable of reading their signed-in rendered DOM.
- Cloud extraction, cloud TTS, AI rewriting, summarization, or translation.
- Arbitrary rich-text editing, layout design, or collaborative editing.
- Pixel-perfect webpage archival, WARC creation, or preservation of interactive experiences.
- Public publishing, hosted anthology sharing, or a collaborative library.
- DRM removal, paywall bypass, credential reuse, or capture of content the user cannot view.
- Silent source refresh after capture.
- PDF capture as an article source.

## 6. Meaning of “snapshot”

An Echo article snapshot is a durable capture of the **reader-relevant rendered article content and metadata at capture time**. It is not a complete copy of the website.

The snapshot may contain:

- source and canonical URLs;
- capture timestamp;
- page title, article title, author/byline, publisher/site, language, and publication date when discoverable;
- the extracted reader-content HTML held only as inactive input;
- the typed block sequence produced from that input;
- local copies of successfully downloaded meaningful images;
- extractor and sanitizer version information;
- content digests needed for duplicate detection and rebuilding.

The snapshot must not contain:

- cookies, authorization headers, form values, or credentials;
- executable scripts, inline event handlers, forms, frames, or service workers;
- general browser history;
- hidden page data unrelated to the extracted article;
- active remote embeds.

Image capture is best effort. Missing images produce a visible warning but do not invalidate an otherwise readable text capture.

## 7. User experience

### 7.1 Library modes

The existing Library gains a platform-appropriate first-class mode selector:

**Books · Inbox · Anthologies**

- On iPhone and iPad, this is a segmented control within Library, not a fourth app tab.
- On Mac, the same three modes appear within the Library surface using native macOS selection treatment.
- The mode selector is accessible, localized, keyboard reachable on Mac, and does not rely on color alone.

**Books** preserves the existing shelf.

**Inbox** shows newest captures first, with:

- title, source, byline when known, capture date, and thumbnail;
- **Ready**, **Review suggested**, or **Capture failed** content status;
- sync state only when actionable or in progress;
- multi-selection for creating an anthology;
- duplicate and missing-image warnings without blocking selection.

**Anthologies** shows projects separately from built books, including:

- title and cover;
- article count;
- last edited date;
- latest built edition revision;
- three independent output summaries: EPUB, Narration, and M4B.

### 7.2 Capture

From Safari, the user chooses **Share → Echo**. The extension acknowledges success only after the capture envelope is durably written to the shared App Group staging directory.

Possible immediate results:

- **Saved to Echo** — durable local staging succeeded.
- **Saved with warnings** — the article text was captured, but extraction or image candidates need review.
- **Could not capture article** — nothing usable was staged; the user receives a concise reason and can retry.

The extension must return promptly. It does not wait for the main app, iCloud upload, image downloads, EPUB construction, or narration.

When invoked from an application that supplies only a URL, Echo performs a local URL fetch. If the fetched response is an authentication page or lacks the viewed article, Echo explains that the user should open the page in Safari and share it from there. Echo never asks for or imports the user's browser credentials.

### 7.3 Cleanup on demand

Opening an Inbox article shows the cleaned reader result. **Clean Up** enters a block editor only when the user wants it.

Version-one operations are:

- remove or restore a paragraph, heading, list, quote, code block, caption, or image;
- trim everything before or after a selected block;
- correct title, author/byline, publisher/site, publication date, and chapter title.

There is no freeform prose rewriting. The immutable capture stays available so cleanup can be reset. Saving cleanup creates a revision recipe over the immutable extracted blocks rather than destructively rewriting the snapshot.

### 7.4 Anthology builder

The user can start from Inbox multi-selection or add articles from an existing anthology. The builder supports:

- drag or keyboard-accessible reordering;
- removing an entry from the project without deleting the Inbox article;
- title, subtitle, creator/editor, and cover;
- a generated cover when none is supplied;
- table-of-contents preview;
- opening an article's cleanup view in context;
- **Build EPUB**.

A project references each article's current cleanup revision. A successful build freezes the exact article revisions into an edition manifest. Later cleanup edits do not silently alter an already-built edition; the anthology becomes **Changes available** until the user rebuilds.

### 7.5 Output detail

The anthology detail keeps three receipts separate:

- **EPUB:** Not built, Building, Ready, Changes available, or Build failed.
- **Narration:** Not started, `N of M chapters ready`, or `K chapters need updating`.
- **M4B:** Waiting for narration, Ready to export, Exporting, Exported, or Export failed.

“EPUB Ready” does not imply narration completion. “M4B Exported” does not imply a human listening pass.

## 8. Ownership and data flow

```text
Safari rendered page / URL fallback
              │
              ▼
Durable App Group capture envelope
              │
              ▼
Immutable inactive article snapshot
              │
              ├── cleanup revision recipe
              │
              ▼
Ordered anthology project
              │
              ▼
Atomic EPUB 3.3 build + validation
              │
              ▼
Normal Echo EPUB import
              │
              ├── reader and study tools
              ├── existing chapter narration
              └── existing chaptered M4B export
```

The boundaries are intentional:

- The share extension owns **capture and durable staging**, not long-running processing.
- The Article Workshop owns **snapshots, cleanup, anthology projects, private sync, and EPUB construction**.
- Echo's book pipeline owns **imported blocks, reading, study state, narration, and media export**.
- A built edition is a normal Echo book with provenance back to its anthology; it is not a special playback mode.

## 9. Conceptual persistence model

The implementation plan must claim the next free additive database migration after checking current `nightly`. This design does not reserve a schema number.

### `article_capture`

One immutable source event.

- stable UUID;
- source URL and canonical URL when known;
- captured date, source application, and rendered-page/URL-fetch capture method;
- extracted metadata;
- capture package relative path and content digest;
- Readability and sanitizer versions;
- content state and warning set;
- current cleanup revision ID;
- creation, update, and deletion/sync bookkeeping.

The capture package lives under Application Support rather than as a large database blob.

### `article_revision`

A reversible cleanup recipe over one immutable capture.

- stable revision UUID and parent revision UUID;
- article capture UUID;
- metadata overrides;
- block inclusion/trim operations;
- derived readable-content digest;
- device and timestamp metadata for conflict presentation.

Base capture blocks retain stable IDs. Cleanup omits or restores them; it does not renumber them.

### `anthology`

The editable project.

- stable anthology UUID;
- title, subtitle, creator/editor, cover reference;
- ordered entry list or related entry rows;
- current project revision;
- latest successful build revision and build status;
- timestamps and sync bookkeeping.

### `anthology_entry`

- anthology UUID;
- article capture UUID;
- display order;
- optional chapter-title override.

The project normally follows the article's current cleanup revision. The built-edition manifest records the exact revisions used.

### `anthology_build`

One successful or failed build attempt.

- anthology UUID and monotonically increasing edition revision;
- stable EPUB identifier;
- exact article revision manifest;
- generated EPUB relative path and digest;
- validation outcome;
- created and modified timestamps;
- linked Echo audiobook/library identity when imported.

A failed attempt does not replace the latest successful build record or file.

## 10. Stable identities and rebuild behavior

Stable identity is required to prevent reordering from destroying narration, bookmarks, notes, and read-along state.

- Anthology identity: `urn:uuid:<anthology UUID>`, unchanged across rebuilds.
- Article identity: capture UUID, unchanged across cleanup revisions and use in multiple anthologies.
- Article document path inside the EPUB: derived from the article UUID, not its ordinal position.
- Block identity: derived from the capture UUID plus a stable base-block ID, not the current spine or chapter index.
- Content validity: article readable-content digest + selected voice ID + narration render version.

The EPUB builder emits inert Echo provenance attributes on the generated XHTML, including stable article and block IDs. Standards-compliant readers ignore these `data-*` attributes. Echo may honor them **only** when the EPUB carries a valid Echo-generated provenance marker and all IDs pass strict format and uniqueness validation. Arbitrary imported EPUBs do not gain authority to choose database IDs.

The importer/reconciliation path for generated anthologies must:

- preserve existing imported block identity when the same stable block remains;
- remove or mark stale only data tied to removed blocks;
- preserve article-owned narration files when only anthology order changes;
- invalidate one article's narration when its spoken digest, voice, or render version changes;
- reassemble playback and M4B order from the current anthology manifest without re-synthesizing unchanged audio.

If current Echo index-based narration filenames cannot meet this contract, the implementation plan must introduce an anthology-specific stable chapter key at the narrow narration-cache boundary rather than weakening the product behavior.

## 11. Capture and extraction pipeline

### 11.1 Safari rendered-page capture

Platform-appropriate Safari share/action extensions use Apple's JavaScript preprocessing bridge to inspect the rendered page the user has already loaded.

The preprocessing script:

1. clones the document rather than mutating the visible page;
2. runs the pinned Readability build against the clone;
3. returns reader-content HTML, safe metadata, base URL, and image candidates;
4. excludes script execution and interactive state from the returned payload.

The native extension treats all returned content as untrusted data, applies envelope limits, and writes one capture package atomically into the App Group staging directory. A completion marker is written last. Partial packages are ignored and later cleaned up.

The main app imports a complete envelope idempotently by capture UUID, verifies its digest and bounds, persists the database row and Application Support package, and only then removes the staging copy.

### 11.2 URL fallback

For URL-only shares, the main app:

1. performs a bounded local `URLSession` fetch;
2. follows ordinary safe HTTP redirects;
3. rejects unsupported schemes and non-document responses;
4. runs the same pinned extraction and typed-block sanitizer;
5. records that the source was fetched rather than rendered.

Build and rebuild never repeat this request. A retry or refresh is an explicit future capture, producing a new article capture rather than mutating history.

### 11.3 Readability component

Echo vendors a reviewed, exact version of [Mozilla Readability](https://github.com/mozilla/readability), the standalone parser used by Firefox Reader View. The implementation must:

- pin an exact upstream release or commit;
- retain the Apache License 2.0 notice and required attribution;
- record the pin and source digest in the repository;
- expose the extractor version in capture metadata for reproducibility;
- update only through an explicit dependency-review change with fixture comparison.

Readability is an extractor, not a trust boundary. Its returned HTML still goes through Echo's native typed-block sanitizer before display, storage as canonical content, EPUB construction, or narration.

### 11.4 Typed-block sanitizer

The sanitizer converts extraction output into Echo-owned values such as:

- heading;
- paragraph;
- ordered/unordered list;
- block quote;
- code/listing;
- meaningful image plus optional caption;
- structural separator.

It does not preserve arbitrary DOM. Text is decoded and later escaped when serialized. Links are normalized to safe `http`/`https` source references; scriptable, local-file, and unknown schemes are rejected. Images are fetched separately with response, MIME, decoded-image, dimension, count, and byte bounds. SVG or other active formats are either rasterized through a safe image path or omitted; they are never copied as executable markup.

All capture and asset limits must be centralized and covered by tests. Exceeding a limit produces a bounded partial result or a clear capture failure, never unbounded memory or disk use.

## 12. EPUB builder

`AnthologyEPUBBuilder` is a shared, non-UI service that consumes one immutable build manifest. It never reads the network.

The generated reflowable EPUB 3.3 contains:

- `mimetype` as the first uncompressed archive entry;
- `META-INF/container.xml`;
- one package document with a stable `dc:identifier`;
- `dcterms:modified` updated for each successful edition;
- title, optional subtitle, language, creator/editor, and publisher metadata;
- a generated or user-selected cover and title page;
- EPUB navigation/TOC;
- one XHTML document per article;
- local image assets with declared media types;
- one small shared stylesheet;
- a source note per article and a final source index.

Each article chapter renders:

1. article title;
2. author/byline, publisher/site, and publication date when known;
3. cleaned article blocks;
4. source attribution and capture date.

Unknown metadata is omitted rather than guessed. If the user supplies no anthology creator/editor, the EPUB and M4B creator default is **Various Authors**.

Source URLs remain usable text links for readers but carry an Echo narration-skip marker. Echo narration speaks the article title, author when present, body, and meaningful visible captions. It skips raw URLs, capture dates, the source index, and decorative image descriptions.

The builder writes to a temporary sibling location, performs internal package preflight, closes the archive, and atomically replaces the stable edition path only after success. Rebuild failure leaves the previous valid EPUB and imported edition available.

### Validation

Runtime preflight checks at least:

- required files and EPUB ZIP ordering;
- parseable container and package documents;
- unique manifest IDs and hrefs;
- complete spine and navigation references;
- valid local resource paths with no traversal;
- well-formed XHTML/XML;
- declared media types matching bundled assets;
- unique Echo provenance IDs.

[EPUBCheck](https://www.w3.org/publishing/epubcheck/) is a repository/CI and release-fixture gate, not an app runtime dependency. The normative format target is [EPUB 3.3](https://www.w3.org/TR/epub-33/).

## 13. Import, narration, and M4B

After a successful build, Echo:

1. retains the EPUB as an explicit shareable product;
2. imports or reconciles it through the normal EPUB pipeline;
3. registers the edition in Books with provenance to the anthology;
4. exposes the existing reader and study tools;
5. makes the existing chapter narration workflow available.

Narration defaults to the anthology's selected default voice and retains Echo's existing per-chapter overrides. The pronunciation preflight and current narration QA remain authoritative.

Narration work is chapter based and resumable:

- a newly added or changed article becomes pending;
- a removed article's audio is no longer selected for the anthology;
- reordering does not re-synthesize;
- changing the anthology default voice invalidates chapters that still inherit that default;
- explicit per-chapter voice overrides remain valid unless that chapter's spoken content changes.

M4B becomes ready only when every included chapter has current narration audio. The existing export stack performs composition, encoding, metadata, cover art, and chapter-marker writing.

M4B metadata:

- title/album: anthology title;
- optional subtitle where supported;
- author/album artist: user-supplied creator/editor or **Various Authors**;
- cover: built EPUB cover;
- chapter marker: `Article Title — Author` when an author exists, otherwise `Article Title`.

Mechanical export success remains separate from a full human listening pass.

## 14. Private iCloud sync

Cross-device workshop sync is part of version one. It is enabled when the user is signed into iCloud, with a visible **Sync Article Workshop** setting. Turning sync off stops new transfers but keeps local data.

The sync implementation uses a dedicated custom zone in the existing container's **private CloudKit database**. It must not use, call through, or place records in the public `CloudKitSyncService` path.

Suggested record ownership:

- immutable capture metadata plus a compressed capture package `CKAsset`;
- immutable cleanup revision records;
- anthology project manifests and cover assets;
- deletion tombstones and per-device change-token/outbox state.

Generated EPUBs, narration caches, and M4Bs do not sync through this subsystem. Another device reconstructs the EPUB deterministically from the synced project and article assets, then narrates locally if requested.

### Local-first behavior

- A capture is complete after durable local staging, not after CloudKit upload.
- Editing and building work offline.
- Local database and files are the immediate source of truth.
- A persisted outbox retries uploads on launch, foreground, and relevant edits.
- Server change tokens support incremental pulls.
- Sync errors do not turn readable local articles into unavailable content.

### Conflicts

Immutable capture records do not conflict.

Cleanup edits create immutable revisions. If two devices edit from the same parent, both revisions are retained and the article is marked **Review edit conflict** until the user chooses the active revision.

For concurrent anthology-project edits, Echo preserves both manifests. One remains the active project and the other appears as a clearly named recovered copy; it never silently discards an ordered article list.

CloudKit account changes, quota exhaustion, and unavailable service are visible actionable sync states, not raw errors. Signing out of iCloud does not delete the local workshop.

## 15. Storage, deletion, and recovery

Suggested Application Support layout:

```text
ArticleWorkshop/
  Captures/<capture UUID>/
  Anthologies/<anthology UUID>/
  Editions/<anthology UUID>/book.epub
```

The share extension writes only to an App Group staging directory. The main app moves verified content into Application Support using idempotent, atomic transactions.

Storage management shows:

- total workshop size;
- capture text/package size;
- image size;
- generated EPUB size;
- narration and M4B storage through Echo's existing storage surfaces.

Exact duplicates are detected using normalized source identity plus content digest and shown as possible duplicates. Echo never silently drops a capture; the user may keep both.

Deleting an Inbox article that is referenced by an anthology is refused by default and identifies the affected projects. An explicit removal flow first removes it from those projects. Existing external exports cannot be recalled; Echo says so plainly.

Deleting an anthology project does not silently delete its reusable Inbox articles. Deleting or rebuilding a generated edition uses atomic replacement and never removes the last valid edition before the replacement passes preflight.

Interrupted operations recover as follows:

- incomplete staging package: ignored and later removed;
- imported staging package with uncleared duplicate: idempotent UUID import, then cleanup;
- interrupted image download: article remains readable with warning;
- interrupted build: temporary output removed, previous edition retained;
- interrupted narration: completed chapter caches remain valid;
- interrupted M4B export: temporary media removed by the existing exporter contract.

## 16. Privacy, rights, and security boundary

The feature is for personal capture of content the user can legitimately access. Echo does not decide whether the user may redistribute a resulting anthology and does not present capture as a license grant.

Hard boundaries:

- no DRM or paywall bypass;
- no credential collection or cookie export;
- no remote Echo extraction service;
- no public CloudKit storage for article content;
- no active HTML execution;
- no hidden refetch during later processing;
- source attribution preserved in the EPUB;
- diagnostics and fixtures never include private captured articles.

Repository fixtures must be authored for Echo, licensed for test use, or public domain. Live signed-in acceptance uses an owner-controlled or otherwise authorized test page and never commits its contents.

## 17. Error and status language

User-facing status reports outcomes and next actions, not implementation details.

Examples:

- **Review suggested — navigation text may be included**
- **Images incomplete — 2 images could not be saved**
- **Open this page in Safari to capture the signed-in version**
- **Saved on this device — waiting for iCloud**
- **Build failed — your previous EPUB is still available**
- **2 chapters need narration before M4B export**
- **Edit conflict — choose which cleanup to keep**

Logs may retain bounded technical diagnostics with private strings redacted. URLs and article text must not be emitted into production logs.

## 18. Accessibility and localization

- Every Library mode, content state, cleanup operation, reorder control, and output state has an accessibility label and value.
- Reordering offers accessible move-up/move-down actions in addition to drag.
- Capture and build status do not rely on color alone.
- Dynamic Type, VoiceOver, keyboard navigation, reduced motion, and high contrast are part of acceptance.
- User-facing strings go through Echo's localization catalog.
- Article language metadata is preserved into the EPUB and supplied to narration where Echo's voice support permits; version one does not promise translation or a compatible voice for every language.

## 19. Verification and acceptance

### Automated unit and fixture tests

- Readability fixture extraction and metadata normalization.
- Typed sanitizer handling of headings, paragraphs, lists, quotes, code, images, captions, and malformed HTML.
- Removal of scripts, forms, frames, event handlers, unsafe URL schemes, traversal paths, oversized payloads, decompression bombs, and invalid image responses.
- Duplicate detection and explicit keep-both behavior.
- Cleanup revision application, reset, stable block IDs, and concurrent revision retention.
- Anthology ordering and immutable build manifests.
- EPUB manifest, spine, navigation, metadata, local resources, source notes, and deterministic stable identity.
- Rebuild reconciliation: unchanged content survives, changed content invalidates only its chapter, reordering does not invalidate narration.
- Atomic build failure retaining the prior edition.
- Sync serialization, outbox retry, tombstones, change tokens, quota/account errors, and conflict-copy behavior using test doubles; no live CloudKit requirement in unit tests.
- M4B metadata and chapter ordering through existing export seams.

### Integration tests

- Share extension envelope creation and App Group import.
- Idempotent recovery after a staged package is imported but not yet removed.
- Generated EPUB import through `EPUBImportCoordinator`.
- Generated provenance acceptance and rejection of spoofed/invalid IDs.
- Narration cache reuse and invalidation.
- M4B assembly using reordered, reused chapter audio.

### Format and application compatibility

- EPUBCheck passes on a representative fixture corpus.
- Sample EPUBs open and navigate correctly in Echo, Apple Books, Kobo, and Calibre.
- Sample M4Bs expose the expected chapter markers and metadata in chapter-aware players.
- Compatibility receipts remain separate; passing EPUBCheck does not claim every reader was tested.

### Real-device acceptance

- Safari capture on iPhone, iPad, and Mac.
- A public article, a long article, an image-rich article, malformed markup, an offline-staged capture, and an owner-authorized signed-in page.
- Capture on iPhone, private sync, cleanup/build on Mac, and the reverse change flow.
- Interrupted and resumed sync.
- VoiceOver and keyboard cleanup/reorder paths.
- A short anthology built, narrated, exported, and listened through completely.

Automated tests, format validation, device capture, third-party reader compatibility, M4B playback, and human listening are reported as separate gates.

## 20. Delivery sequence

All phases are part of version one, but they should land in dependency order:

1. **Local foundation** — additive persistence, file layout, durable App Group staging, typed sanitizer, pinned Readability, and Inbox.
2. **Workshop and EPUB** — cleanup revisions, Anthologies UI, stable identities, builder, validation, atomic output, and ordinary Echo import.
3. **Narration integration** — stable chapter cache identity, selective invalidation, output receipts, and existing M4B export wiring.
4. **Private sync** — private custom zone, assets, outbox/change tokens, conflicts, cross-device UI, and device acceptance.

Each phase stays internal or feature-flagged until its user-visible path is coherent. The feature is not complete merely because capture works; version-one acceptance requires capture through EPUB and M4B, plus the approved cross-device flow.

## 21. Documentation and licensing impact

When implemented:

- `ARCHITECTURE.md` gains an Article Workshop section covering capture, stable identities, private sync, EPUB construction, and the boundary to normal book import.
- `README.md` describes Article Inbox, anthology EPUBs, and optional local narration/M4B.
- Readability's exact pin and Apache 2.0 attribution are added to the repository's third-party notices.
- App privacy wording is reviewed for private iCloud article-content sync.
- Release notes distinguish local capture, private sync, EPUB readiness, narration, and M4B export.

## 22. Implementation-plan guardrails

The implementation plan may choose file names and concrete Swift type boundaries, but it must preserve these approved contracts:

- snapshots are immutable and builds never silently refetch;
- cleanup is structural and reversible;
- private article data never enters Echo's public CloudKit path;
- generated output is a valid interoperable EPUB, not an Echo-only container;
- stable article/block identity survives reorder and rebuild;
- unchanged narration is reused;
- prior valid output survives failure;
- capture, EPUB, narration, M4B, compatibility, and listening remain distinct claims.

No unresolved product decision blocks implementation planning. Schema numbering, exact bounded resource constants, target membership, and the exact Readability pin must be rechecked against current `nightly` during the plan and implementation.
