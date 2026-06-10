# EPUB Reader Feed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 3rd "Read" tab rendering EPUB blocks as a vertically-scrolling card feed with manual alignment via long-press context menu.

**Architecture:** Card-based feed using `UICollectionView` with `NSDiffableDataSourceSnapshot` — same pattern as `TimelineFeedCollectionView`. Each EPUB block (heading, paragraph, image) is a self-sized card cell. Alignment uses the existing `AlignmentService.recalculateTimeline()` which already implements chapter-aware interpolation. The new work is: (1) preserving inner HTML during import, (2) creating two system anchors on first import so every block gets an interpolated timestamp, (3) building the reader feed UI, and (4) wiring long-press alignment actions.

**Tech Stack:** Swift, SwiftUI, UIKit (`UICollectionView`), GRDB, `NSAttributedString` HTML parsing

---

### Task 1: Schema V6 Migration

**Files:**
- Create: `Shared/Database/Schema_V6.swift`
- Modify: `Shared/Database/DatabaseService.swift` (register V6 migrator)

- [ ] **Step 1: Create Schema_V6.swift**

```swift
import GRDB

/// V6 migration — adds html_content and card_color columns to epub_block
/// for the EPUB reader feed (Phase 5.1).
enum Schema_V6 {
    static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "html_content", .text)
            t.add(column: "card_color", .text)
        }
    }
}
```

- [ ] **Step 2: Register V6 in DatabaseService.swift**

Read `DatabaseService.swift` to find the migration registration block (where V1–V5 are registered). Add V6 after V5:

```swift
// Find the migrator.registerMigration("v5") block and add after it:
migrator.registerMigration("v6") { db in
    try Schema_V6.migrate(db)
}
```

- [ ] **Step 3: Build and verify migration runs**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. The V6 migration runs on next app launch and adds the two new columns.

- [ ] **Step 4: Commit**

```bash
git add Shared/Database/Schema_V6.swift Shared/Database/DatabaseService.swift
git commit -m "feat(schema): add V6 migration — html_content and card_color columns on epub_block"
```

---

### Task 2: Update EPubBlockRecord with New Columns

**Files:**
- Modify: `Shared/Database/EPubBlockRecord.swift`

- [ ] **Step 1: Add htmlContent and cardColor properties to EPubBlockRecord**

Read `EPubBlockRecord.swift`. Add two new properties after `text`:

```swift
var htmlContent: String?
var cardColor: String?
```

Add corresponding coding keys in the `CodingKeys` enum:

```swift
case htmlContent = "html_content"
case cardColor = "card_color"
```

Full updated struct (showing only the changed portions — insert after `var text: String?`):

```swift
var text: String?
var htmlContent: String?
var cardColor: String?
var imagePath: String?
```

And in `CodingKeys` (insert after `text`):

```swift
case text
case htmlContent = "html_content"
case cardColor = "card_color"
case imagePath = "image_path"
```

The `init` from decoder is synthesized — the new optional properties default to `nil` for existing data.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds with no coding key mismatches.

- [ ] **Step 3: Commit**

```bash
git add Shared/Database/EPubBlockRecord.swift
git commit -m "feat: add htmlContent and cardColor to EPubBlockRecord"
```

---

### Task 3: Preserve Inner HTML During EPUB Import

**Files:**
- Modify: `OrbitAudioBooks/Services/EPUBImportService.swift`

- [ ] **Step 1: Add htmlContent to TextBlockDescriptor**

In `EPUBImportService.swift`, find `TextBlockDescriptor` struct (near bottom of file). Add `htmlContent` property:

```swift
struct TextBlockDescriptor {
    let kind: EPubBlockRecord.Kind
    let text: String?
    let imagePath: String?
    let htmlContent: String?  // NEW
}
```

- [ ] **Step 2: Update XHTMLBlockDelegate to collect inner HTML**

In `XHTMLBlockDelegate`, add state variables after existing ones:

```swift
private var currentHTML = ""
private var inlineDepth = 0
private var isInBlock = false
private let inlineTags: Set<String> = ["b", "i", "em", "strong", "span", "small", "sub", "sup", "a", "br"]
```

Update `parse(_:)` to reset `currentHTML` alongside `currentText`:

```swift
func parse(_ data: Data) {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    flushBlock()
}
```

Update `parser(_:didStartElement:...)` — replace the existing method. Below the existing skip/heading/img/block logic, add inline tag tracking. The full updated method:

```swift
func parser(_ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String] = [:]) {
    if skipTags.contains(elementName) { skipDepth += 1; return }
    guard skipDepth == 0 else { return }

    if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
        isInHeading = true
        isInBlock = true
        currentHeading = ""
        currentHTML = ""
    } else if elementName == "img", let src = attributeDict["src"] {
        flushBlock()
        textBlocks.append(TextBlockDescriptor(
            kind: .image,
            text: attributeDict["alt"],
            imagePath: src,
            htmlContent: nil
        ))
    } else if blockTags.contains(elementName) {
        flushBlock()
        isInBlock = true
        currentHTML = ""
    } else if inlineTags.contains(elementName) {
        // Build opening tag with attributes
        var tag = "<\(elementName)"
        for (key, value) in attributeDict {
            tag += " \(key)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        tag += ">"
        currentHTML += tag
        inlineDepth += 1
    }
}
```

Update `parser(_:foundCharacters:)` to also append to `currentHTML`:

```swift
func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard skipDepth == 0 else { return }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if isInHeading { currentHeading += trimmed + " " }
    if !trimmed.isEmpty { currentText += trimmed + " " }
    // Preserve raw characters for inner HTML (including whitespace)
    if isInBlock || inlineDepth > 0 {
        currentHTML += string
    }
}
```

Update `parser(_:didEndElement:...)` — replace the existing method. Add inline tag closing and flush htmlContent:

```swift
func parser(_ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?) {
    if skipTags.contains(elementName) { skipDepth = max(0, skipDepth - 1); return }
    guard skipDepth == 0 else { return }

    if inlineTags.contains(elementName) {
        currentHTML += "</\(elementName)>"
        inlineDepth = max(0, inlineDepth - 1)
        return
    }

    if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(elementName) {
        isInHeading = false
        isInBlock = false
        let heading = currentHeading.trimmingCharacters(in: .whitespaces)
        let html = currentHTML.trimmingCharacters(in: .whitespaces)
        if !heading.isEmpty {
            textBlocks.append(TextBlockDescriptor(
                kind: .heading,
                text: heading,
                imagePath: nil,
                htmlContent: html.isEmpty ? nil : html
            ))
        }
    }
}
```

