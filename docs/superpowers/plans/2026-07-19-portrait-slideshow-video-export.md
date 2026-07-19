<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Portrait Slideshow Video Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class 1080x1920 Portrait slideshow export while preserving 1920x1080 Landscape as the default and keeping audio, timing, SRT, chapters, cancellation, cleanup, publication, and filenames format-independent.

**Architecture:** Introduce validated shared dimensions and a pure aspect-aware layout value, carry full image-or-code payloads through the existing planner, and make the CoreText/CoreGraphics renderer consume those values. `VideoExportService` performs a live H.264 settings preflight before reading book data, while the CLI, iOS, and macOS surfaces resolve an immutable format request and call the same service. Approved spec: `docs/superpowers/specs/2026-07-19-portrait-slideshow-video-export-design.md`.

**Tech Stack:** Swift 6.0 language mode, Swift Testing, ArgumentParser, SwiftUI, AVFoundation, CoreGraphics, CoreText, ImageIO, Xcode 26.6; no new dependencies.

## Global Constraints

- Work only in `/Users/dfakkeldy/.codex/worktrees/portrait-slideshow-video-export-design/Echo` on `codex/portrait-slideshow-video-export-design`, based on `origin/nightly`; preserve the unrelated changes in `/Users/dfakkeldy/Developer/Echo`.
- Preserve iOS 18, macOS 15, watchOS 11, and Swift 6.0 project settings.
- Every new source, test, and Markdown file starts with the repository SPDX header on line 1.
- Do not add UIKit/AppKit to `Shared/` or `EchoCore/Services/Export/`; those files compile for iOS, macOS, and echo-cli.
- Do not edit generated `project.pbxproj` membership for synchronized source groups.
- Strict TDD for every behavior: add one focused failing test, run it and record the expected failure, implement the minimum production change, then rerun the focused suite.
- Run all builds/tests through `"$HOME/.claude/bin/xcode-build-gate.sh" --wait`; never use uncapped test parallelism or `-jobs`.
- Build echo-cli only with `make echo-cli`.
- Commit each task with the listed Conventional Commit message, staging only named files.
- Do not manipulate shared simulators, devices, Xcode processes, or another worktree.
- Do not include a private real-book path, database content, or media in commits, PR text, logs, or this plan.
- Do not push or open a PR until Dan gives a separate publication approval after local implementation and review evidence is presented. Any PR targets `nightly`, never `main`.

## File and Ownership Map

| Slice | Files | Produces |
|---|---|---|
| Dimensions | `Shared/SlideshowVideoDimensions.swift`, `EchoTests/SlideshowVideoDimensionsTests.swift` | Valid presets, custom-size parsing, validation, orientation profile |
| Layout | `EchoCore/Services/Export/SlideshowFrameLayout.swift`, `EchoTests/SlideshowFrameLayoutTests.swift` | Exact legacy/portrait geometry and typography |
| Planner | `Shared/SlideshowExportPlanner.swift`, `EchoTests/SlideshowExportPlannerTests.swift` | Full image-or-code payloads in frame plans |
| Text | `EchoCore/Services/Export/SlideshowTextFitter.swift`, `EchoTests/SlideshowTextFitterTests.swift` | Bounded caption/subtitle/code fitting and stable Karaoke pages |
| Renderer | `EchoCore/Services/Export/SlideshowFrameRenderer.swift`, `EchoTests/SlideshowFrameRendererTests.swift`, `EchoTests/Support/LegacyLandscapeFrameReferenceRenderer.swift` | Aspect-aware raster frames and code cards |
| Service | `EchoCore/Services/Export/VideoExportService.swift`, `EchoTests/VideoExportServiceTests.swift` | H.264 preflight, validated dimensions, paired sidecar proof |
| CLI | `Tools/echo-cli/ExportVideoCommand.swift`, `EchoTests/SlideshowVideoDimensionsTests.swift` | `--portrait`, optional `--size`, early validation |
| Shared UI | `EchoCore/Views/SlideshowVideoFormatPicker.swift`, `EchoCore/Localizable.xcstrings`, `EchoTests/VideoExportUIWiringTests.swift`, `EchoTests/LocalizationSymbolTests.swift` | Localized selector and accessibility value |
| iOS | `EchoCore/Views/VideoExportProgressView.swift`, `EchoTests/VideoExportUIWiringTests.swift` | Configuration/export/result state machine |
| macOS | `Echo macOS/Views/MacVideoExportView.swift`, `EchoTests/VideoExportUIWiringTests.swift` | Format choice captured before save panel |
| Docs/QA | `ARCHITECTURE.md`, `CHANGELOG.md` | Durable contract, verification receipt |

