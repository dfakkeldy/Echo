# Echo: Audiobook Study Player

> For every mind — turn listening into learning.

[![CI](https://github.com/dfakkeldy/Echo/actions/workflows/ci.yml/badge.svg)](https://github.com/dfakkeldy/Echo/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Echo plays the audiobooks you own, aligns them with EPUB/PDF text, and helps you turn useful passages into spaced-repetition study cards. It can also narrate text-only documents on-device. It runs on **iOS/iPadOS 18+, macOS 15+, and watchOS 11+**; Watch is a companion to the iPhone player.

**Documentation reviewed against `nightly` on October 24, 2026.** Implemented source, a TestFlight build, and public release availability are separate states. Check the notes for the build you install.

## Start here

| Resource | Purpose |
|---|---|
| [Website and documentation](https://dfakkeldy.github.io/Echo/) | Getting started, guides, manual, glossary, and devlog |
| [User manual](https://dfakkeldy.github.io/Echo/manual.html) · [Markdown](docs/guides/user-manual.md) | Import, playback, reading, narration, study, exports, and platform differences |
| [Learning guide](https://dfakkeldy.github.io/Echo/learn.html) | The study workflow and the research behind it |
| [Focus field guide](https://dfakkeldy.github.io/Echo/focus.html) | ADHD/AuDHD strategies, with sources |
| [Beta guide](https://dfakkeldy.github.io/Echo/beta.html) | Access, requirements, feedback, and current limitations |
| [Glossary](https://dfakkeldy.github.io/Echo/glossary.html) | Plain-language definitions |
| [Devlog](https://dfakkeldy.github.io/Echo/devlog.html) | Dated development history linked to commits |
| [KinNoKi Labs](https://kinnokilabs.com/apps/echo) | Echo's marketing home and App Store-facing support links |

## Why Echo exists

Echo began with interrupted audiobook listening on a mail route: loop a difficult chapter, recover context after a pause, and save a thought without losing the passage. Dan directs AI coding agents to build and maintain the app, using it in daily life and refining what gets in the way.

You can use it as an ordinary player. The reading and study tools are there when you need them.

## Current capabilities

- **Your library.** Load DRM-free MP3/M4A/M4B files or folders, including multi-file M4B books. Files can stay in your selected folders. The phone's Books shelf shows books with listening history and groups related editions; Mac shows the full imported catalog.
- **Playback for interruptions.** Adaptive Smart Rewind, pitch-corrected speed, chapter/section navigation, playlist/chapter/bookmark looping, sleep timer, voice-memo and photo bookmarks, configurable controls, optional focus soundscapes and visualizers.
- **Read alongside audio.** Searchable EPUB and PDF companions, automatic and manual alignment, word following, audio-only transcription, and Visual Listening for figures/code. Matching editions and alignment quality matter; word following is not a promise of perfect timing for every book.
- **Narrate documents.** EPUB, PDF, Markdown, and plain text use the on-device narration pipeline on iPhone/iPad and Mac. Kokoro provides pronunciation controls; optional Phonon 31M has different hardware, IPA, and timing support. Mac's **Batch → Narrate Documents…** processes multiple documents.
- **Capture and review.** Mark Passage on phone/Watch, Card Inbox, editable cards and decks, FSRS review, chapter Study Plans, local notes, and listening/study statistics on iPhone/iPad. Mac has Card Inbox and Daily Review; detailed phone Insights and some study controls still differ.
- **Watch companion.** Up to five pages of five controls, Digital Crown volume/scrubbing, bookmarks, study review, and timers. **Watch Inbox** queues native dictation for a configured HTTPS webhook through the phone, with optional book context and acceptance status.
- **Audiobookshelf.** Browse, filter, download, and exchange progress on iPhone/iPad and Mac, with multiple saved servers and visible import/retry states. Playback is download-based; streaming and fully resumable background transfers remain deferred.
- **Portable outputs.** Chaptered M4B audio, per-book and full-library study-note bundles, a text-only auto-export Markdown mirror, and Mac Anki export/AnkiConnect. The phone deck picker accepts Echo JSON/folders; the tested `.apkg` backend is not a reachable phone import action.
- **Articles and anthologies.** Capture article text, assemble ordered anthology chapters with voice choices, and narrate through the same reader/player pipeline. Article captures and anthology drafts have their own private CloudKit sync path.

### Platform and availability boundaries

The **Echo Widget extension is watchOS-only**, with circular and rectangular Smart Stack/complication families. iPhone Lock Screen playback uses system Now Playing. An iOS Control Widget exists behind a source gate but is not shipped by that extension target.

Source files in iCloud Drive, Audiobookshelf progress, public CloudKit alignment lookup, private article sync, and WatchConnectivity are separate mechanisms. **Full private-iCloud study-state sync for ordinary cards, decks, bookmarks, and playback is unfinished.** Sharing an audio folder does not transfer the local study database. Public alignment uploads are unavailable in Echo 1.0.

On iPhone/iPad, **Echo Pro is a one-time unlock**: core import, playback, and reading stay free; free narration covers one chapter per book and flashcards are capped at 20. The current Mac has no Pro purchase/restore UI and does not enforce those phone caps. StoreKit supplies current prices and purchase availability.

Local playback, narration inference, and alignment process your files on-device. Model downloads and optional external AI, Audiobookshelf, article sync, and Watch Inbox use network services. External AI sends source text to the selected provider. Read the [privacy policy](https://dfakkeldy.github.io/Echo/privacy.html) for the feature-specific transfers.

## A short study workflow

1. Add an audiobook and matching EPUB/PDF, or narrate a text document.
2. Align the companion text; read/search/tap to revisit useful passages.
3. Mark a passage while listening. Turn it into a question later in Card Inbox.
4. Review due cards or chapter assignments and grade your recall.
5. Export notes and audio when you want a copy for another tool.

The [manual](docs/guides/user-manual.md) has current Settings paths, PDF read-along instructions, Watch Inbox setup, and troubleshooting. The [roadmap](ROADMAP.md) tracks incomplete work; historical plans are dated records, not availability guides.

## Build and contribute

Open `Echo.xcodeproj` in Xcode with the required Apple platform SDKs. App targets use Swift 6 with default MainActor isolation; keep media, database, and transcript work off the main actor. Follow [AGENTS.md](AGENTS.md) for repository and shared-Mac build scheduling rules.

| Command | Purpose |
|---|---|
| `make help` | List supported targets |
| `make doc-contract-test doc-automation-test` | Fast documentation/help contracts and automation tests; no Xcode |
| `make test` | Unit tests in `EchoTests`; serial simulator execution |
| `make build-tests` | Build test products once |
| `make test-only FILTER=EchoTests/TOCTreeBuilderTests` | Rerun a suite without rebuilding |
| `make echo-cli` | Release CLI with the required incremental compilation settings |
| `make architecture` | Refresh the architecture source tree while preserving manual notes |
| `make devlog-update` | Regenerate the previous calendar week's dated commit digest |

Run agent-started Apple builds/tests through the build-slot wrapper specified in your working instructions. **Use `make echo-cli` rather than a bare CLI scheme build**: its Release and compilation-mode settings are required. The shared `Echo` scheme includes `EchoTests` and `EchoUITests`; `make test` and CI explicitly select only `EchoTests`. Hosted CI compiles the embedded Watch app; Watch test execution is separate.

Useful contributor references:

- [Architecture and release engineering](ARCHITECTURE.md)
- [Roadmap](ROADMAP.md) and [changelog](CHANGELOG.md)
- [Website maintenance](docs/README.md)
- [Release checklist](docs/release-checklist.md) and [Fastlane](fastlane/README.md)
- [EPUB pronunciation authoring](docs/epub-pronunciation-authoring.md)
- [PDF read-along authoring](docs/pdf-readalong-authoring.md)
- [Phonon narration](docs/phonon-narration.md)
- [Versioned renderer](docs/guides/versioned-echo-renderer.md)

`Tools/transcription_generator.py` is a separate optional faster-whisper utility; the app's alignment uses WhisperKit. Its environment is documented in `Tools/requirements.txt` and its CLI help.

### Branches and checks

```text
feature/* → nightly → weekly → main
```

Feature PRs target **nightly**. Promotions are separate release decisions. Hotfixes normally start from `main` and are merged back down.

CI runs fast documentation contracts before the required **Build gate + tests** job. Documentation-only PRs can skip Apple compilation; app changes build/test the iOS scheme, embedded Watch/widget, Mac, and Release CLI. The workflow selects an available iOS 26.x simulator and records its actual destination. A passing docs check does not prove an app build or device behavior.

Scheduled TestFlight workflows run from the default branch and check out the selected train. Uploads, processing, external eligibility, and Beta App Review remain separate steps. **A version tag alone does not submit or publish an App Store release.** See [release engineering](ARCHITECTURE.md#release-engineering--promotion-ladder).

### Accessibility

Echo bundles **Lexend** and **OpenDyslexic**, supports Dynamic Type and VoiceOver, and respects Reduce Motion. The silver/gold infinity identity reflects its AuDHD origins. Font preference is personal; neither font is presented as a treatment or a guaranteed reading improvement.

## Credits and license

Created by **Dan Fakkeldy / KinNoKi Labs**, with AI-assisted development. Contributors and upstream projects are listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Echo is licensed under [GPL-3.0](LICENSE), with an [App Store distribution exception](LICENSE-APP-STORE-EXCEPTION.md). Do not commit private books, transcripts, generated study material, credentials, or personal captures.
