# Audiobookshelf Browse and Import Reliability — Design

**Date:** 2026-08-12  
**Status:** Approved  
**Platforms:** iOS 18+ and macOS 15+

## Summary

Echo's Audiobookshelf browser will gain server-native sorting and metadata filters, an Echo-local "Not Added" filter, and matching behavior on iOS and macOS. Audiobookshelf imports will become observable staged operations that remain on the browse surface after success or failure. Echo will declare an import successful only after the downloaded archive has been extracted, validated as usable, committed to local storage and persistence, and resolved as a local Echo book.

The existing download-to-local architecture remains unchanged. This work does not add Audiobookshelf streaming, background-resumable downloads, listening-status filters, or new third-party dependencies.

## Goals

- Sort a complete Audiobookshelf library by newest added, title, author, series, or publication year.
- Filter by author, series, genre, tag, and whether an item has not been added to Echo.
- Give iOS and macOS the same behavior and terminology through shared browse and import state.
- Show meaningful download and import progress.
- Keep the Audiobookshelf browser open after an import succeeds or fails.
- Replace silent dismissal with an explicit Added state or a named failure stage and retry action.
- Preserve existing completed imports when a re-import fails.

## Non-goals

- Streaming audio from Audiobookshelf.
- Full background `URLSessionConfiguration.background` downloads or resumable byte-range transfers.
- Listening-status filters such as not started, in progress, or finished.
- Redesigning Echo's local Library.
- Changing server connection, credential, certificate-pinning, or progress-sync behavior beyond the browse/import integration points needed here.

## Current behavior and diagnosed failure boundary

`ABSEndpoints.items` currently hard-codes `media.metadata.title` as the sort. The iOS `ABSBrowseView` and macOS `MacAudiobookshelfViewModel` independently own browsing, search, loading, and errors. Both ultimately call the shared `ABSImportService`, but their import presentations differ.

On iOS, the detail screen shows only elapsed time and an indeterminate spinner. After `ABSImportService.prepareLocalFolder` returns, `PlayerModel.addFromAudiobookshelf` starts the synchronous `loadFolder` entry point and returns. `ABSBrowseView` then dismisses its sheet immediately. The load path does not return a success or failure result to the importer. The reported symptom—returning to Connections with the book absent—therefore cannot be assigned conclusively to network transfer, extraction, media discovery, or local registration from the current UI and logs.

This design moves the success boundary. Sheet dismissal is removed, import stages are observable, staged content is checked for supported content before publication, and the committed result is resolved through local persistence before the UI shows Added. Privacy-safe stage logging leaves evidence for failures that cannot be reproduced in development.

## Approach

Use Audiobookshelf's library-items API for sorting, paging, and individual metadata-filter queries. Use Echo's database only for local provenance state such as "Not Added." A shared observable browse model coordinates both platform views.

This is preferred over loading the entire library and sorting locally because server-native operations remain correct while paging and scale to large libraries. It is preferred over a hybrid that filters only loaded pages because partial results would be misleading.

## Shared browse model

Add a shared `@MainActor @Observable` browse model in `EchoCore`, constructed with the concrete `AudiobookshelfService`, `DatabaseService`, and active server ID. No protocol is introduced; service construction and the existing injectable `URLSession` remain the test seams.

The model owns:

- available libraries and the selected library;
- current search text;
- selected sort and direction;
- selected author, series, genre, and tag filters;
- the `Not Added` toggle;
- filter metadata for the selected library;
- paged results, total result count, and paging/loading/error state;
- locally added remote item IDs for the active server;
- per-item import state and progress.

Changing library, sort, or server-native filters cancels the previous request, clears stale pages, and reloads page zero. Stale responses must not overwrite a newer selection. Changing libraries clears metadata-filter selections because their identifiers belong to the prior library. The user's preferred sort persists locally across launches; filter selections do not.

### Search behavior

Search remains a debounced Audiobookshelf server search. The model intersects its returned item IDs with the complete server-filter result sets described below, applies the selected stable sort, and then applies the Echo-only `Not Added` predicate. The search request limit must be high enough to return the server's complete matching set; if the server reports truncation or cannot provide a complete set, Echo labels the count as limited rather than implying complete-library results.

Search, sorting, and filters must never operate on only the currently visible page while implying complete-library results.

## Sort options

The default is **Newest Added**, which uses the Audiobookshelf library item's `addedAt` field in descending order.