Update `flushBlock()` to include `htmlContent`:

```swift
private func flushBlock() {
    let text = currentText.trimmingCharacters(in: .whitespaces)
    let html = currentHTML.trimmingCharacters(in: .whitespaces)
    currentText = ""
    currentHTML = ""
    isInBlock = false
    guard !text.isEmpty else { return }
    textBlocks.append(TextBlockDescriptor(
        kind: .paragraph,
        text: text,
        imagePath: nil,
        htmlContent: html.isEmpty ? nil : html
    ))
}
```

Add a reset of `currentHTML` in `parse(_:)` just before `parser.parse()`:

```swift
func parse(_ data: Data) {
    let parser = XMLParser(data: data)
    parser.delegate = self
    currentHTML = ""
    currentText = ""
    parser.parse()
    flushBlock()
}
```

- [ ] **Step 3: Write htmlContent to EPubBlockRecord during import**

In `parseXHTML(...)` (the private method in `EPUBImportService`), update the block creation to include `htmlContent`. Find the loop over `parser.textBlocks` and update the `EPubBlockRecord` init to include `htmlContent`:

```swift
let block = EPubBlockRecord(
    id: "epub-\(audiobookID)-s\(spineIndex)-b\(blockIdx)",
    audiobookID: audiobookID,
    spineHref: spineHref,
    spineIndex: spineIndex,
    blockIndex: blockIdx,
    sequenceIndex: startingSequence,
    blockKind: textBlock.kind.rawValue,
    text: textBlock.text,
    htmlContent: textBlock.htmlContent,  // NEW
    imagePath: textBlock.imagePath,
    chapterIndex: chapterIndex,
    isHidden: false,
    hiddenReason: nil,
    cardColor: nil,  // NEW
    createdAt: ISO8601DateFormatter().string(from: Date()),
    modifiedAt: nil
)
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. Inner HTML is now preserved during import.

- [ ] **Step 5: Commit**

```bash
git add OrbitAudioBooks/Services/EPUBImportService.swift
git commit -m "feat: preserve inner HTML in EPubBlockRecord during XHTML parsing"
```

---

### Task 4: Create Initial Anchors After EPUB Import

**Files:**
- Modify: `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift`

- [ ] **Step 1: Add initial anchor creation after successful import**

In `EPUBAutoImportScanner.importEPUBFile(...)`, after the successful import and notification post, add a step to create initial system anchors and recalculate the timeline. Replace the success block (lines 107-124) with:

```swift
// Import extracted EPUB blocks.
do {
    let importer = EPUBImportService()
    let blocks = try await importer.import(
        audiobookID: audiobookID,
        epubURL: extractedDir,
        chapters: chapters,
        bookDuration: duration
    )
    logger.info("Auto-imported \(blocks.count) EPUB blocks for \(sanitizedPath(epubURL.lastPathComponent))")

    // Create initial system anchors (first block → 0, last block → duration)
    // so every block gets an interpolated timestamp from the start.
    if let firstBlock = blocks.first, let lastBlock = blocks.last, let bookDuration = duration {
        let alignmentService = AlignmentService(db: databaseService.writer, audiobookID: audiobookID)
        // Anchor first block to time 0
        let firstAnchor = AlignmentAnchorRecord(
            id: "anchor-init-first-\(audiobookID)",
            audiobookID: audiobookID,
            epubBlockID: firstBlock.id,
            audioTime: 0,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.imported.rawValue,
            note: "Auto-created: first block",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: nil
        )
        // Anchor last block to total duration
        let lastAnchor = AlignmentAnchorRecord(
            id: "anchor-init-last-\(audiobookID)",
            audiobookID: audiobookID,
            epubBlockID: lastBlock.id,
            audioTime: bookDuration,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.imported.rawValue,
            note: "Auto-created: last block",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: nil
        )
        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
        // Upsert in case of re-import
        try? anchorDAO.deleteAll(for: audiobookID)
        try? anchorDAO.upsert(firstAnchor)
        try? anchorDAO.upsert(lastAnchor)
        // Interpolate all blocks between the two anchors.
        try? alignmentService.recalculateTimeline()
        logger.info("Created initial alignment anchors for \(audiobookID)")
    }

    // Post notification to trigger UI refresh.
    await MainActor.run {
        NotificationCenter.default.post(
            name: .timelineItemsIngested,
            object: nil,
            userInfo: ["audiobookID": audiobookID]
        )
    }
} catch {
    logger.error("EPUB auto-import failed: \(error.localizedDescription)")
}
```

Note: The `try?` for anchor operations is intentional — anchor creation is best-effort. If it fails, the reader still works (blocks render without timestamps, alignment can be added manually).

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. On next EPUB import, initial anchors are created and timeline is interpolated.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Services/EPUBAutoImportScanner.swift
git commit -m "feat: create initial system anchors after EPUB import with linear interpolation"
```

---

### Task 5: Add EPubBlockDAO Query Methods

**Files:**
- Modify: `Shared/Database/DAOs/EPubBlockDAO.swift`

- [ ] **Step 1: Add blocksByChapter, blockID(at:), and setCardColor**

Add three new methods to `EPubBlockDAO`:

```swift
// MARK: - Chapter grouping

/// Blocks grouped by chapter index. Blocks without a chapter index go in bucket -1.
func blocksByChapter(for audiobookID: String) throws -> [Int: [EPubBlockRecord]] {
    let blocks = try self.blocks(for: audiobookID)
    var dict: [Int: [EPubBlockRecord]] = [:]
    for block in blocks {
        let key = block.chapterIndex ?? -1
        dict[key, default: []].append(block)
    }
    return dict
}

// MARK: - Audio position lookup

/// Find the EPUB block ID at a given audio time. Joins epub_block → timeline_item
/// on epub_block_id. Returns nil if no block covers this time.
func blockID(at time: TimeInterval, audiobookID: String) throws -> String? {
    try db.read { db in
        try Row.fetchOne(db, sql: """
            SELECT eb.id
            FROM epub_block eb
            JOIN timeline_item ti ON ti.epub_block_id = eb.id
            WHERE eb.audiobook_id = ?
              AND ti.audio_start_time <= ?
              AND ti.audio_end_time > ?
            ORDER BY eb.sequence_index
            LIMIT 1
            """, arguments: [audiobookID, time, time]
        )?["id"]
    }
}

// MARK: - Card color

/// Update a single block's card color. Pass nil to reset to default.
func setCardColor(_ color: String?, blockID: String) throws {
    try db.write { db in
        try db.execute(
            sql: """
                UPDATE epub_block
                SET card_color = :color, modified_at = :now
                WHERE id = :id
                """,
            arguments: [
                "color": color as Any,
                "now": ISO8601DateFormatter().string(from: Date()),
                "id": blockID
            ]
        )
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Shared/Database/DAOs/EPubBlockDAO.swift
git commit -m "feat: add blocksByChapter, blockID(at:), and setCardColor to EPubBlockDAO"
```