Implementation order is 1 through 11. Tasks 1 and 2 are independent; after both land, Tasks 3 and 4 may be developed independently, but renderer ownership remains with Task 5.

---

## Task 1: Validated Video Dimensions and Presets

**Files:**

- Create: `Shared/SlideshowVideoDimensions.swift`
- Create: `EchoTests/SlideshowVideoDimensionsTests.swift`
- Modify: `EchoCore/Localizable.xcstrings`

**Interfaces consumed:** `Foundation`, ArgumentParser callers in Task 7.

**Interfaces produced:**

```swift
nonisolated enum SlideshowFrameLayoutProfile: Equatable, Sendable {
    case legacyLandscape
    case phonePortrait
}

nonisolated enum SlideshowVideoFormat: String, CaseIterable, Identifiable, Sendable {
    case landscape
    case portrait

    var id: Self { self }
    var dimensions: SlideshowVideoDimensions {
        switch self {
        case .landscape: .landscape
        case .portrait: .portrait
        }
    }
}

nonisolated struct SlideshowVideoDimensions: Equatable, Hashable, Sendable {
    static let landscape = SlideshowVideoDimensions(validatedWidth: 1920, height: 1080)
    static let portrait = SlideshowVideoDimensions(validatedWidth: 1080, height: 1920)

    let width: Int
    let height: Int
    var layoutProfile: SlideshowFrameLayoutProfile {
        width >= height ? .legacyLandscape : .phonePortrait
    }

    static func parse(_ value: String) throws -> Self
    static func validating(width: Int, height: Int) throws -> Self
}

nonisolated enum SlideshowVideoDimensionError: LocalizedError, Equatable, Sendable {
    case malformedSize
    case nonPositive
    case odd
    case shortestSideTooSmall
    case longestSideTooLarge
    case pixelAreaTooLarge
    case aspectRatioTooExtreme

    var errorDescription: String? { get }
}

nonisolated enum SlideshowVideoDimensionRequestError: Error, Equatable, Sendable {
    case conflictingOptions
}

nonisolated enum SlideshowVideoDimensionRequest {
    static func resolve(portrait: Bool, size: String?) throws -> SlideshowVideoDimensions
}
```

- [ ] Write failing tests for both presets; default/portrait/custom/conflict resolution; lowercase `x`; malformed, negative, zero, odd, `<180`, `>4096`, excessive area, and `>4:1`; exact valid boundaries; Landscape/Portrait/square profiles; and `Int.max` area safety.

Representative assertions:

```swift
@Test func requestResolution() throws {
    #expect(try SlideshowVideoDimensionRequest.resolve(portrait: false, size: nil) == .landscape)
    #expect(try SlideshowVideoDimensionRequest.resolve(portrait: true, size: nil) == .portrait)
    #expect(
        try SlideshowVideoDimensionRequest.resolve(portrait: false, size: "640x360")
            == SlideshowVideoDimensions.validating(width: 640, height: 360)
    )
}

@Test func multiplicationCannotOverflow() {
    #expect(throws: SlideshowVideoDimensionError.longestSideTooLarge) {
        try SlideshowVideoDimensions.validating(width: .max, height: .max)
    }
}
```

- [ ] Run the focused test and confirm it fails because the types do not exist:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

- [ ] Implement parsing with exactly two non-empty lowercase-`x` components. Validate in this order: positive, even, short side, long side, pixel area, ratio. Use `multipliedReportingOverflow` for area and cross-multiplication `longSide <= shortSide * 4` after the 4096 guard.

- [ ] Keep the stored initializer private and use it only for known-valid presets and the throwing factory. Do not add a raw public/memberwise initializer.