| Echo label | Audiobookshelf value | Direction |
| --- | --- | --- |
| Newest Added | `addedAt` | Descending |
| Title | `media.metadata.title` | Ascending |
| Author | `media.metadata.authorName` | Ascending |
| Series | Echo stable sort by series name, numeric sequence, then title | Ascending |
| Publication Year | `media.metadata.publishedYear` | Descending |

Audiobookshelf's items API does not expose a whole-library series-name sort. Series is therefore the one complete-result local sort: Echo loads every server page, orders books with a series by localized series name and numeric sequence, then title, and places books without a series afterward ordered by title. The UI keeps its loading state until that complete ordering is available instead of presenting a partially sorted page. If an older server rejects another sort field, Echo shows a useful compatibility error rather than silently returning incorrectly ordered results.

`ABSLibraryItem` will decode `addedAt` and any other item-level fields required for stable presentation and tests.

## Metadata filters

For each selected library, Echo requests Audiobookshelf filter metadata containing authors, series, genres, and tags. Filter selectors are searchable multi-select lists because self-hosted libraries may have hundreds of choices.

Audiobookshelf accepts one `group.value` filter per library-items request. For one selection, Echo uses one paged server-filter request. For multiple selections, Echo runs a bounded number of paged requests—one per selected value—and combines the complete item-ID sets locally: union inside a category, intersection across categories. Sorting is applied to the resulting complete set. This preserves the approved multi-select semantics without filtering only the visible page. The model cancels the entire query group when selections change and limits concurrent requests to avoid flooding a self-hosted server.

- Multiple selections inside one category use OR semantics: Author A or Author B.
- Separate categories use AND semantics: selected author and selected genre.
- The UI displays the number of active filter categories/selections and provides Clear Filters.
- Audiobookshelf filter identifiers are encoded exactly as required by its API; views do not construct query strings.

### Not Added to Echo

An Audiobookshelf item is Added only when an Echo `audiobook` record matches both the active `server_id` and `remote_item_id` and its managed local content still resolves as usable. This avoids treating an orphaned database row or missing folder as a successful import.

Imported items remain visible by default with an Added badge. Enabling **Not Added to Echo** removes them from the displayed results. After a successful import, the result set updates immediately without a server reload; if the filter is enabled, the newly added row disappears and the result count updates.

## Import state and progress

The shared model keeps a per-item state:

1. `ready`
2. `downloading(progress)`
3. `extracting(progress)`
4. `validating`
5. `addingToEcho`
6. `added(localBook)`
7. `failed(stage, message, retryability)`

Only one import runs at a time in the first version, matching the current UI and avoiding competing large archive operations on a 16 GB device. Other Add controls are disabled while an import is active.

### Download progress

The download transport reports bytes received and expected bytes when the response supplies a usable `Content-Length` or equivalent expected total.

- With a known total, show a determinate bar, percentage, transferred size, total size, and elapsed time.
- Without a known total, show an indeterminate bar, transferred size, and elapsed time. Do not invent a percentage from the item's metadata size because the whole-item ZIP size may differ.
- Cancellation removes the partial staging download and returns the item to a retryable state.

The existing access-token refresh behavior remains: one refresh and retry after HTTP 401. Progress state resets consistently if the request restarts.

### Extraction progress

`ABSImportService` already reads the ZIP directory before extracting entries. It will report progress by total declared uncompressed bytes when those values are safe and available, falling back to completed-file count. Existing archive size limits and zip-slip protections remain mandatory. Extraction remains off the main actor and propagates cancellation between entries.

### Validation and commit

Before publishing the staging folder, validation recursively finds at least one content file supported by Echo's existing audio or study-document scanners. A ZIP that is non-empty but contains no usable audiobook or study document fails at Validating with a specific message.

After atomic folder publication and provenance persistence, the import coordinator resolves the stored record and managed folder into a local-book result. The UI does not call the fire-and-forget player load as proof of import success. If local registration fails, the operation reports Adding to Echo as failed and preserves or rolls back data according to the existing atomic import rules; it never dismisses silently.

Opening the successfully added book is a separate user action. `Open in Echo` calls the platform's normal local-library opening path, so tab/window navigation and playback loading remain owned by existing player code.

## Failure handling and telemetry

Failures remain on the browse/detail surface and include:

- the named stage that failed;
- a privacy-safe, actionable message;
- Retry when appropriate;
- Cancel during cancellable transfer or extraction;
- no deletion of a previously completed import during a failed re-import.