---

### Task 6: Add Reader Settings Keys

**Files:**
- Modify: `OrbitAudioBooks/Services/BookPreferencesService.swift`
- Modify: `OrbitAudioBooks/Services/SettingsManager.swift`

- [ ] **Step 1: Add reader setting keys to BookPreferencesService**

Add after the existing `volumeBoostKey` method:

```swift
// MARK: - Reader settings

static func readerFontSizeKey(for audiobookID: String) -> String {
    "book_readerFontSize_\(audiobookID)"
}

static func readerLineSpacingKey(for audiobookID: String) -> String {
    "book_readerLineSpacing_\(audiobookID)"
}

static func readerCardTintKey(for audiobookID: String) -> String {
    "book_readerCardTint_\(audiobookID)"
}
```

- [ ] **Step 2: Add reader defaults to SettingsManager**

In `SettingsManager.Defaults`, add:

```swift
static let readerFontSize: Double = 17.0
static let readerLineSpacing: Double = 1.4
static let readerCardTint: String = "#F5F0E8"
```

In `SettingsManager.Keys` (private enum), add:

```swift
static let readerFontSize = "readerFontSize"
static let readerLineSpacing = "readerLineSpacing"
static let readerCardTint = "readerCardTint"
```

Add computed properties in `SettingsManager`:

```swift
var readerFontSize: Double {
    get { defaults.double(forKey: Keys.readerFontSize).nonZero ?? Defaults.readerFontSize }
    set { defaults.set(newValue, forKey: Keys.readerFontSize) }
}

var readerLineSpacing: Double {
    get { defaults.double(forKey: Keys.readerLineSpacing).nonZero ?? Defaults.readerLineSpacing }
    set { defaults.set(newValue, forKey: Keys.readerLineSpacing) }
}

var readerCardTint: String {
    get { defaults.string(forKey: Keys.readerCardTint) ?? Defaults.readerCardTint }
    set { defaults.set(newValue, forKey: Keys.readerCardTint) }
}
```

Add the defaults in the `registerDefaults` call (find it in `init()` and add):

```swift
Keys.readerFontSize: Defaults.readerFontSize,
Keys.readerLineSpacing: Defaults.readerLineSpacing,
Keys.readerCardTint: Defaults.readerCardTint,
```

Helper extension at bottom of file:

```swift
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OrbitAudioBooks/Services/BookPreferencesService.swift OrbitAudioBooks/Services/SettingsManager.swift
git commit -m "feat: add reader font size, line spacing, and card tint settings"
```

---

### Task 7: Create ReaderSettings Observable

**Files:**
- Create: `Shared/ReaderSettings.swift`

- [ ] **Step 1: Create ReaderSettings.swift**

```swift
import Foundation
import Observation

#if os(iOS)
import UIKit
#endif

/// Observable settings object for the EPUB reader feed.
/// Per-book overrides take precedence over global defaults.
@Observable
final class ReaderSettings {
    var fontSize: Double
    var lineSpacing: Double
    var cardTintHex: String

    init(fontSize: Double, lineSpacing: Double, cardTintHex: String) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.cardTintHex = cardTintHex
    }

    #if os(iOS)
    var cardTintColor: UIColor {
        UIColor(hex: cardTintHex) ?? UIColor.systemBackground
    }
    #endif

    /// Resolve per-book overrides against global defaults.
    static func resolved(
        fontSizeOverride: Double?,
        lineSpacingOverride: Double?,
        cardTintOverride: String?,
        globalFontSize: Double,
        globalLineSpacing: Double,
        globalCardTint: String
    ) -> ReaderSettings {
        ReaderSettings(
            fontSize: fontSizeOverride ?? globalFontSize,
            lineSpacing: lineSpacingOverride ?? globalLineSpacing,
            cardTintHex: cardTintOverride ?? globalCardTint
        )
    }
}

#if os(iOS)
extension UIColor {
    /// Initialize from a hex string like "#FFF8E7" or "FFF8E7".
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
            a = 1.0
        case 8:
            r = CGFloat((int >> 24) & 0xFF) / 255
            g = CGFloat((int >> 16) & 0xFF) / 255
            b = CGFloat((int >> 8) & 0xFF) / 255
            a = CGFloat(int & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
#endif
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Shared/ReaderSettings.swift
git commit -m "feat: add ReaderSettings observable with hex color support"
```

---

### Task 8: Create TabSelection Enum and Update Navigation

**Files:**
- Create: `Shared/TabSelection.swift`
- Modify: `OrbitAudioBooks/ViewModels/PlayerModel.swift`
- Modify: `OrbitAudioBooks/Views/RootTabView.swift`

- [ ] **Step 1: Create TabSelection.swift**

```swift
import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case timeline
}
```

- [ ] **Step 2: Update PlayerModel**

In `PlayerModel.swift`, replace:
```swift
var showingTimeline: Bool = false
```
with:
```swift
var selectedTab: TabSelection = .nowPlaying
```

Check for any references to `showingTimeline` in `PlayerModel.swift` and update them. Run a search:

```bash
grep -n "showingTimeline" OrbitAudioBooks/ViewModels/PlayerModel.swift
```

Replace each occurrence with `selectedTab` logic:
- `model.showingTimeline` → `model.selectedTab == .timeline` (in views)
- `model.showingTimeline = true` → `model.selectedTab = .timeline`
- `model.showingTimeline = false` → `model.selectedTab = .nowPlaying`

- [ ] **Step 3: Update RootTabView**

