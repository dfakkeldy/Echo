# The Echo Beta Tester Guide

Welcome — and thank you. Echo is built by one person around a full-time mail route, which means every tester genuinely moves the project. This guide covers how the beta works, how to send feedback that actually helps, and a set of structured test plans if you want to hunt bugs on purpose.

The short version: **use Echo like you really listen** — commute, chores, workouts, bedtime — and tell us the moment something feels wrong.

---

## 1. Joining the beta

1. Install **TestFlight** (Apple's free beta app) from the App Store.
2. Open your Echo invite link on the device — it opens in TestFlight.
3. Tap **Accept**, then **Install**. Echo appears on your home screen like any app, with a small orange dot in TestFlight marking it as a beta.

Don't have an invite yet? Request access via [GitHub Issues](https://github.com/dfakkeldy/Echo/issues) — include the device you'd test on.

**Requirements:** a recent iPhone (the on-device alignment uses the Neural Engine, so newer hardware aligns faster). Apple Watch and Mac are optional but very welcome test surfaces — the watch app installs automatically from the iPhone's Watch app.

**Updates:** TestFlight notifies you when a new build lands. Each build's **What to Test** notes tell you where to aim. Beta builds expire after 90 days; updating resets the clock.

**Your data:** beta builds share data with release builds going forward — but it's a beta, so keep your source audiobook files backed up (you should anyway; Echo never modifies them).

---

## 2. Sending feedback that helps

### The fastest way: TestFlight screenshots

See something wrong? **Take a screenshot right then.** Tap the screenshot preview → **Share** → **Send Beta Feedback**. Your note arrives with the build number, device model, and iOS version attached automatically — that's half the diagnosis done.

### Crashes

If Echo crashes, TestFlight will offer to send the crash report with a comment box. Please add one sentence about what you were doing — a crash log with *"happened when I tapped Auto-Align on a 40-hour book"* is worth ten without.

### Trackable bugs & feature ideas: GitHub

For anything you want tracked (or to check whether it's known): [github.com/dfakkeldy/Echo/issues](https://github.com/dfakkeldy/Echo/issues). The developer reads every one.

### Reporting alignment problems (special instructions)

Alignment bugs are the most valuable reports and need the most context. Include:

- **Book title + narrator** (different narrations of the same book behave differently)
- **Where the ePub/PDF came from** — store, edition, year if you know it (editions drift; that's often the whole bug)
- **What the audio is** — single M4B, folder of MP3s, LibriVox, Libation export…
- **Where it went wrong** — chapter and roughly what the text said vs. what was playing
- Whether **Auto-Align** had run, and whether you'd placed any **manual anchors**

> "Book X aligned perfectly except chapter 7 drifted ~30s after an ad-libbed intro; ePub is the 2nd edition from Kobo; audio is a Libation M4B" — that's a *perfect* report.

---

## 3. Structured test plans

Pick whichever matches your life. Each plan is 10–20 minutes of intentional testing.

### Plan A — The Commute Run *(Smart Rewind & interruptions)*
1. Start a book, then live your interrupted life: pause for seconds, for minutes, for an hour.
2. Each resume: did Smart Rewind back up a sensible amount? Did it ever dump you somewhere confusing?
3. Mid-sentence, unplug your headphones / disconnect Bluetooth. Echo should pause — never blast the speaker.
4. Take a phone call. After it ends, does Echo behave correctly (resume if it was playing, stay paused if you'd paused)?

### Plan B — The Alignment Gauntlet *(EPUB + auto-align)*
1. Put an ePub in the audiobook's folder; confirm Echo imports it automatically.
2. Run **Auto-Align Chapters** and watch the progress view (plug in for long books — the first run also downloads the ~40 MB speech model).
3. Spot-check five chapters: tap a paragraph, does audio land on those words (or close)?
4. Find the worst spot and fix it: long-press → **Align to Now**. Does the surrounding text snap into place?
5. Search a distinctive phrase; tap the result. Text and audio should jump together.
6. **No ePub at all?** Pick an audio-only book and let Echo transcribe it on-device — the book should open in the reader with tap-to-seek and search working, even though no ebook exists.
7. If your book has pictures or code listings, watch Now Playing while aligned audio plays: it should become a **Visual Listening** slideshow (the active figure, a caption, word-by-word highlight).

### Plan C — The Study Session *(bookmarks, flashcards, review)*
1. While listening, make three bookmarks: one plain, one with a **voice memo**, one with a **photo**.
2. Re-listen across them: does the voice memo play inline? Does the player artwork switch to your photo and back?
3. Promote a bookmark to a **flashcard** (front as a question). Attach the audio snippet.
4. Tomorrow, when the review notification arrives: do your **Daily Review** on the phone — then try a session on the **watch**, hands-free.
5. Grade honestly and check the stats module updates (due / reviewed today / total).

### Plan D — The Library Stress Test *(formats & playlist)*
1. Load your messiest book: a multi-file M4B, a 100-file LibriVox folder, weird filenames.
2. Check the chapter list: grouping sensible? Sections under chapters where expected?
3. Drag-reorder a few tracks; dim one (e.g., a disclaimer track) and confirm playback skips it.
4. iCloud users: try a book *without* "Keep Downloaded" on cellular — how does Echo cope? Then set Keep Downloaded and compare.
5. Drop an ePub (or PDF) beside an M4B of the same book: the Library should show **one card**, not two. Open the card's context menu — switch between editions, then try **Separate This Edition** and confirm it splits out.

### Plan E — The Wrist-Only Day *(watch remote)*
1. From the phone (Settings → Controls → **Watch App Settings**), design your layout with the slot pickers — up to five pages of five buttons; leave one page empty and confirm it hides on the watch.
2. Drive a full listening session from the watch only: play, skip, sections, loop, speed, sleep timer, a bookmark with a voice memo, a **Mark Passage**.
3. Try the Digital Crown both ways. As **volume**: a gauge should appear as you turn, with a gentle click per step. As **scrubbing**: check the deadzone (brushing the crown shouldn't jump position).
4. Glance surfaces: the watch progress bar should render one capsule per chapter (with matching arcs around the play ring), and the **Smart Stack card** and watch-face complication should track real playback — cover, state, percentage.
5. Leave the watch off-wrist overnight; next morning, raise it: right book, right position, no phantom commands?
6. Run a **Pomodoro**: set 25 minutes, lower your wrist, confirm the alarm is unmissable.

### Plan F — The Accessibility Pass
1. Crank Dynamic Type to a large size: anything truncated, overlapping, or unreadable?
2. Switch the reader font to **OpenDyslexic**, then **Lexend**; adjust size and line spacing.
3. If you use VoiceOver: a pass over the player and reader — every control labeled and operable?
4. Enable Reduce Motion: anything still animating that shouldn't?
5. Set Appearance to **Cover** mode (and try the **Vivid Cover Accent** toggle) across a few very different covers — pale, dark, garish. Is every control still legible, in both light and dark rooms?

### Plan G — The 1.0 Preview *(as builds gain the new features)* 🚧
The last road-to-1.0 features land build-by-build — each build's **What to Test** notes say which are live. (Stats, the Card Inbox, Anki import, and Context Memory have all shipped and now have their own plans below.) When your build has these:
1. **Instant-start narration:** tap Narrate and time how long until the first words — playback should begin while later chapters are still rendering.
2. **Brain Dump:** park an untethered thought ("buy stamps") without touching the book; dictate a note from the watch mid-chapter. Playback should never hiccup, and the note should land on the right book.
3. **Study sync:** with two devices on the same iCloud, create a card on one and review it on the other; bookmarks and playback position should follow too.
4. **Chapter-study closeout:** let a chapter end and watch for the retire-into-your-cards prompt; grade honestly and confirm the schedule picks it up.
5. **Coverage heatmap:** open a book's coverage view — does the heatmap match which chapters you've actually heard?

### Plan H — The Narrator *(on-device narration — no audiobook needed)*
Echo's flagship new surface. Works on every device Echo supports — no special chip required.
1. Import a **text-only EPUB** (one with no matching audiobook) and tap **Narrate**. Echo voices it on-device — no cloud, no account. The first-ever narration downloads the voice model (~163 MB) once; after that, note your device and how long the first words take.
2. Watch the **status card** while it works — download, loading, rendering, playing, the render-ahead buffer — and expand its history. Does it ever stall silently or say something untrue?
3. Try a plain **.md / .markdown / .txt** file too: does it import and narrate, with chapter breaks in sensible places?
4. Read along as it narrates — words should light up exactly in time (narrated books carry per-word timings). Scrub, then tap a paragraph: does the voice follow?
5. Switch the narrator voice — then give just **one chapter** a different voice (an appendix, an interview) and confirm only that chapter re-renders.
6. Open the playlist: the full chapter outline should be there up front. Tap a chapter to **exclude** it from narration (greyed, speaker-slash), then re-include it — instant, no re-render.
7. In **Book Settings**, check the **pronunciation report**: odd names and abbreviations flagged? Fix one and confirm the affected chapters re-render. If your build has the listen-back QA pass, run it and see what it flags.
8. Narrate as many chapters as you like — narration is unlocked for the whole beta (Plan K). Report anything that stops you.

### Plan I — The PDF Companion
1. Import a **PDF** — as a book's companion (slides, a scanned textbook, sheet music) or on its own. The import button takes EPUB and PDF and routes automatically.
2. Reader tab: toggle **page view ⇄ reflow view** — Echo should remember your choice per book. Continuous scroll and pinch-zoom smooth? Pages legible at your text size?
3. With matching audio (or narration), page view should follow along and highlight the active word **on the page**; tap a word to seek. Report anything that drifts or won't seek (PDFs imported long ago may need a one-time re-import).
4. Press-hold a word → **Look Up**, then **Save Word**. The saved word should appear as a vocabulary flashcard carrying its context sentence.
5. A text-bearing PDF with no audio should offer a **Narrate** button — try it.

### Plan J — Import, Export & Take It With You
1. Export an audiobook as **.m4b** (the "Export Audiobook (.m4b)…" action). Open it in another player: do chapters, cover, and metadata survive? This works for narrated books too — a text-only EPUB can leave Echo as a real audiobook.
2. If your book has figures and alignment (or narration), try **Export Video** — landscape and portrait. Slideshow, captions, and karaoke subtitles look right? A subtitle file and chapter list should ride alongside.
3. Export your study notes as **Markdown** — formatting and passages intact? If you've enabled Pro's **Auto-Export** folder, add a note and confirm the mirrored file updates on its own.
4. **Anki import:** bring a real .apkg deck. Counts right? Scheduling sensible (mature cards not reset)? Cloze cards reported in the summary?
5. Anki **.apkg** deck *export* lives in the Mac app only — skip that one if you are testing on iPhone.

### Plan K — Echo Pro *(nothing to buy during the beta)*
Echo Pro is **fully unlocked for every beta tester**. There is no paywall in this build, no in-app purchase, and nothing to buy in the TestFlight sandbox — so there is no purchase flow to test yet.

When Echo Pro does ship it will be a **one-time unlock, never a subscription**.

1. Use every feature freely and tell us which ones you would actually have paid for — that is the feedback worth having right now.
2. Report anything that locks a feature it shouldn't. Nothing in this build should be gated.

### Plan L — The Mac *(if you test on macOS)*
1. Import a book — or a whole folder of EPUBs.
2. Use **Narrate EPUB(s)…** from the menu; if you queued several, watch the batch queue chew through them (overnight is the intended use), then export the results.
3. Read along in the reader — live word highlighting included. Do the media keys and the system Now Playing widget behave?
4. Try the **Article Workshop**: capture a page, or paste a list of links into an anthology; assign a voice per piece; publish and confirm it lands as a normal book.
5. Export an audiobook, a video, or a deck. Known honest gaps — AI card generation currently starts from iPhone/iPad (the Mac sets preferences), and the Mac PDF reader is reflow-only for now. Anything *else* Mac-only broken, or different from the phone?

### Plan M — Audiobookshelf *(self-hosters)*
1. Settings → Library & Accounts → **Connections**; add your server. Self-signed certificate? You should see its fingerprint exactly once, then never again for that server.
2. Browse with the real filters — sort orders, author/series/genre/tag filters, the "Not Added to Echo" filter. Do the result counts look right for your library?
3. Download a book and watch the stages — Downloading, Extracting, Validating, Adding to Echo — then tap **Open in Echo** at the end. Cancel one mid-way and retry it.
4. Save a **second server** and switch between them without re-entering credentials.
5. Listen on one device, then confirm progress synced back to the server (and to Echo on another device — the Mac counts). Report anything that double-counts or resets position.
6. Known wrinkle: cover thumbnails don't load from self-signed servers yet — no need to report that one.

### Plan N — Mark & Convert *(capture without breaking flow)*
1. While listening — ideally mid-chore — tap **Mark Passage** on the dock. Playback must never stop. Do it from the watch too.
2. Later, open the **Card Inbox**: your marks, grouped by book, with context (and a transcript snippet on aligned books). Convert one into a card — write the front as a question — dismiss another, leave a third.
3. In the reader feed, use the **capture bar**: type a note, then hold to record a voice memo, all while playback continues. Both should thread into the feed at the right position; the memo should play back from its row.
4. Promote a note to a bookmark, and a bookmark to a flashcard.
5. Turn on **Chapter Checkpoints** (in Settings): at a chapter boundary Echo should pause and ask — replay, grade it and move on, or wait. Does the configurable delay behave? Does the new-chapters-per-day cap hold?

### Plan O — Articles & Anthologies
1. On iPhone/iPad, capture a few web articles into the **Article Inbox** (Library tab). Try the optional cleanup — did it strip the clutter without eating real content? Images preserved?
2. Order several captures into an **anthology** and build it. It should import as an ordinary Echo book.
3. Now treat it like any book: read it in the feed, narrate it, bookmark it, make a card from it, export it as a chaptered m4b.
4. On two devices? Confirm captures and anthology drafts followed you through your iCloud.

### Plan P — Stats, Sessions & Context Memory
1. After a few days of normal listening, open **Stats** (More menu): do the totals, streak, time-of-day patterns, and per-book chapter coverage match your memory of the week?
2. Study numbers: the retention curve, grade mix, and 30-day due forecast — does the forecast react when you add a batch of new cards?
3. Open **Sessions** — your listening diary. Tap a session and confirm the reader feed scopes to exactly what that session covered.
4. Opt in to **Context Memory** (Settings → Advanced & Privacy). Bookmark something on a walk — the place chip should be neighborhood-approximate, never your doorstep. In airplane mode, bookmarks must still save instantly (just placeless).
5. Press **Delete Location History** and verify everything location-shaped is gone.

### Plan Q — AI Card Generation *(opt-in, bring your own key)*
1. Settings → Study & Notes → **AI Card Generation**. Three providers: your own Anthropic API key (the book's text goes to Anthropic **only when you generate** — that's the honest deal; the key lives in your Keychain), on-device Apple intelligence on the newest iPhones/Macs (nothing leaves the device), and a deterministic on-device fallback that should always be available.
2. Generate cards from a chapter; they should arrive validated and editable before anything is saved.
3. Accept a batch and confirm the cards **drip** into your study plan over following days rather than flooding day one.
4. Flip the provider picker (auto / cloud / on-device) and confirm it does what it says.

### Auto Study Plan Beta Pass

1. Import or open an EPUB-backed book.
2. Open Book Settings and tap Study Plan.
3. Confirm front matter is not selected.
4. Create a plan with 1 chapter per day and image cards enabled.
5. Open the Reviews/Study dashboard card.
6. Confirm due cards appear before new chapter assignments.
7. Play a chapter assignment, reveal the retention prompt, and grade it.
8. Reopen the queue and confirm the graded assignment is no longer shown as new.

---

## 4. Known limitations (current beta)

Honest list — these are known, so you don't need to report them (though opinions on them are welcome):

- **First auto-align is heavy.** Model download (~40 MB) + Neural Engine work; phones run warm on long books. Plug in. (First-ever narration similarly downloads a ~163 MB voice model.)
- **Full study sync is still landing.** iCloud sync currently covers alignment anchors and article captures/anthology drafts; cards, bookmarks, and playback position across devices is road-to-1.0 work (Plan G).
- **Edition drift is real.** Auto-align gets you close; some books need two or three manual anchors. That's expected, not a bug — but tell us about books that need *lots*.
- **AI card generation starts from iPhone/iPad** — the Mac app sets preferences but doesn't generate yet.
- **The Mac PDF reader is reflow-only**; page-view read-along on the Mac is coming.
- **Audiobookshelf cover thumbnails** don't load from self-signed servers yet.

---

## 5. Privacy during the beta

Echo's promise is unchanged in beta: **no analytics, no tracking, no accounts, no Echo servers — alignment, narration, and transcription fully on-device.** The only features that touch the network are ones you opt into: your personal iCloud, your own Audiobookshelf server, Context Memory's approximate place lookup, and AI card generation with your own key (which sends the book's text to Anthropic only when you generate — Plan Q).

One thing TestFlight itself adds: Apple's beta system shares **crash reports** and **the feedback you choose to send** with the developer, along with device/OS/build info. That's TestFlight's standard mechanism (it's how your reports reach us), not telemetry inside Echo. The full policy is at [dfakkeldy.github.io/Echo/privacy.html](https://dfakkeldy.github.io/Echo/privacy.html).

---

*Thank you for testing. Every report makes the player better for the next interrupted listener.* — Dan
