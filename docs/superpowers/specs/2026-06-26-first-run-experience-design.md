# Echo First-Run Experience — Design Spec

*2026-06-26 · branch `claude/ecstatic-borg-a7e8df`. Companion to [the all-paths test map](2026-06-26-first-run-and-all-paths-map.md), which holds the exhaustive current-vs-desired path matrix and test assertions. This spec is the decision-locked design for the first-run redesign.*

## 1. Problem & goals

A brand-new user lands on a dead end: the Now Playing tab showing "No track selected" with no call-to-action, an unlabeled folder glyph as the only discovery affordance, an empty library, and a fully-written but **never-presented** `OnboardingView` (`hasSeenOnboarding` is never checked). macOS has no first-run at all.

Goals:
- A new user can do something valuable in seconds — either **press play on a bundled manual** or **open their own folder**.
- The "we don't copy your files" promise is communicated accurately, where everyone sees it.
- The best content on-ramps (the manual, Audiobookshelf, narration, transcription) become discoverable instead of buried.
- Content-aware behavior: what happens on open depends on what's in the folder.
- Returning users whose files moved get a real recovery path, not the newcomer's dead end.

Non-goals (explicitly deferred): bare-audio "transcribe → AI flashcards" generation; an on-device in-Echo card generator; EchoDeckBuilder transcript-input mode; recursive multi-disc folder scanning (messaging only for 1.0); a native mirror of the marketing website.

## 2. Locked decisions