In `RootTabView.swift`, replace `@State private var showingTimeline` with `@State private var selectedTab: TabSelection = .nowPlaying` (but actually this should just use `model.selectedTab` directly since it's `@Published` on `PlayerModel`).

Read `RootTabView.swift` fully, then:

1. Remove `@State private var showingTimeline` — not needed since `model.selectedTab` is the source of truth.
2. Replace the body's conditional logic. The current pattern uses `if model.showingTimeline { TimelineTab } else { NowPlayingTab }`. Replace with a switch:

```swift
var body: some View {
    @Bindable var model = model
    NavigationStack {
        ZStack(alignment: .bottom) {
            Group {
                switch model.selectedTab {
                case .nowPlaying:
                    NowPlayingTab()
                case .read:
                    if model.hasEPUB {
                        ReaderTab(folderURL: model.folderURL!)
                    } else {
                        ReaderEmptyState()
                    }
                case .timeline:
                    TimelineTab(
                        onReviewTap: { launchReview() },
                        onEditBookmark: { id in editingBookmarkID = id },
                        onCreateBookmark: { draft in newBookmarkDraft = draft }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.isPlayingVoiceMemo {
                VStack(spacing: 8) {
                    if model.selectedTab == .timeline && model.folderURL != nil && !model.tracks.isEmpty {
                        PlayerControlBar()
                    }
                    BottomToolbarView(
                        selectedTab: $model.selectedTab,
                        hasEPUB: model.hasEPUB,
                        onCreateBookmark: { draft in newBookmarkDraft = draft }
                    )
                }
            }
        }
        // ... rest of existing modifiers (overlay, toolbar, sheets) remain unchanged
    }
}
```

Update the overlay condition: change `!model.showingTimeline` to `model.selectedTab == .nowPlaying` for the `NowPlayingTopToolbar`.

Update toolbar visibility: change `model.showingTimeline` to `model.selectedTab != .nowPlaying`.

- [ ] **Step 4: Update BottomToolbarView to accept tab selection**

Read `BottomToolbarView.swift`. Add parameters for `selectedTab` and `hasEPUB`:

```swift
struct BottomToolbarView: View {
    @Binding var selectedTab: TabSelection
    let hasEPUB: Bool
    let onCreateBookmark: (BookmarkDraft) -> Void
    // ... existing state vars
```

Replace the existing tab toggle buttons (if any) with three tab buttons. The Read tab button is disabled when `!hasEPUB`:

```swift
HStack(spacing: 0) {
    ForEach(TabSelection.allCases, id: \.self) { tab in
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                Text(tab.label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
        }
        .disabled(tab == .read && !hasEPUB)
        .accessibilityLabel(Text(tab.label))
    }
}
```

Add extension on `TabSelection` for icon/label:

```swift
extension TabSelection {
    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        case .timeline: return "list.bullet.rectangle"
        }
    }
    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read"
        case .timeline: return "Timeline"
        }
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. App navigates between 3 tabs.

- [ ] **Step 6: Commit**

```bash
git add Shared/TabSelection.swift OrbitAudioBooks/ViewModels/PlayerModel.swift OrbitAudioBooks/Views/RootTabView.swift OrbitAudioBooks/Views/BottomToolbarView.swift
git commit -m "feat: add 3-tab navigation with Read tab (TabSelection enum)"
```

---

### Task 9: Create ReaderCardItem and ReaderFeedViewModel

**Files:**
- Create: `OrbitAudioBooks/Models/ReaderCardItem.swift`
- Create: `OrbitAudioBooks/ViewModels/ReaderFeedViewModel.swift`

- [ ] **Step 1: Create ReaderCardItem.swift**

```swift
import Foundation

/// Items displayed in the EPUB reader feed.
enum ReaderCardItem: Hashable {
    /// A divider between chapters showing the chapter title.
    case chapterHeader(title: String, chapterIndex: Int)
    /// An EPUB block (heading, paragraph, or image).
    case block(EPubBlockRecord)
    // Future: case flashcard(Flashcard, associatedBlockIDs: [String], placement: FlashcardPlacement)
}
```

- [ ] **Step 2: Create ReaderFeedViewModel.swift**

```swift
import Foundation
import Observation
import os.log

/// View model for the EPUB reader feed. Loads blocks, builds the card array,
/// tracks the active block for playback sync, and handles search.
@MainActor
@Observable
final class ReaderFeedViewModel {
    private let logger = Logger(subsystem: "com.echo.audiobooks", category: "ReaderFeed")

    let audiobookID: String
    private let blockDAO: EPubBlockDAO
    private let chapterDAO: ChapterDAO
    private let anchorDAO: AlignmentAnchorDAO

    /// All cards in the feed (blocks + chapter dividers).
    private(set) var cards: [ReaderCardItem] = []
    /// Index of each card by block ID for fast lookup.
    private var cardIndexByBlockID: [String: Int] = [:]

    /// ID of the currently active block (based on playback position).
    var activeBlockID: String?

    /// Current search query. nil = show all blocks.
    var searchQuery: String? {
        didSet { reload() }
    }

    /// Callbacks for alignment actions.
    var onAlignToNow: ((String) -> Void)?
    var onAlignToFiveSecondsAgo: ((String) -> Void)?
    var onAlignToChapter: ((String) -> Void)?

    init(audiobookID: String, db: DatabaseWriter) {
        self.audiobookID = audiobookID
        self.blockDAO = EPubBlockDAO(db: db)
        self.chapterDAO = ChapterDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
    }

    /// Load blocks from the database and build the card array.
    func reload() {
        do {
            let blocks: [EPubBlockRecord]
            if let query = searchQuery, !query.isEmpty {
                blocks = try blockDAO.searchBlocks(for: audiobookID, query: query)
                cards = blocks.map { .block($0) }
            } else {
                let grouped = try blockDAO.blocksByChapter(for: audiobookID)
                var items: [ReaderCardItem] = []
                // Sort chapter indices for ordered output; -1 (no chapter) goes first.
                let sortedKeys = grouped.keys.sorted()
                for key in sortedKeys {
                    guard let chapterBlocks = grouped[key], !chapterBlocks.isEmpty else { continue }
                    let title: String
                    if key >= 0 {
                        let chapters = try? chapterDAO.chapters(for: audiobookID)
                        title = chapters?[safe: key]?.title ?? "Chapter \(key + 1)"
                    } else {
                        title = "Front Matter"
                    }
                    items.append(.chapterHeader(title: title, chapterIndex: key))
                    items.append(contentsOf: chapterBlocks.map { .block($0) })
                }
                cards = items
            }

            // Rebuild block ID index.
            cardIndexByBlockID = [:]
            for (idx, card) in cards.enumerated() {
                if case .block(let block) = card {
                    cardIndexByBlockID[block.id] = idx
                }
            }
        } catch {
            logger.error("Failed to load reader blocks: \(error.localizedDescription)")
        }
    }

    /// Update the active block based on current playback position.
    func updateActiveBlock(time: TimeInterval) {
        do {
            activeBlockID = try blockDAO.blockID(at: time, audiobookID: audiobookID)
        } catch {
            // Best-effort; if query fails, just keep the previous active block.
        }
    }

    /// Index path for a given block ID, if present in the current cards.
    func indexForBlockID(_ blockID: String) -> Int? {
        cardIndexByBlockID[blockID]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OrbitAudioBooks/Models/ReaderCardItem.swift OrbitAudioBooks/ViewModels/ReaderFeedViewModel.swift
git commit -m "feat: add ReaderCardItem enum and ReaderFeedViewModel"
```

---

### Task 10: Create Card Cells (Heading, Paragraph, Image)

**Files:**
- Create: `OrbitAudioBooks/Views/Cells/HeadingCardCell.swift`
- Create: `OrbitAudioBooks/Views/Cells/ParagraphCardCell.swift`
- Create: `OrbitAudioBooks/Views/Cells/ImageCardCell.swift`

- [ ] **Step 1: Create HeadingCardCell.swift**

```swift
import UIKit

/// Card cell for EPUB heading blocks (h1-h6). Larger font, more prominent background.
final class HeadingCardCell: UICollectionViewCell {
    static let reuseIdentifier = "HeadingCardCell"

    private let label: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let activeBar: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    var isActiveBlock: Bool = false {
        didSet {
            activeBar.isHidden = !isActiveBlock
            contentView.alpha = isActiveBlock ? 1.0 : 0.95
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label)
        contentView.addSubview(activeBar)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        NSLayoutConstraint.activate([
            activeBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            activeBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            activeBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            activeBar.widthAnchor.constraint(equalToConstant: 3),

            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with text: String, font: UIFont, tint: UIColor) {
        label.text = text
        label.font = font
        contentView.backgroundColor = tint.withAlphaComponent(0.15)
        label.textColor = UITraitCollection.current.userInterfaceStyle == .dark ? .white : .label
    }
}
```

- [ ] **Step 2: Create ParagraphCardCell.swift**

```swift
import UIKit

/// Card cell for EPUB paragraph/sentence blocks. Renders HTML content via UITextView.
final class ParagraphCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ParagraphCardCell"

    private let textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let activeBar: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    var isActiveBlock: Bool = false {
        didSet {
            activeBar.isHidden = !isActiveBlock
            contentView.alpha = isActiveBlock ? 1.0 : 0.95
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(textView)
        contentView.addSubview(activeBar)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        NSLayoutConstraint.activate([
            activeBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            activeBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            activeBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            activeBar.widthAnchor.constraint(equalToConstant: 3),

            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, font: UIFont, tint: UIColor, lineSpacing: CGFloat) {
        let displayHTML = block.htmlContent ?? block.text ?? ""
        let data = Data(displayHTML.utf8)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) {
            // Apply font and line spacing to the entire attributed string.
            let range = NSRange(location: 0, length: attributed.length)
            attributed.addAttribute(.font, value: font, range: range)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            textView.attributedText = attributed
        } else {
            textView.text = block.text
            textView.font = font
        }

        contentView.backgroundColor = tint.withAlphaComponent(0.08)
    }
}
```

- [ ] **Step 3: Create ImageCardCell.swift**

```swift
import UIKit

/// Card cell for EPUB image blocks. Loads image from local asset storage.
final class ImageCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ImageCardCell"

    private let artworkView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let captionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(artworkView)
        contentView.addSubview(captionLabel)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            artworkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            artworkView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            artworkView.heightAnchor.constraint(lessThanOrEqualToConstant: 300),

            captionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            captionLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 8),
            captionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, tint: UIColor) {
        if let imagePath = block.imagePath, let image = UIImage(contentsOfFile: imagePath) {
            artworkView.image = image
        } else {
            artworkView.image = UIImage(systemName: "photo")
        }
        captionLabel.text = block.text
        contentView.backgroundColor = tint.withAlphaComponent(0.05)
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add OrbitAudioBooks/Views/Cells/
git commit -m "feat: add HeadingCardCell, ParagraphCardCell, and ImageCardCell"
```

---

### Task 11: Create ReaderFeedCollectionView

**Files:**
- Create: `OrbitAudioBooks/Views/ReaderFeedCollectionView.swift`

- [ ] **Step 1: Create ReaderFeedCollectionView.swift**

```swift
import SwiftUI
import UIKit

/// UIViewRepresentable wrapping a UICollectionView that renders the EPUB reader feed.
struct ReaderFeedCollectionView: UIViewRepresentable {
    @Binding var cards: [ReaderCardItem]
    @Binding var activeBlockID: String?
    let settings: ReaderSettings
    var onTapBlock: ((String) -> Void)?
    var onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            cards: $cards,
            activeBlockID: $activeBlockID,
            settings: settings,
            onTapBlock: onTapBlock,
            onContextMenu: onContextMenu
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(200)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: itemSize,
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 6
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            return section
        }

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = context.coordinator

        // Register cell types.
        collectionView.register(HeadingCardCell.self, forCellWithReuseIdentifier: HeadingCardCell.reuseIdentifier)
        collectionView.register(ParagraphCardCell.self, forCellWithReuseIdentifier: ParagraphCardCell.reuseIdentifier)
        collectionView.register(ImageCardCell.self, forCellWithReuseIdentifier: ImageCardCell.reuseIdentifier)
        collectionView.register(ChapterDividerCell.self, forCellWithReuseIdentifier: ChapterDividerCell.reuseIdentifier)

        context.coordinator.dataSource = makeDataSource(for: collectionView)
        context.coordinator.applySnapshot(cards: cards, animated: false)

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.onTapBlock = onTapBlock
        context.coordinator.onContextMenu = onContextMenu

        // Only reload if cards actually changed (avoid infinite loops).
        let oldCount = context.coordinator.currentCardCount
        let newCount = cards.count
        if oldCount != newCount || context.coordinator.needsReload {
            context.coordinator.applySnapshot(cards: cards, animated: oldCount > 0)
            context.coordinator.currentCardCount = newCount
            context.coordinator.needsReload = false
        }

        // Update active block highlight.
        context.coordinator.updateActiveBlock(activeBlockID, in: collectionView)
    }

    private func makeDataSource(for collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<String, ReaderCardItem> {
        return UICollectionViewDiffableDataSource<String, ReaderCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .chapterHeader(let title, _):
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChapterDividerCell.reuseIdentifier, for: indexPath
                ) as? ChapterDividerCell else { return UICollectionViewCell() }
                cell.configure(with: title)
                return cell

            case .block(let block):
                switch block.blockKind {
                case EPubBlockRecord.Kind.heading.rawValue:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: HeadingCardCell.reuseIdentifier, for: indexPath
                    ) as? HeadingCardCell else { return UICollectionViewCell() }
                    let font = UIFont(name: "Lexend-SemiBold", size: 20) ?? UIFont.preferredFont(forTextStyle: .title3)
                    cell.configure(with: block.text ?? "", font: font, tint: .systemBackground)
                    cell.isActiveBlock = (block.id == self.activeBlockID)
                    return cell

                case EPubBlockRecord.Kind.image.rawValue:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ImageCardCell.reuseIdentifier, for: indexPath
                    ) as? ImageCardCell else { return UICollectionViewCell() }
                    cell.configure(with: block, tint: .systemBackground)
                    return cell

                default:
                    guard let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ParagraphCardCell.reuseIdentifier, for: indexPath
                    ) as? ParagraphCardCell else { return UICollectionViewCell() }
                    let font = UIFont(name: "Lexend-Regular", size: 17) ?? UIFont.preferredFont(forTextStyle: .body)
                    cell.configure(with: block, font: font, tint: .systemBackground, lineSpacing: 4)
                    cell.isActiveBlock = (block.id == self.activeBlockID)
                    return cell
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UICollectionViewDelegate {
        @Binding var cards: [ReaderCardItem]
        @Binding var activeBlockID: String?
        var settings: ReaderSettings
        var onTapBlock: ((String) -> Void)?
        var onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?

        var dataSource: UICollectionViewDiffableDataSource<String, ReaderCardItem>?
        var currentCardCount = 0
        var needsReload = false
        private var isUserScrolling = false
        private var scrollTripwireTask: Task<Void, Never>?

        init(cards: Binding<[ReaderCardItem]>, activeBlockID: Binding<String?>,
             settings: ReaderSettings, onTapBlock: ((String) -> Void)?,
             onContextMenu: ((String, EPubBlockRecord.Kind?) -> UIContextMenuConfiguration?)?) {
            self._cards = cards
            self._activeBlockID = activeBlockID
            self.settings = settings
            self.onTapBlock = onTapBlock
            self.onContextMenu = onContextMenu
        }

        func applySnapshot(cards: [ReaderCardItem], animated: Bool) {
            var snapshot = NSDiffableDataSourceSnapshot<String, ReaderCardItem>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(cards, toSection: "main")
            dataSource?.apply(snapshot, animatingDifferences: animated)
        }

        func updateActiveBlock(_ blockID: String?, in collectionView: UICollectionView) {
            guard let blockID else { return }
            // Find index path for the active block item.
            guard let snapshot = dataSource?.snapshot() else { return }
            let activeItem = ReaderCardItem.block(
                EPubBlockRecord(
                    id: blockID, audiobookID: "", spineHref: "", spineIndex: 0,
                    blockIndex: 0, sequenceIndex: 0, blockKind: "", text: nil,
                    htmlContent: nil, cardColor: nil, imagePath: nil, chapterIndex: nil,
                    isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil
                )
            )
            // We can't directly look up by block ID in the snapshot, so we
            // iterate cards to find the matching index path.
            for (idx, card) in cards.enumerated() {
                if case .block(let b) = card, b.id == blockID {
                    let indexPath = IndexPath(item: idx, section: 0)
                    // Reload the cell to update highlight.
                    if let cell = collectionView.cellForItem(at: indexPath) {
                        if let headingCell = cell as? HeadingCardCell {
                            headingCell.isActiveBlock = true
                        } else if let paraCell = cell as? ParagraphCardCell {
                            paraCell.isActiveBlock = true
                        }
                    }
                    break
                }
            }
        }

        // MARK: - UICollectionViewDelegate

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            if case .block(let block) = item {
                onTapBlock?(block.id)
            }
        }

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            if case .block(let block) = item {
                let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
                return onContextMenu?(block.id, kind)
            }
            return nil
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            scrollTripwireTask?.cancel()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                startTripwire()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            startTripwire()
        }

        private func startTripwire() {
            scrollTripwireTask?.cancel()
            scrollTripwireTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.isUserScrolling = false
            }
        }
    }
}