- [ ] Add manual English/Dutch catalog symbols for the seven dimension failures and the option conflict. `errorDescription` uses the dimension symbols; the CLI maps the request conflict to `--portrait cannot be used with --size; choose one format option.` Keep the approved English dimension copy exact.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowVideoDimensionsTests
```

Expected: all dimension tests pass.

- [ ] Commit:

```bash
git add Shared/SlideshowVideoDimensions.swift EchoTests/SlideshowVideoDimensionsTests.swift EchoCore/Localizable.xcstrings
git commit -m "feat(export): validate slideshow video dimensions"
```

## Task 2: Pure Landscape and Portrait Layouts

**Files:**

- Create: `EchoCore/Services/Export/SlideshowFrameLayout.swift`
- Create: `EchoTests/SlideshowFrameLayoutTests.swift`

**Interfaces consumed:** `SlideshowVideoDimensions`, `SlideshowFrameLayoutProfile`, CoreGraphics.

**Interface produced:**

```swift
nonisolated struct SlideshowFrameLayout: Equatable, Sendable {
    let canvasRect: CGRect
    let subtitleRect: CGRect
    let captionRect: CGRect
    let figureRect: CGRect
    let outerInset: CGFloat
    let subtitleCaptionGap: CGFloat
    let captionFigureGap: CGFloat
    let preferredCaptionFontSize: CGFloat
    let minimumCaptionFontSize: CGFloat
    let preferredSubtitleFontSize: CGFloat
    let minimumSubtitleFontSize: CGFloat
    let preferredCodeFontSize: CGFloat
    let minimumCodeFontSize: CGFloat
    let captionLineLimit: Int
    let subtitleLineLimit: Int
    let codeContentInset: CGFloat
    let codeLanguageFontSize: CGFloat
    let codeLanguageLineHeight: CGFloat
    let codeLanguageGap: CGFloat

    init(dimensions: SlideshowVideoDimensions)
    func codeContentRect(hasLanguageLabel: Bool) -> CGRect
    func codeLanguageRect() -> CGRect
}
```

- [ ] Write exact-value tests for every 1920x1080 and 1080x1920 value in the approved spec. Use `#expect(abs(actual - expected) < 0.000_1)` for fractional geometry.

- [ ] Add a matrix over valid boundary and representative sizes (`320x180`, `640x360`, `1920x1080`, `1080x1920`, `3840x2160`, `2160x3840`, `720x720`) asserting finite/non-negative rectangles, containment, vertical order, no pairwise intersections with positive area, positive figure height, and preferred fonts greater than or equal to minima.

- [ ] Run `make build-tests` through the build gate and observe the missing layout-type failure.

- [ ] Implement two private value-semantic specifications inside `SlideshowFrameLayout.swift`. Landscape uses the current height formulas exactly, including a zero subtitle-to-caption gap and `0.05H` caption-to-figure gap; Portrait uses `S = min(W, H)`, `M = 0.05S`, and `G = 0.025S` for both gaps. Do not integralize rectangles or expose a template/schema API.

- [ ] Derive code metrics for both profiles from the short side: inset `0.025S`, language font `0.022S`, language line height `1.25L`, and label gap `0.0125S`.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowFrameLayoutTests
```

Expected: exact preset values and invariant matrix pass.

- [ ] Commit:

```bash
git add EchoCore/Services/Export/SlideshowFrameLayout.swift EchoTests/SlideshowFrameLayoutTests.swift
git commit -m "feat(export): add aspect-aware slideshow layouts"
```

## Task 3: Preserve Full Visual Content in the Planner

**Files:**

- Modify: `Shared/SlideshowExportPlanner.swift`
- Modify: `EchoTests/SlideshowExportPlannerTests.swift`

**Interfaces consumed:** Existing `VisualListeningCueResolver.snapshot(...).visualCue?.content`; do not modify the resolver.

**Interface change produced:** replace `SlideshowFramePlan.imagePath: String?` with `visualContent: VisualListeningVisualContent?`.

- [ ] Add failing tests proving image and code payloads, including the optional code language, survive planning and range clamping; distinct code strings with identical narration do not merge; raw code never enters SRT; and existing timing/range tests remain unchanged.

```swift
#expect(plan.frames.map(\.visualContent) == [
    .code(text: "let answer = 42", language: "swift")
])
#expect(plan.frames.map(\.subtitleText) == ["Listing 1."])
#expect(plan.srtCues.map(\.text) == ["Listing 1."])
```

- [ ] Run the planner suite and observe the missing `visualContent` failure.

- [ ] Change frame construction to `visualContent: snapshot.visualCue?.content`; compare full payloads in `appendMerging`; preserve the payload when merging and clamping. Keep captions in the plan for code cues—the renderer owns duplicate-caption suppression.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowExportPlannerTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/VisualListeningCodeCueTests
```