| # | Decision |
|---|----------|
| Manual role | Listen-first **bundled starter book**, seeded into the library on first launch. |
| Manual artifact | `~/Developer/echo-manual-build/welcome-to-echo/dist/Welcome-to-Echo.epub` (16 ch, 44k words, 28 placeholder images). **Not** the explainer-audiobooks series. |
| Manual audio | **Hybrid:** the opening chapter's narration is **pre-rendered + bundled** (instant play); once playback starts, the remaining chapters **narrate on-device** progressively. |
| Manual entry | "Play / Read the welcome manual" opens the **bundled EPUB** (self-contained); no runtime dependency on the website. |
| Web page | `dfakkeldy.github.io/Echo` stays the **external marketing front door** + desktop reference `manual.html`; kept in sync via `doc-sync`. |
| Auto-play | New **Settings → "Auto-play on open"** toggle, **default OFF**. When ON, applies to audio-first opens only (never text-only). Default keeps load-don't-play with a prominent Play affordance. |
| MP3 ordering | Honor embedded **track-number/disc** metadata; fall back to natural filename sort; **show the order** so it's verifiable. |
| Audiobookshelf | One-tap **"Connect to demo"** → the community `audiobooks.dev` demo (`demo`/`demo`, listed in ABS's official README), with a graceful-offline fallback; no self-hosted server for 1.0. |
| Companion docs | Audio + **one** EPUB/PDF → auto-load it; **multiple** → load the **name-matching** one; none matching → offer to import. PDF now auto-imports too (today only EPUB does). |
| Flashcards | **EPUB round-trip first:** "Open in EchoDeckBuilder" (macOS) + Echo's **vNext importer**. Bare-audio "Transcribe → flashcards" is a forward-hook only. iOS "Make flashcards" = export the EPUB for EchoDeckBuilder on Mac. |

## 3. Design

### 3.1 Routing & the first-run gate
- Entry stays `EchoCoreApp.swift` → `RootTabView` (iOS) / `MacTriPaneView` (macOS).
- Reuse the existing `@AppStorage("hasSeenOnboarding")` flag but repurpose it to gate the **new native landing page**, not the dead 4-page carousel.
- First-launch sequence: seed the bundled manual into the library (§3.3) → show the landing page over the empty Now Playing surface.
- The landing page also reappears whenever the library is genuinely empty (e.g., the only book's files went missing — see §3.8), so "empty" always has a way forward.

### 3.2 Landing page (native)
Replaces the "No track selected" empty state. Three actions, ranked by the "most people just want to listen" principle (see mockup screen 1):
1. **Open a folder** — primary (accent). Existing `FolderPicker` (`asCopy:false`).
2. **Play the welcome manual** — secondary. Opens the bundled manual (§3.3).
3. **Connect a server** — tertiary, "demo" tag. ABS connect with one-tap demo pre-fill (§3.6).

No-copy reassurance lives here, stated precisely for the dominant (audio) case: *"Echo plays files where they live — it never copies them, so don't delete the originals."* A **"How do I add books?"** link opens a helper covering: Files app / iCloud "Keep Downloaded" / AirDrop, and the nuance that EPUB/PDF companions *are* copied into the book's folder while audio and `.md/.txt` are referenced in place. This finally surfaces `HelpContent`'s buried no-copy text where every new user sees it.

### 3.3 Bundled manual (listen-first hybrid) + seeding
- **Bundle** `Welcome-to-Echo.epub` into Echo's resources. **Pre-render the opening chapter's audio + word-level alignment** (the manual's first chapter — file `ch00`, "Welcome to Echo"; optionally through the next chapter) via the `echo-cli`/overnight harness, and bundle those alongside.
- **Seed** on first launch: create the audiobook + track DB records so the manual is the first library item, with its EPUB blocks imported (reusing the existing EPUB import pipeline) and the opening chapter's alignment attached so read-along works immediately.
- **Playback:** the opening chapter plays instantly from the bundled audio. **Once playback starts**, on-device narration renders the remaining chapters progressively (extends the existing `startNarrationPlayback` render-ahead, which today renders all chapters on-device with no pre-bundled head). A quiet, non-blocking banner shows "Narrating the rest on-device — N/16" (mockup screen 3). `NarrationSilenceGuard` (PR #144) covers the on-device chapters; the bundled opening chapter is guaranteed clean for the first impression. The on-device chapters depend on the narration-reliability requirement in §7 — that pass **gates shipping the bundled manual**.
- **Freshness:** the manual is dated 2026-06-22 and can drift from shipped features — re-run the `echo-manual-epub` skill and re-verify before bundling, and treat manual refresh as a recurring `doc-sync` item.

### 3.4 Content-aware open + auto-play
The engine already makes *one folder = one book* (`folderURL` is the book identity), so this governs post-load behavior:
- **Audio present** (1 M4B / MP3 folder / multi-M4B): load, show the book, make **Play unmissable**; auto-play only if Settings → "Auto-play on open" is ON (default OFF). MP3 order per the metadata→filename rule, shown for verification.
- **Companion document auto-load** (audio + EPUB/PDF in the same folder): if there's **exactly one** EPUB/PDF, load it automatically. If there are **multiple**, load the one whose filename **matches the audiobook/M4B name** (extension- and case-insensitive, natural match); if none matches, **don't guess** — show the *Read along with the ebook* / *Add a PDF* nudge so the user chooses. Extends today's behavior (`EPUBAutoImportScanner` grabs the first EPUB; PDF isn't auto-imported) to (a) include **PDF** and (b) disambiguate by **name match** instead of "first found".
- **Text only** (EPUB/PDF/.md): never auto-plays; offers narration via the (now dismissible) narration nudge.
- **Empty / unsupported-only folder:** explicit message ("Echo plays MP3, M4A, and M4B") and **suppress** the narration nudge, which currently misfires on `tracks.isEmpty` regardless of whether any document exists.
- **M4B chapters in the Contents/TOC view:** chapters are already parsed (and aggregated across multi-disc with cumulative offsets) and shown in the chapter picker; add a fallback so the Read-tab TOC tree (today EPUB-only, `MacTOCTreeView`) lists `state.chapters` when there's no EPUB.

### 3.5 Dismissible help nudge system
A small, non-blocking stack beneath the transport (mockup screen 2). Hard rule (and test assertion): **never overlaps the play/scrub controls.** Content-aware — only shows what's actually missing:
- 1 M4B alone → *Read along with the ebook · Add a PDF · Transcribe to make searchable · New here? Open the manual.*
- M4B + EPUB present → drop the ebook offer; keep transcribe + manual.
- Each is individually dismissible. **Persistence:** new `nudge_dismissal` table keyed per-book + per-type; dismissed offers stay dismissed across launches and are re-enableable in Settings. Exceptions: the manual offer is session-only; the narration offer (text-only books) persists until narration starts.

### 3.6 Audiobookshelf one-tap demo
- An existing community demo, **`https://audiobooks.dev`** (login `demo` / `demo`), is listed in Audiobookshelf's official README. The **"Connect to demo"** affordance (in the ABS connect flow and from the landing page's "Connect a server") pre-fills it so users see a real ABS library in one tap.
- **Caveats that drive the UX:** it's volunteer-maintained (one community member), has no uptime guarantee, and ABS guest/demo accounts are **not strictly read-only**. So: label it "community-maintained demo — may be unavailable", handle connect failures gracefully (clear "demo's offline — connect your own server" fallback, never a dead end), and never write to it. We do **not** self-host a server for 1.0; revisit a self-hosted read-only LibriVox instance only if the community demo proves unreliable.

### 3.7 Transcription wiring + flashcards (EPUB round-trip)
- **Wire transcription** (the whole feature is wiring — `StandaloneTranscriptionService` exists but is instantiated nowhere): a "Transcribe to make searchable" action (from the nudge and `BookSettingsView`), shown only when `!hasEPUB && !hasPDF` → run on-device WhisperKit → progress UI (adapt `AutoAlignmentProgressView`) → on completion show `StandaloneTranscriptView`. Optional FTS5 index on `standalone_transcript.text` (today's search is a client-side filter).
- **Flashcards (EPUB round-trip):** implement Echo's **vNext importer** — add `sourceAnchor` to `FlashcardDeckImport.ImportedCard`; resolve `s<i>-b<j>` to local `epub_block.id` via a new `EPUBSourceAnchorResolver` (mirrors `DocumentImportFinalizer`'s portable-ID convention); wire into `DeckImportService` + `ApkgImportService`. Add **"Open in EchoDeckBuilder"** for the current EPUB on macOS. On iOS, "Make flashcards" = export the EPUB for EchoDeckBuilder on Mac; deck imports back. Bare-audio transcript→cards stays a forward-hook.

### 3.8 Silent-failure / returning-user hardening
Folded in because a returning user whose file moved currently hits the *same* dead end as a newcomer:
- `restoreBookmark()` returning `nil` (`Persistence.swift:238-240`) → show "Can't find this book's files — they may have moved or been deleted" with a **Re-select** action, instead of silently dropping to empty.
- Narration OOM/model failure (`.fail()` today has no UI) → surface an error with retry.
- macOS scope-loss (device unmounted) → same recovery affordance.
- Nested/multi-disc folder → explicit "Echo loads files from the top level of the folder; flatten multi-disc books" message (recursive scan deferred).

### 3.9 Permissions
Move the notification-permission prompt from app launch (pre-context, before the view tree renders) to **first flashcard creation**, asked in-context. Mic permission stays system-handled on first voice memo.

### 3.10 Platform scope
- **iOS/iPad first:** wire the landing page in place of the dead onboarding; iPad landscape polish.
- **macOS:** a tri-pane-appropriate first-run equivalent (it has none today). The "Open in EchoDeckBuilder" hand-off is macOS-only by nature.
- **watchOS / CarPlay:** light "open a book on your phone" guidance only; no full flow. CarPlay must never show first-run modals while driving.

## 4. Data model changes
- **`nudge_dismissal`** table: `(audiobook_id, nudge_type, dismissed_at)`; per-book per-type dismissal state.
- **Optional FTS5** virtual table over `standalone_transcript.text`.
- Both are GRDB migrations → must follow the schema-migration rules (version-number collision checks, `SchemaVxxTests`) and trigger **`doc-sync`** (ARCHITECTURE.md / README.md / CHANGELOG.md). Run the schema-migration-reviewer before committing.

## 5. Build order (phasing)
1. **First-run shell:** landing page + routing gate + no-copy copy + empty-state recovery (§3.1, §3.2, §3.8 partial). Highest user-visible payoff, no schema change.
2. **Bundled manual:** pre-render the opening chapter's audio+alignment, bundle EPUB, seed on first launch, hybrid playback (§3.3). Depends on a manual freshness pass **and the on-device narration-reliability pass (§7)**.
3. **Content-aware open + auto-play setting + TOC fallback + empty/unsupported messaging** (§3.4).
4. **Nudge system + `nudge_dismissal` migration** (§3.5).
5. **Transcription wiring (+ optional FTS5)** (§3.7 first half).
6. **Flashcards vNext importer + "Open in EchoDeckBuilder"** (§3.7 second half).
7. **Silent-failure hardening completion + permission re-timing** (§3.8, §3.9).
8. **macOS first-run equivalent + watch/CarPlay guidance** (§3.10).

Phases 1–4 constitute the core first-run experience; 5–8 harden and extend. EchoDeckBuilder integration (phase 6) and the manual pre-rendering (phase 2 prereq) are sizeable enough to be their own PRs.

## 6. Testing
The all-paths test map ([2026-06-26-first-run-and-all-paths-map.md](2026-06-26-first-run-and-all-paths-map.md)) is the test matrix: §B (content-combination), §C (per-book actions), §E (edge/returning/platform), and §H (verified-but-risky). Key assertions to add: nudge never overlaps transport; dismissed nudge stays dismissed across launches; stale-file restore shows recovery UI (not empty); empty/unsupported folder shows the format message and no narration nudge; auto-play obeys the default-OFF setting; MP3 order honors track metadata.

## 7. Risks & requirements
- **On-device narration reliability — REQUIRED (owner-confirmed).** The manual's chapters beyond the bundled opener, and every EPUB-narration path, depend on the on-device engine — which has an OOM-past-~8-chapters and intermittent all-zero (silent) chunk history. Reliability is a hard prerequisite, not a nice-to-have: keep/strengthen `NarrationSilenceGuard` (detect + retry + re-split, PR #144), render on-device chapters in **fresh processes batched ≤~5 chapters** (per the overnight findings) to avoid jetsam OOM, and add **per-chapter error UI + resume**. Bundling the opening chapter only de-risks the *first* impression; the rest must still render cleanly. Treat a narration-reliability pass as a **gating dependency** for shipping the bundled manual (build phase 2).
- **Manual staleness** — bundled content drifts from shipped features; refresh (`echo-manual-epub`) + verify before any release that bundles it.
- **Demo ABS server — RESOLVED to a fallback.** Point at the community `audiobooks.dev` demo; fail gracefully when it's down or changed; don't depend on it (see §3.6).
- **Resolved smaller items:** PDF auto-import → handled by the companion-document rule (§3.4); AirDrop copies into the sandbox → message accordingly; FTS5 → ship with transcription, or accept the client-side filter initially.