// MARK: - Chapter Divider Cell

fileprivate final class ChapterDividerCell: UICollectionViewCell {
    static let reuseIdentifier = "ChapterDividerCell"

    private let label: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with title: String) {
        label.text = "— \(title) —"
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. Reader feed renders with card cells.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Views/ReaderFeedCollectionView.swift
git commit -m "feat: add ReaderFeedCollectionView with card cells and context menu support"
```

---

### Task 12: Create ReaderHeaderView with Search

**Files:**
- Create: `OrbitAudioBooks/Views/ReaderHeaderView.swift`

- [ ] **Step 1: Create ReaderHeaderView.swift**

```swift
import SwiftUI

struct ReaderHeaderView: View {
    @Binding var searchText: String
    let chapterTitle: String
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(chapterTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Button {
                    onSettingsTap()
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 16))
                }
                .accessibilityLabel(Text("Reader settings"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Find in book...", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Views/ReaderHeaderView.swift
git commit -m "feat: add ReaderHeaderView with search bar"
```

---

### Task 13: Create ReaderTab Root View

**Files:**
- Create: `OrbitAudioBooks/Views/ReaderTab.swift`

- [ ] **Step 1: Create ReaderTab.swift**

```swift
import SwiftUI

struct ReaderTab: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settingsManager

    @State private var viewModel: ReaderFeedViewModel?
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showChapterPicker: String? = nil  // blockID being aligned
    @State private var readerSettings: ReaderSettings = .init(
        fontSize: 17, lineSpacing: 1.4, cardTintHex: "#F5F0E8"
    )

    var body: some View {
        VStack(spacing: 0) {
            if let vm = viewModel {
                ReaderHeaderView(
                    searchText: $searchText,
                    chapterTitle: "EPUB Reader",  // Updated dynamically via activeBlockID
                    onSettingsTap: { showSettings = true }
                )

                ReaderFeedCollectionView(
                    cards: .constant(vm.cards),
                    activeBlockID: .constant(vm.activeBlockID),
                    settings: readerSettings,
                    onTapBlock: { blockID in
                        seekToBlock(blockID)
                    },
                    onContextMenu: { blockID, kind in
                        buildContextMenu(blockID: blockID, kind: kind)
                    }
                )
            } else {
                Spacer()
                ProgressView("Loading EPUB...")
                Spacer()
            }
        }
        .onAppear {
            loadViewModel()
        }
        .onChange(of: searchText) { _, newValue in
            viewModel?.searchQuery = newValue.isEmpty ? nil : newValue
        }
        .onChange(of: model.currentPosition) { _, newPos in
            viewModel?.updateActiveBlock(time: newPos)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(settings: $readerSettings)
        }
        .sheet(item: $showChapterPicker.map(
            get: { $0.map { IdentifiableString(id: $0) } },
            set: { showChapterPicker = $0?.id }
        )) { wrapper in
            ChapterPickerSheet(
                chapters: model.playbackState.chapters,
                onSelect: { chapter in
                    if let blockID = showChapterPicker {
                        alignBlock(blockID, to: chapter.startSeconds, source: .chapterBoundary)
                    }
                    showChapterPicker = nil
                }
            )
        }
    }

    private func loadViewModel() {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let vm = ReaderFeedViewModel(audiobookID: audiobookID, db: db.writer)
        vm.onAlignToNow = { blockID in
            alignBlock(blockID, to: model.currentPosition, source: .moveToNow)
        }
        vm.onAlignToFiveSecondsAgo = { blockID in
            alignBlock(blockID, to: max(0, model.currentPosition - 5.0), source: .moveToNow)
        }
        vm.onAlignToChapter = { blockID in
            showChapterPicker = blockID
        }
        vm.reload()
        self.viewModel = vm
    }

    private func seekToBlock(_ blockID: String) {
        guard let db = model.databaseService else { return }
        let timelineDAO = TimelineDAO(db: db.writer)
        // Find the timeline_item for this epub_block_id and seek to its audio_start_time.
        // The timeline_item table has epub_block_id — query via raw SQL since
        // TimelineDAO may not have a direct lookup by epub_block_id.
        do {
            let items = try db.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT audio_start_time FROM timeline_item
                    WHERE epub_block_id = ? AND audiobook_id = ?
                    LIMIT 1
                    """, arguments: [blockID, folderURL.absoluteString]
                )
            }
            if let row = items.first, let startTime: Double = row["audio_start_time"], startTime >= 0 {
                model.playbackController.seek(to: startTime)
            }
        } catch {
            // Seek is best-effort; if the block has no timeline item yet, nothing happens.
        }
    }

    private func alignBlock(_ blockID: String, to time: TimeInterval, source: AlignmentAnchorRecord.Source) {
        guard let db = model.databaseService else { return }
        let audiobookID = folderURL.absoluteString
        let alignmentService = AlignmentService(db: db.writer, audiobookID: audiobookID)
        do {
            try alignmentService.moveBlockToCurrentTime(blockID: blockID, time: time)
            // Reload the feed to reflect updated timestamps.
            viewModel?.reload()
        } catch {
            // Alignment failure is logged by AlignmentService.
        }
    }

    private func buildContextMenu(blockID: String, kind: EPubBlockRecord.Kind?) -> UIContextMenuConfiguration? {
        let isHeading = kind == .heading

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIAction] = []

            let changeColorAction = UIAction(
                title: "Change Color", image: UIImage(systemName: "paintpalette")
            ) { _ in
                // TODO: Present per-card color picker (Task 16)
            }
            actions.append(changeColorAction)

            let alignNowAction = UIAction(
                title: "Align to Now", image: UIImage(systemName: "location.fill")
            ) { _ in
                alignBlock(blockID, to: model.currentPosition, source: .moveToNow)
            }
            actions.append(alignNowAction)

            let alignFiveAction = UIAction(
                title: "Align to 5s Ago", image: UIImage(systemName: "gobackward.5")
            ) { _ in
                alignBlock(blockID, to: max(0, model.currentPosition - 5.0), source: .moveToNow)
            }
            actions.append(alignFiveAction)

            if isHeading {
                let alignChapterAction = UIAction(
                    title: "Align to Chapter", image: UIImage(systemName: "text.book.closed")
                ) { _ in
                    showChapterPicker = blockID
                }
                actions.append(alignChapterAction)
            }

            return UIMenu(title: "", children: actions)
        }
    }
}

// MARK: - Helper wrappers for sheet presentation

private struct IdentifiableString: Identifiable {
    let id: String
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Views/ReaderTab.swift
git commit -m "feat: add ReaderTab with seek, alignment, and context menu wiring"
```

---

### Task 14: Create ChapterPickerSheet

**Files:**
- Create: `OrbitAudioBooks/Views/ChapterPickerSheet.swift`

- [ ] **Step 1: Create ChapterPickerSheet.swift**

```swift
import SwiftUI
import AVFoundation

/// Sheet showing the audiobook's chapter list for "Align to Chapter."
struct ChapterPickerSheet: View {
    let chapters: [Chapter]
    let onSelect: (Chapter) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(chapters) { chapter in
                Button {
                    onSelect(chapter)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                                .font(.body)
                                .lineLimit(2)
                            Text(formatTime(chapter.startSeconds))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Pick Chapter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Views/ChapterPickerSheet.swift
git commit -m "feat: add ChapterPickerSheet for Align to Chapter action"
```

---

### Task 15: Create ReaderSettingsSheet

**Files:**
- Create: `OrbitAudioBooks/Views/ReaderSettingsSheet.swift`

- [ ] **Step 1: Create ReaderSettingsSheet.swift**

```swift
import SwiftUI

struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private let colorSwatches: [(String, String)] = [
        ("#F5F0E8", "Sepia"),
        ("#FFF8E7", "Cream"),
        ("#FFFFFF", "White"),
        ("#F0F0F0", "Light Gray"),
        ("#2C2C2C", "Dark"),
        ("#000000", "Black"),
        ("#E8F5E9", "Soft Green"),
        ("#E3F2FD", "Soft Blue"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                // Font Size
                Section("Font Size") {
                    Stepper("\(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 12...28, step: 1)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: settings.fontSize))
                        .lineLimit(2)
                }

                // Line Spacing
                Section("Line Spacing") {
                    VStack {
                        Slider(value: $settings.lineSpacing, in: 1.0...2.5, step: 0.1) {
                            Text("Line Spacing")
                        }
                        Text(String(format: "%.1f×", settings.lineSpacing))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Card Tint
                Section("Card Background") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(colorSwatches, id: \.0) { (hex, name) in
                            Button {
                                settings.cardTintHex = hex
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            settings.cardTintHex == hex
                                                ? Image(systemName: "checkmark")
                                                    .foregroundColor(hex == "#000000" || hex == "#2C2C2C" ? .white : .black)
                                                : nil
                                        )
                                        .overlay(
                                            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    Text(name)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Reset
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        settings.fontSize = SettingsManager.Defaults.readerFontSize
                        settings.lineSpacing = SettingsManager.Defaults.readerLineSpacing
                        settings.cardTintHex = SettingsManager.Defaults.readerCardTint
                    }
                }
            }
            .navigationTitle("Reader Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OrbitAudioBooks/Views/ReaderSettingsSheet.swift
git commit -m "feat: add ReaderSettingsSheet with font size, line spacing, and card tint controls"
```

---

### Task 16: Create ReaderEmptyState and Wire Up Per-Card Color

**Files:**
- Create: `OrbitAudioBooks/Views/ReaderEmptyState.swift`
- Modify: `OrbitAudioBooks/Views/ReaderTab.swift` (wire per-card color)
- Modify: `OrbitAudioBooks/Views/ReaderFeedCollectionView.swift` (apply per-card colors)

- [ ] **Step 1: Create ReaderEmptyState.swift**

```swift
import SwiftUI

struct ReaderEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No EPUB Available",
            systemImage: "book.pages",
            description: Text("Import an EPUB file alongside your audiobook to enable reading.")
        )
    }
}
```

- [ ] **Step 2: Update ReaderFeedCollectionView to apply per-card colors**

In `ReaderFeedCollectionView.swift`, update the `makeDataSource` method to check for per-card `cardColor` and fall back to the global `settings.cardTintColor`. In the block rendering closures, replace `.systemBackground` tint references with the resolved color:

```swift
let cardTint: UIColor = {
    if let hex = block.cardColor, let color = UIColor(hex: hex) {
        return color
    }
    return settings.cardTintColor
}()
```

Apply this in the Heading, Paragraph, and Image card `configure` calls.

- [ ] **Step 3: Wire per-card color change action in ReaderTab**

In `ReaderTab.buildContextMenu`, replace the `// TODO` comment in the Change Color action with a sheet presentation for the color picker. This can be done by reusing the color swatches from `ReaderSettingsSheet` in a compact overlay, or presenting a `.sheet` with the swatch grid scoped to the single card:

```swift
@State private var showCardColorPicker: String? = nil  // blockID

// In the Change Color UIAction:
showCardColorPicker = blockID

// Add sheet:
.sheet(item: $showCardColorPicker...) { blockID in
    CardColorPicker(blockID: blockID, onSelect: { color in
        try? EPubBlockDAO(db: db.writer).setCardColor(color, blockID: blockID)
        viewModel?.reload()
    })
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project OrbitAudioBooks.xcodeproj -scheme OrbitAudioBooks -destination 'platform=iOS Simulator,name=iPhone 16' build`

Expected: Build succeeds. Reader is feature-complete.

- [ ] **Step 5: Commit**

```bash
git add OrbitAudioBooks/Views/ReaderEmptyState.swift OrbitAudioBooks/Views/ReaderTab.swift OrbitAudioBooks/Views/ReaderFeedCollectionView.swift
git commit -m "feat: add ReaderEmptyState and per-card color override support"
```

---

### Task 17: End-to-End Integration and Polish

**Files:**
- Modify: `OrbitAudioBooks/Views/ReaderTab.swift` (reading position sync polish)
- Modify: `OrbitAudioBooks/Views/ReaderFeedCollectionView.swift` (follow-state tripwire polish)

- [ ] **Step 1: Verify reading position sync works end-to-end**

Manually test in simulator:
1. Load an audiobook with an EPUB.
2. Switch to the Read tab — verify cards render.
3. Play audio — verify the active block highlight advances.
4. Tap a card — verify audio seeks to that block.
5. Long-press a card — verify context menu appears with correct options.
6. "Align to Now" — verify anchor is created (check database).
7. "Align to Chapter" — verify chapter picker appears.
8. Search for text — verify filtered cards appear.
9. Adjust font size in settings — verify cards update.
10. Change card tint — verify background colors update.

- [ ] **Step 2: Fix any issues found during manual testing**

Iterate on `ReaderFeedCollectionView` if the active-block scrolling or follow-state tripwire doesn't behave as expected. The existing `TimelineFeedCollectionView` in the codebase already has a robust follow-state implementation — reference its `CADisplayLink` and scroll-tracking logic if the simpler approach needs hardening.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete EPUB Reader Feed implementation (Phase 5.1)

- 3-tab navigation with Read tab
- Card-based EPUB feed with heading, paragraph, and image cells
- Inner HTML preservation during import
- Initial system anchors with linear interpolation
- Long-press context menu: Align to Now, Align to 5s Ago, Align to Chapter
- Search within book
- Reader settings: font size, line spacing, card tint
- Per-card color overrides
- Reading position sync with active block highlight"
```

---

## Verification Checklist

After all tasks are complete, verify:

- [ ] App launches with 3-tab navigation (Listen, Read, Timeline)
- [ ] Read tab shows empty state when no EPUB loaded
- [ ] Read tab shows card feed when EPUB is loaded
- [ ] Card feed scrolls smoothly with 1000+ cards
- [ ] Heading, paragraph, and image cards render correctly
- [ ] HTML formatting (bold, italic) preserved in paragraph cards
- [ ] Tapping a card seeks audio to that block's timestamp
- [ ] Active block highlight advances with playback
- [ ] Auto-scroll follows the active block (disengages on manual scroll)
- [ ] Long-press shows context menu with correct options per block kind
- [ ] "Align to Now" creates anchor and recalculates timeline
- [ ] "Align to 5s Ago" creates anchor at currentPosition - 5
- [ ] "Align to Chapter" presents chapter picker, creates anchor on selection
- [ ] Search filters cards, clear restores full feed
- [ ] Reader settings sheet opens and controls work
- [ ] Card tint changes reflect immediately
- [ ] Per-card color override works (if implemented)
- [ ] Offline reading works (scroll cards without audio playing)
- [ ] V6 migration runs on existing databases without data loss