- [ ] Commit:

```bash
git add Shared/SlideshowExportPlanner.swift EchoTests/SlideshowExportPlannerTests.swift
git commit -m "feat(export): preserve slideshow visual payloads"
```

## Task 4: Bounded Text and Stable Karaoke Pages

**Files:**

- Create: `EchoCore/Services/Export/SlideshowTextFitter.swift`
- Create: `EchoTests/SlideshowTextFitterTests.swift`

**Interfaces consumed:** CoreText and `WordTokenizer.wordRanges(in:)`.

**Interfaces produced:**

```swift
nonisolated enum SlideshowTextTruncationBoundary: Equatable, Sendable {
    case composedCharacter
    case word
}

nonisolated struct SlideshowFittedText: Equatable, Sendable {
    let displayText: String
    let fontSize: CGFloat
    let isTruncated: Bool
}

nonisolated struct SlideshowDisplayedWord: Equatable, Sendable {
    let sourceIndex: Int
    let displayRange: NSRange
}

nonisolated struct SlideshowKaraokePage: Equatable, Sendable {
    let displayText: String
    let sourceWordRange: Range<Int>
    let displayedWords: [SlideshowDisplayedWord]
}

nonisolated enum SlideshowTextFitter {
    static func fit(
        _ text: String,
        in rect: CGRect,
        preferredFontSize: CGFloat,
        minimumFontSize: CGFloat,
        maximumLineCount: Int,
        truncationBoundary: SlideshowTextTruncationBoundary
    ) -> SlideshowFittedText

    static func karaokePages(
        for text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        maximumLineCount: Int
    ) -> [SlideshowKaraokePage]
}
```

- [ ] Write failing tests for: preferred fit; deterministic 0.5-pixel shrink steps; caption composed-character ellipsis; simple subtitle word ellipsis; one over-wide token fallback; every source word appearing on exactly one Karaoke page; correct leading/trailing ellipses; all-bold conservative page formation; and stable page membership across active-word changes.

- [ ] Implement measurement with `CTFramesetterSuggestFrameSizeWithConstraints` plus line-count inspection from `CTFrameGetLines`. Choose the greatest fitting size by decrementing in fixed 0.5-pixel steps, never below the minimum.

- [ ] At minimum size, truncate captions at composed-character boundaries and simple subtitles at word boundaries, always reserving a literal `…`. If one token cannot fit, composed-character ellipsize it while retaining the source-word mapping.

- [ ] Build Karaoke pages greedily from consecutive source words using bold font metrics and reserving required leading/trailing ellipses before accepting a boundary. Map each page's displayed ranges back to original source indices; never use heard/active styling to calculate boundaries.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowTextFitterTests
```

- [ ] Commit:

```bash
git add EchoCore/Services/Export/SlideshowTextFitter.swift EchoTests/SlideshowTextFitterTests.swift
git commit -m "feat(export): bound slideshow text and karaoke pages"
```

## Task 5: Refactor the Renderer and Add Code Cards

**Files:**

- Modify: `EchoCore/Services/Export/SlideshowFrameRenderer.swift`
- Modify: `EchoTests/SlideshowFrameRendererTests.swift`
- Create: `EchoTests/Support/LegacyLandscapeFrameReferenceRenderer.swift`

**Interfaces consumed:** `SlideshowVideoDimensions`, `SlideshowFrameLayout`, `SlideshowTextFitter`, and `SlideshowFramePlan.visualContent`.

**Constructor produced:**

```swift
init(
    dimensions: SlideshowVideoDimensions,
    coverArt: CGImage?,
    imageLoader: @escaping @Sendable (String) -> CGImage? = {
        SlideshowFrameRenderer.loadImage(storedPath: $0)
    }
)
```

- [ ] Before changing production rendering, copy only the current ordinary short-text Landscape path into the test-only reference renderer. Add a same-runtime 1920x1080 pixel comparison to lock legacy geometry without a brittle checked-in PNG.

- [ ] Add failing raster tests at both presets for exact output size; portrait/landscape/square image aspect fit; EXIF orientation; unreadable image fallback; cover/no-cover/no-visual states; code with/without language; long horizontal and vertical code; code caption suppression; bounded caption/Simple subtitle; active word visibility; heard/active pixel distinction; stable Karaoke page membership; and changed pixels contained by the declared region.

- [ ] Replace raw width/height storage with validated dimensions and one immutable `SlideshowFrameLayout`. Remove the unchecked initializer.

- [ ] Change the base cache key to:

```swift
private struct BaseKey: Equatable {
    let visualContent: VisualListeningVisualContent?
    let caption: String?
}
```

- [ ] Switch base rendering by payload: `.image` loads and aspect-fits with cover fallback; `.code` renders the code card and suppresses the ordinary caption; `nil` aspect-fits cover; absent cover leaves the dark region. Clip each operation to its layout rectangle.

- [ ] Implement the code card inside `layout.figureRect`: monospaced top-leading text, optional language label, source indentation/newlines, no wrapping, preferred-to-minimum fit, per-line trailing ellipsis, and final visible row `…` when vertical overflow remains.

- [ ] Route caption and Simple subtitle through `SlideshowTextFitter`. Cache Karaoke pages per `(text, rect size, minimum font, line limit)` and select the page containing the valid active index; invalid/nil active index uses Simple fitting. Apply heard/active attributes only through `SlideshowDisplayedWord` mappings.

- [ ] Adapt the existing loader-count test to prove subtitle-only changes reuse the base; prove different code payloads do not reuse it.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowFrameRendererTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowTextFitterTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowExportPlannerTests
```