Logging uses the existing `Logger` infrastructure. It records server ID and remote item ID only as privacy-safe identifiers, stage transitions, HTTP status or local error category, transferred byte count, and whether expected length was known. It must not log credentials, tokens, server response bodies, paths containing private book titles, or book metadata.

## Platform presentation

Both platforms use the same labels, option order, filter semantics, import stages, and empty-state distinctions.

### iOS

- Keep the library picker and searchable list.
- Put Sort in the navigation toolbar.
- Open Filters in a sheet with searchable multi-select sections.
- Show active-filter count and Clear Filters.
- Extend the existing detail screen with staged progress, failure/retry state, and Added/Open in Echo actions.
- Keep the Audiobookshelf browser open after success.

### macOS

- Place Sort and Filters beside the library picker and search field.
- Open filters in a popover or compact sheet using the same shared selections.
- Give selection/detail presentation the same staged import information as iOS instead of limiting imports to a one-line Add button.
- Keep the Audiobookshelf sheet open after success.

### Common states and accessibility

Rows remain visible while another page loads. Refresh preserves the current query. Empty states distinguish an empty library, no search results, no filter matches, and no remaining results under Not Added.

Accessibility labels announce the active sort, active-filter count, import stage, byte progress, and completion. All new user-facing strings are localizable. Dynamic Type and macOS control sizing must preserve readable progress and error content.

## Data flow

1. The platform constructs the shared browse model for the active server.
2. The model loads libraries and local imported IDs.
3. Selecting a library loads its filter metadata and page zero using the selected server sort/filter query.
4. Additional pages append only if they still belong to the active request generation.
5. `Not Added` removes locally usable imported IDs from presentation.
6. Add starts the staged import and streams progress into the shared model.
7. The import service downloads, extracts, validates, atomically publishes, and persists provenance.
8. The coordinator resolves a usable local-book result.
9. The model marks the item Added and updates the current filtered results.
10. Open in Echo hands that local result to the existing platform-specific open action.

## Testing

### Pure and endpoint tests

- Query construction for each sort, direction, and encoded filter combination.
- Filter metadata decoding for authors, series, genres, and tags.
- `addedAt` and relevant metadata decoding across representative ABS response shapes.
- Same-category OR and cross-category AND selection semantics.
- Imported-state matching requires active server ID, remote item ID, and usable local content.
- Request-generation logic rejects stale pages after library/filter/sort changes.

### Download and import tests

- Known-length download reports monotonic bytes and determinate fraction.
- Unknown-length download reports monotonic bytes without a fraction.
- 401 refresh/retry resets transport progress safely.
- HTTP, cancellation, disk-write, corrupt ZIP, extraction-limit, unsupported-content, database, and registration failures identify the correct stage.
- Extraction progress is monotonic and cancellation cleans staging data.
- Unsupported but non-empty archives fail validation.
- Successful import produces a usable local-book result and Added state.
- Failed re-import preserves the previous completed folder and record.

### Browse-model tests

- Newest Added is the default and persists when changed.
- Sort/filter/library changes cancel and replace prior requests.
- Not Added updates immediately after import.
- Failure remains visible and Retry starts from a clean state.
- Success does not dismiss and exposes Open in Echo.
- Search and filter combinations never claim partial-page completeness.

### Platform tests

- iOS and macOS source/wiring tests assert they use the shared browse model and expose matching controls.
- Accessibility identifiers/labels cover sort, filters, progress, failure, Added, and Open actions.
- Targeted SwiftUI or UI smoke tests verify browser retention after success and failure where the existing test infrastructure permits.

### Verification

Run the narrowest relevant tests first, followed by Echo's primary `make test` unit gate through the required Xcode build-slot wrapper. Live acceptance against the owner's Audiobookshelf server should retry the reported Cory Doctorow title and one previously successful title, observing stage progress, Added state, local Library presence, and Open in Echo. Live credentials and private media remain outside committed artifacts.

## Compatibility and rollout

The implementation targets current Audiobookshelf APIs while returning explicit compatibility errors for unsupported optional query fields. Existing connected servers and imported books require no database migration unless implementation proves an index is necessary for efficient `(server_id, remote_item_id)` lookup; a migration must not be introduced speculatively.

The feature can land as one coherent change because shared model, endpoints, import-state contract, and both views must agree for parity. Streaming and fully resumable background transfers remain independently scoped follow-ups.