- [ ] Commit:

```bash
git add EchoCore/Services/Export/SlideshowFrameRenderer.swift EchoTests/SlideshowFrameRendererTests.swift EchoTests/Support/LegacyLandscapeFrameReferenceRenderer.swift
git commit -m "feat(export): render aspect-aware slideshow visuals"
```

## Task 6: Service H.264 Preflight and Format-Independent Outputs

**Files:**

- Modify: `EchoCore/Services/Export/VideoExportService.swift`
- Modify: `EchoTests/VideoExportServiceTests.swift`
- Modify: `EchoCore/Localizable.xcstrings`
- Temporarily adapt compile-time callers in `Tools/echo-cli/ExportVideoCommand.swift`, `EchoCore/Views/VideoExportProgressView.swift`, and `Echo macOS/Views/MacVideoExportView.swift` to pass `.landscape`; Tasks 7–9 replace those defaults with choices.

**Interfaces consumed:** `SlideshowVideoDimensions`, refactored renderer.

**Interface change produced:**

```swift
func exportVideo(
    audiobookID: String,
    bookTitle: String,
    databaseWriter: DatabaseWriter,
    cacheDirectory: URL,
    outputDirectory: URL,
    mode: SlideshowExportMode = .karaoke,
    syncPoint: VisualListeningSyncPoint = .midpoint,
    dimensions: SlideshowVideoDimensions = .landscape,
    range: Range<TimeInterval>? = nil,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
) async throws -> Output
```

**Testable encoder seam produced:**

```swift
nonisolated struct H264VideoSettings: Equatable, Sendable {
    let width: Int
    let height: Int

    var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }
}

nonisolated struct H264VideoSettingsCapability: Sendable {
    let supports: @Sendable (H264VideoSettings) throws -> Bool
    static let live: Self = .init { settings in
        let url = FileManager.default.temporaryDirectory
            .appending(path: "echo-video-preflight-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        return writer.canApply(
            outputSettings: settings.outputSettings,
            forMediaType: .video
        )
    }
}
```

`VideoExportService` stores the capability through an initializer defaulting to `.live`; tests inject a deterministic closure. `writeMovie` receives the already-created `H264VideoSettings` value and derives writer input plus pixel-buffer dimensions from it.

- [ ] Add `ExportError.unsupportedVideoSettings(width: Int, height: Int)` and a test seam that injects a `@Sendable (H264VideoSettings) throws -> Bool` capability closure. `H264VideoSettings` is an immutable `Sendable` value holding dimensions and constructs its `[String: Any]` dictionary only on the actor, so no non-Sendable settings dictionary crosses the closure. Add the manual English/Dutch `videoExportErrorUnsupportedVideoSettings` catalog key and make both platform error switches exhaustive.

- [ ] Write a failing negative-preflight test using a nonexistent audiobook ID and an uncreated output directory. Assert the injected closure receives 1080x1920, the thrown case is `unsupportedVideoSettings`, and no output directory exists. This proves preflight precedes service-owned source/database/output work; the caller has necessarily already supplied a `DatabaseWriter`.

- [ ] Write a 1080x1920 synthesized export test asserting AVFoundation natural size, H.264 video, AAC audio, duration tolerance, and unchanged filename stem.

- [ ] Add a paired Landscape/Portrait export test from the same fixture and plan. Assert `.srt` and `.chapters.txt` data are byte-identical; load chapter metadata groups and compare semantic start/title pairs when stamping succeeds.

- [ ] At the first line after cancellation checking, create one H.264 settings value and run the capability preflight. The live implementation creates a unique temporary `.mp4` URL, removes it in `defer`, constructs `AVAssetWriter`, and calls `canApply(outputSettings:forMediaType: .video)`. Throw the new error before `resolveSourceItems` on false.

- [ ] Pass that same immutable `H264VideoSettings` value into `writeMovie`, and use its `outputSettings` for the real `AVAssetWriterInput`; use its dimensions for the renderer and pixel buffer attributes. Delete the late `width > 0` guard and raw width/height service parameters.

- [ ] Preserve writer error propagation, staging, named-output rollback, cancellation, SRT/chapter formatting, and chapter-atom fallback unchanged.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/VideoExportServiceTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SlideshowFrameRendererTests
```

- [ ] Commit all six explicitly named files together because the signature change must compile atomically:

```bash
git add EchoCore/Services/Export/VideoExportService.swift EchoTests/VideoExportServiceTests.swift EchoCore/Localizable.xcstrings Tools/echo-cli/ExportVideoCommand.swift EchoCore/Views/VideoExportProgressView.swift 'Echo macOS/Views/MacVideoExportView.swift'
git commit -m "feat(export): preflight validated video settings"
```

## Task 7: CLI Portrait and Custom-Size Resolution

**Files:**

- Modify: `Tools/echo-cli/ExportVideoCommand.swift`
- Modify: `EchoTests/SlideshowVideoDimensionsTests.swift`

**Interfaces consumed:** `SlideshowVideoDimensionRequest.resolve(portrait:size:)` and `VideoExportService.exportVideo(...dimensions:)`.

- [ ] Add an optional `@Option var size: String?` and `@Flag(help: "Export a 1080x1920 phone-portrait video.") var portrait = false`.

- [ ] Map `SlideshowVideoDimensionRequestError.conflictingOptions` and each `SlideshowVideoDimensionError` to the exact actionable messages in the approved spec via `ValidationError`.

- [ ] Move dimension resolution to the first line of `run()`, before `DatabaseService(...)`, narrated-source checks, range parsing, and output-directory creation. Pass the validated dimensions to the service.

- [ ] Build only with:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

- [ ] Run executable smoke tests:

```bash
.build/cli/Build/Products/Release/echo-cli export-video --help | rg -- '--portrait|--size'
.build/cli/Build/Products/Release/echo-cli export-video --portrait --size 1920x1080 --db /definitely/missing.sqlite --audiobook-id test --title Test --out /tmp/echo-video-conflict
.build/cli/Build/Products/Release/echo-cli export-video --size 1919x1080 --db /definitely/missing.sqlite --audiobook-id test --title Test --out /tmp/echo-video-odd
```

Expected: help lists both options; conflict and odd-size commands fail with their dimension errors before a database-open error and do not create `/tmp/echo-video-conflict` or `/tmp/echo-video-odd`.

- [ ] Run the pure dimension suite again, then commit:

```bash
git add Tools/echo-cli/ExportVideoCommand.swift EchoTests/SlideshowVideoDimensionsTests.swift
git commit -m "feat(cli): add portrait slideshow export"
```

## Task 8: Shared Format Picker, Localization, and Accessibility

**Files:**

- Create: `EchoCore/Views/SlideshowVideoFormatPicker.swift`
- Modify: `EchoCore/Localizable.xcstrings`
- Modify: `EchoTests/VideoExportUIWiringTests.swift`
- Modify: `EchoTests/LocalizationSymbolTests.swift`

**Interfaces consumed:** `SlideshowVideoFormat` and generated manual localization symbols.

- [ ] Add failing tests that require manual English and Dutch entries for: format label, Landscape, Portrait, both accessibility values with exact resolutions, phone-viewing explanation, and configuration Export button. Also verify the unsupported-video-settings key added in Task 6 remains manual and bilingual.

- [ ] Implement a shared segmented `Picker` bound to `SlideshowVideoFormat`, with visible localized text and an explicit accessibility value returned from a pure format-to-symbol switch. Do not communicate orientation only by color or icon.

- [ ] Use semantic text styles and no fixed font sizes. Keep the view platform-neutral SwiftUI.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/LocalizationSymbolTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/VideoExportUIWiringTests
```

- [ ] Commit:

```bash
git add EchoCore/Views/SlideshowVideoFormatPicker.swift EchoCore/Localizable.xcstrings EchoTests/VideoExportUIWiringTests.swift EchoTests/LocalizationSymbolTests.swift
git commit -m "feat(export): add localized video format picker"
```

## Task 9: iOS Configuration, Export, and Result States

**Files:**

- Modify: `EchoCore/Views/VideoExportProgressView.swift`
- Modify: `EchoTests/VideoExportUIWiringTests.swift`

**Interfaces consumed:** `SlideshowVideoFormatPicker`, `SlideshowVideoFormat.dimensions`, and the new service signature.

**State produced:**

```swift
private struct VideoExportRequest: Identifiable, Equatable {
    let id = UUID()
    let dimensions: SlideshowVideoDimensions
}

private enum VideoExportPhase {
    case configuration
    case exporting(VideoExportRequest)
    case result
}

@State private var phase: VideoExportPhase = .configuration
@State private var selectedFormat: SlideshowVideoFormat = .landscape
@State private var request: VideoExportRequest?
```

- [ ] Extend source-wiring tests to prove the sheet starts in configuration, defaults to `.landscape`, exposes only format (not Simple/Karaoke), captures dimensions in an immutable request, runs `.task(id: request?.id)`, keeps `.karaoke`, disables duplicate starts, and dismisses/cancels the structured task.

- [ ] Replace auto-starting `isExporting = true` with the three phases. Put configuration content in a `ScrollView` for Dynamic Type and small-screen safety. The Export button captures one request and transitions immediately; it is unavailable outside configuration.

- [ ] Attach `.task(id: request?.id)` to the stateful content, guard/copy the request at entry, and pass `request.dimensions`. Preserve background-task handling, progress stream, temporary-directory cleanup, sharing, error mapping, and cancellation behavior.

- [ ] Add the `unsupportedVideoSettings` localized switch case including the requested width and height through `FormatStyle`, not C-style formatting.

- [ ] Run UI wiring, localization, and VideoExportService tests through the gate.

- [ ] Manually inspect the configuration at the smallest supported iPhone Dynamic Type default and an accessibility size; record that labels, resolutions, button, and navigation remain reachable. This is human inspection, not a claim of automated VoiceOver acceptance.

- [ ] Commit:

```bash
git add EchoCore/Views/VideoExportProgressView.swift EchoTests/VideoExportUIWiringTests.swift
git commit -m "feat(ios): configure slideshow video format"
```

## Task 10: macOS Format Capture Before Save Panel

**Files:**

- Modify: `Echo macOS/Views/MacVideoExportView.swift`
- Modify: `EchoTests/VideoExportUIWiringTests.swift`

**Interfaces consumed:** `SlideshowVideoFormatPicker` and new service signature.

- [ ] Add failing source-wiring tests requiring a `.landscape` default, format picker alongside mode picker, both controls disabled while exporting, and immutable `mode + dimensions` capture before `NSSavePanel.begin`.

- [ ] Introduce:

```swift
private struct MacVideoExportConfiguration: Sendable {
    let mode: SlideshowExportMode
    let dimensions: SlideshowVideoDimensions
}
```

Capture it at the start of `presentSavePanel()` and pass it through the panel completion into `startExport(to:configuration:)`. Never read mutable picker state inside the callback or export task.

- [ ] Preserve basename choice, security-scoped access, staging, coordinated three-file publication, rollback, cancellation, and Reveal in Finder.

- [ ] Replace the fixed `460x300` height with a minimum/flexible layout that keeps both pickers and result/error content reachable at larger Dynamic Type settings.

- [ ] Run:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/VideoExportUIWiringTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme 'Echo macOS' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] Manually inspect both pickers and exact resolutions at default and larger text sizes.

- [ ] Commit:

```bash
git add 'Echo macOS/Views/MacVideoExportView.swift' EchoTests/VideoExportUIWiringTests.swift
git commit -m "feat(macos): configure slideshow video format"
```

## Task 11: Documentation, Full Verification, Real-Book Acceptance, and Review

**Files:**

- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`
- Verification only: all implementation files above

- [ ] Update the architecture section with the two presets, Landscape default, CLI custom-size/profile rules, validated-dimensions boundary, H.264 preflight ordering, image-or-code plan parity, exact layout ownership, and format-independent sidecars.

- [ ] Add a concise Unreleased changelog entry naming 1080x1920 Portrait on iOS/macOS/CLI, the retained Landscape default, and bounded code/text rendering.

- [ ] Scan for incomplete markers and stale raw dimensions:

```bash
pattern='TO''DO|TB''D|FIX''ME|place''holder|SlideshowFrameRenderer\(width:|width: width, height: height'
rg -n "$pattern" Shared EchoCore 'Echo macOS' Tools/echo-cli EchoTests docs/superpowers/plans/2026-07-19-portrait-slideshow-video-export.md
```

Expected: no unfinished feature markers and no raw renderer constructor; unrelated pre-existing markers are listed rather than edited.

- [ ] Run the entire local gate:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme 'Echo macOS' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

- [ ] If SwiftLint/SwiftFormat check targets are present, run their non-mutating check modes and require zero new warnings/errors.

- [ ] Locate a local aligned book without recording its path. Export the same short representative range once as 1920x1080 Landscape and once as 1080x1920 Portrait. Prefer a range containing differently shaped images, long text, code, and cover/no-figure states; if one cue type is absent, record it as not exercised rather than claiming it.

- [ ] From copied acceptance outputs, verify both movies with `/opt/local/bin/ffprobe`: exact dimensions, H.264 video, AAC audio, duration, and chapter metadata. Verify chapter atoms with `/opt/local/bin/AtomicParsley` or Echo's existing chapter inspection route. Compare `.srt` and `.chapters.txt` using `cmp` and hashes; expected: byte-identical sidecars for the paired plan.

- [ ] Decode representative frames and inspect region containment, aspect fit, code truncation, caption/subtitle overflow, Karaoke active-word visibility, cover fallback, and Portrait phone readability. Record machine findings separately from human viewing. Do not claim full-book comprehension, physical-device performance, thermals, or background endurance.

- [ ] Commit documentation:

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs(export): document portrait slideshow video"
```

- [ ] Request an independent exact-SHA review from a fresh review subagent. The reviewer checks spec coverage, invalid-dimension reachability, preflight order/settings identity, renderer bounds, stable Karaoke paging, sidecar independence, cancellation/publication regressions, localization/accessibility, and test adequacy. Resolve every finding with TDD and rerun affected suites.

- [ ] Rebase-review the final diff without publishing:

```bash
git status --short --branch
git log --oneline origin/nightly..HEAD
git diff --check origin/nightly...HEAD
git diff --stat origin/nightly...HEAD
```

Expected: clean named branch, coherent commits, no whitespace errors, only in-scope files.

- [ ] Present the exact reviewed SHA, local test results, machine artifact evidence, human-inspection boundary, and final status to Dan. Stop and request explicit approval before any rebase/push/PR action.

## Publication Gate — Only After Separate Approval

- [ ] After Dan explicitly approves publication, fetch and rebase onto the latest `origin/nightly`:

```bash
git fetch origin nightly
git rebase origin/nightly
```

- [ ] Rerun affected tests if the base changed, then push with `--force-with-lease` only if this branch was already published.

- [ ] Open one ready-for-review PR targeting `nightly`, naming the reviewed head and proof boundaries. Never target `main` and do not create a draft unless Dan asks.

- [ ] Follow hosted `Build gate + tests` to completion. If it fails, inspect the failing job logs, reproduce the concrete failure, fix with a focused test, push, and recheck. Implementation is complete only when required hosted CI is green.

- [ ] Final repository check:

```bash
git status --short --branch
gh pr checks --watch
```

Expected: clean worktree, pushed branch represented by the approved PR, required checks passing.
