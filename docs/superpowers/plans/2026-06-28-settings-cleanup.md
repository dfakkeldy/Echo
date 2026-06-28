# Settings Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved settings cleanup so Echo settings are grouped by user intent, use consistent native settings controls, and ship the corrected watch defaults.

**Architecture:** Keep `SettingsManager` as the single persistence source and keep `SettingsView` a thin shell that routes into focused settings screens. Convert ordinary preferences to native `Form`/`Section` rows, while preserving custom phone/watch preview canvases only inside the designer sections. Use source-scanning tests for structural UI guardrails and normal Swift Testing tests for defaults/persistence behavior.

**Tech Stack:** SwiftUI, Swift Testing, `@MainActor @Observable SettingsManager`, app-group `UserDefaults`, existing Echo make targets.

## Global Constraints

- Xcode detected in this worktree: Xcode 26.6.
- Project file currently reports `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, `WATCHOS_DEPLOYMENT_TARGET = 11.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, and `SWIFT_VERSION = 5.0`.
- Preserve the current platform support unless a separate migration explicitly changes it.
- Use SwiftUI and the existing `@MainActor @Observable SettingsManager` pattern.
- Do not introduce third-party frameworks.
- Echo feature/docs PRs should target `nightly`.
- Do not migrate or overwrite existing users' saved watch face/progress choices.
- Do not redesign the playback UI, watch runtime UI, bottom chrome, or player layouts beyond the settings surfaces needed for this cleanup.
- Keep custom phone/watch preview canvases where the user is directly designing controls.

---

## File Structure

- Modify `EchoCore/Services/SettingsManager.swift`
  - Owns default values and app-group registration for watch progress/face defaults.

- Create `EchoCore/Views/SettingsNowPlayingView.swift`
  - Durable playback defaults and behavior: default speed, skip durations, Smart Rewind, play bookmarks inline.

- Create `EchoCore/Views/ReaderDefaultsSettingsView.swift`
  - Global reader defaults exposed from Appearance.

- Modify `EchoCore/Views/SettingsView.swift`
  - Root IA only: Now Playing, Appearance, Controls, Library & Accounts, Study & Notes, Advanced & Privacy, Support & About.

- Modify `EchoCore/Views/SettingsAppearanceView.swift`
  - Link to reader defaults.

- Modify `EchoCore/Views/WatchAppSettingsView.swift`
  - Convert ordinary watch settings to `Form` sections and replace progress menu pickers with segmented pickers.

- Modify `EchoCore/Views/PhonePlayerSettingsView.swift`
  - Convert ordinary phone controls to `Form` sections while preserving the designer preview canvas and action palette.

- Modify `EchoCore/Views/PlaybackOptionsSheet.swift`
  - Keep as quick session sheet; rename toolbar action to "More Controls" so it matches the new IA.

- Modify `EchoCore/Views/HelpContent.swift`
  - Update user-visible settings paths.

- Modify `ARCHITECTURE.md`, `docs/guides/user-manual.md`, and `docs/manual.html`
  - Update settings paths and the settings restructure summary.

- Modify `EchoTests/EchoCoreTests.swift`
  - Behavioral defaults and persistence tests.

- Modify `EchoTests/SettingsExtractionTests.swift`
  - Root IA and new subview structural guardrails.

- Modify `EchoTests/WatchAppDesignerAccessibilityTests.swift`
  - Watch progress segmented controls and `Form` structure guardrails.

- Modify `EchoTests/PhonePlayerPaletteTests.swift`
  - Phone settings `Form` structure and consistent designer terminology guardrails.

- Modify `EchoTests/PlaybackOptionsSheetTests.swift`
  - "More Controls" routing label guardrail.

---

### Task 1: Watch Defaults And Persistence Guardrails

**Files:**
- Modify: `EchoTests/EchoCoreTests.swift:184-235`
- Modify: `EchoCore/Services/SettingsManager.swift:36-40`

**Interfaces:**
- Consumes: `SettingsManager(defaults:appGroupDefaults:)`, `SettingsManager.registerDefaults(defaults:appGroupDefaults:)`.
- Produces: new default contract:
  - `SettingsManager.Defaults.linearBarMode == "chapter"`
  - `SettingsManager.Defaults.circularRingMode == "total"`
  - `SettingsManager.Defaults.watchArtworkLayout == "classic"`

- [ ] **Step 1: Add failing defaults tests**

Add these tests after `settingsPersistsWatchBackgroundStyle()` in `EchoTests/EchoCoreTests.swift`:

```swift
    @Test func settingsUsesClassicWatchFaceAndProgressDefaults() {
        let suiteName = "watch-progress-defaults-\(UUID().uuidString)"
        let appGroupName = "watch-progress-defaults-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: appGroupDefaults)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(SettingsManager.Defaults.watchArtworkLayout == "classic")
        #expect(SettingsManager.Defaults.linearBarMode == "chapter")
        #expect(SettingsManager.Defaults.circularRingMode == "total")
        #expect(appGroupDefaults.string(forKey: "watchArtworkLayout") == "classic")
        #expect(appGroupDefaults.string(forKey: "linearBarMode") == "chapter")
        #expect(appGroupDefaults.string(forKey: "circularRingMode") == "total")
        #expect(settings.watchArtworkLayout == "classic")
        #expect(settings.linearBarMode == "chapter")
        #expect(settings.circularRingMode == "total")
    }

    @Test func settingsPreservesPersistedWatchFaceAndProgressChoices() {
        let suiteName = "watch-progress-persisted-\(UUID().uuidString)"
        let appGroupName = "watch-progress-persisted-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        appGroupDefaults.set("immersive", forKey: "watchArtworkLayout")
        appGroupDefaults.set("total", forKey: "linearBarMode")
        appGroupDefaults.set("chapter", forKey: "circularRingMode")

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)

        #expect(settings.watchArtworkLayout == "immersive")
        #expect(settings.linearBarMode == "total")
        #expect(settings.circularRingMode == "chapter")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/EchoCoreTests
```

Expected: `settingsUsesClassicWatchFaceAndProgressDefaults` fails because defaults still report `watchArtworkLayout == "immersive"`, `linearBarMode == "total"`, and `circularRingMode == "chapter"`.

- [ ] **Step 3: Change the defaults**

In `EchoCore/Services/SettingsManager.swift`, change the defaults block from:

```swift
        static let linearBarMode = "total"
        static let linearBarHidden = false
        static let circularRingMode = "chapter"
        static let circularRingHidden = false
        static let watchArtworkLayout = "immersive"
```

to:

```swift
        static let linearBarMode = "chapter"
        static let linearBarHidden = false
        static let circularRingMode = "total"
        static let circularRingHidden = false
        static let watchArtworkLayout = "classic"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
make test-only FILTER=EchoTests/EchoCoreTests
```

Expected: all `EchoCoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/SettingsManager.swift EchoTests/EchoCoreTests.swift
git commit -m "test: pin watch settings defaults"
```

---

### Task 2: Durable Now Playing Settings Screen

**Files:**
- Create: `EchoCore/Views/SettingsNowPlayingView.swift`
- Modify: `EchoTests/SettingsExtractionTests.swift:11-101`

**Interfaces:**
- Consumes: `SettingsManager.defaultPlaybackSpeed`, `SettingsManager.seekBackwardDuration`, `SettingsManager.seekForwardDuration`, `SettingsManager.playBookmarksInline`, `PlaybackOptionsSheet.seekDurationOptions`, `SmartRewindSettingsView`.
- Produces: `SettingsNowPlayingView`, a native `Form` screen for durable playback defaults.

- [ ] **Step 1: Add failing extraction tests**

Add this test after `proTranscriptsSubViewIsExtracted()` in `EchoTests/SettingsExtractionTests.swift`:

```swift
    @Test func nowPlayingSubViewIsExtracted() throws {
        let source = try Self.source(named: "SettingsNowPlayingView.swift")
        #expect(source.contains("struct SettingsNowPlayingView"))
        #expect(source.contains("Default Speed"))
        #expect(source.contains("PlaybackOptionsSheet.seekDurationOptions"))
        #expect(source.contains("SmartRewindSettingsView()"))
        #expect(source.contains("playBookmarksInline"))
    }
```

Also update `source(named:)` so it can find the new file once created. No code change is needed if it already walks `EchoCore/Views`; the failing test is enough.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: `nowPlayingSubViewIsExtracted` fails with `CocoaError(.fileNoSuchFile)` because `SettingsNowPlayingView.swift` does not exist yet.

- [ ] **Step 3: Create the Now Playing settings screen**

Create `EchoCore/Views/SettingsNowPlayingView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsNowPlayingView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Default Speed", selection: defaultSpeedSelection) {
                    ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { speed in
                        Text(speedLabel(Double(speed))).tag(Double(speed))
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Playback Defaults")
            } footer: {
                Text("Used for new books. Existing books keep the last speed you selected for that book.")
            }

            Section("Skip Durations") {
                Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                    ForEach(PlaybackOptionsSheet.seekDurationOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }
                .onChange(of: settings.seekBackwardDuration) { _, _ in
                    model.syncToWatch()
                }

                Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                    ForEach(PlaybackOptionsSheet.seekDurationOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }
                .onChange(of: settings.seekForwardDuration) { _, _ in
                    model.syncToWatch()
                }
            }

            Section {
                NavigationLink("Smart Rewind") {
                    SmartRewindSettingsView()
                }
            } footer: {
                Text("Automatically rewinds after pauses so you can regain context.")
            }

            Section {
                Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
            } footer: {
                Text("When enabled, voice memos attached to bookmarks play automatically when the audiobook reaches that timestamp.")
            }
        }
        .navigationTitle("Now Playing")
    }

    private var defaultSpeedSelection: Binding<Double> {
        Binding(
            get: { settings.defaultPlaybackSpeed },
            set: { settings.defaultPlaybackSpeed = $0 }
        )
    }

    private func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: `SettingsExtractionTests` pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/SettingsNowPlayingView.swift EchoTests/SettingsExtractionTests.swift
git commit -m "feat: add now playing settings screen"
```

---

### Task 3: Root Settings IA

**Files:**
- Modify: `EchoCore/Views/SettingsView.swift:33-140`
- Modify: `EchoTests/SettingsExtractionTests.swift:75-101`

**Interfaces:**
- Consumes: `SettingsNowPlayingView`, `SettingsAppearanceView`, `PhonePlayerSettingsView`, `WatchAppSettingsView`, `ABSConnectionsSettingsView`, `ProTranscriptsSettingsView`, `SettingsAdvancedView`, `FeedbackSupportView`, `AllStudyNotesExportView`.
- Produces: root settings sections: `Now Playing`, `Appearance`, `Controls`, `Library & Accounts`, `Study & Notes`, `Advanced & Privacy`, `Support & About`.

- [ ] **Step 1: Update the structural test first**

Replace `settingsShellExposesSubscreenLinksOnly()` in `EchoTests/SettingsExtractionTests.swift` with:

```swift
    @Test func settingsShellUsesApprovedInformationArchitecture() throws {
        let source = try Self.source(named: "SettingsView.swift")

        #expect(source.contains("Section(\"Now Playing\")"))
        #expect(source.contains("SettingsNowPlayingView()"))
        #expect(source.contains("Section(\"Appearance\")"))
        #expect(source.contains("SettingsAppearanceView()"))
        #expect(source.contains("Section(\"Controls\")"))
        #expect(source.contains("PhonePlayerSettingsView()"))
        #expect(source.contains("WatchAppSettingsView()"))
        #expect(source.contains("Section(\"Library & Accounts\")"))
        #expect(source.contains("ABSConnectionsSettingsView()"))
        #expect(source.contains("ProTranscriptsSettingsView()"))
        #expect(source.contains("Section(\"Study & Notes\")"))
        #expect(source.contains("SettingsStudyRows()"))
        #expect(source.contains("AllStudyNotesExportView"))
        #expect(source.contains("Section(\"Advanced & Privacy\")"))
        #expect(source.contains("PronunciationDictionaryView(store: .shared)"))
        #expect(source.contains("SettingsAdvancedView()"))
        #expect(source.contains("SettingsSupportAboutSection("))

        #expect(!source.contains("Section(\"Display\")"))
        #expect(!source.contains("Section(\"Store\")"))
        #expect(!source.contains("Section(\"Library Sources\")"))
        #expect(!source.contains("Section(\"Customization\")"))
        #expect(!source.contains("Section(\"Flashcards\")"))
        #expect(!source.contains("Section(\"Data\")"))
        #expect(!source.contains("Section(\"Support\")"))
        #expect(!source.contains("Toggle(\"Volume Boost\""))
    }
```

Update `settingsShellExposesStudyGlobalChapterCap()` to keep only the study assertions that remain true:

```swift
    @Test func settingsShellExposesStudyGlobalChapterCap() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(source.contains("SettingsStudyRows()"))
        #expect(source.contains("$settings.studyGlobalNewChapterLimit"))
        #expect(source.contains("Global New Chapters"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: `settingsShellUsesApprovedInformationArchitecture` fails because `SettingsView` still has the old section names.

- [ ] **Step 3: Replace the root sections**

In `EchoCore/Views/SettingsView.swift`, replace the `Form` contents from the first section after `BookOverridesSections` through `BuildMetadataSection(buildMetadata:)` with:

```swift
                Section("Now Playing") {
                    NavigationLink("Playback Defaults") {
                        SettingsNowPlayingView()
                    }
                }

                Section("Appearance") {
                    NavigationLink("Appearance") {
                        SettingsAppearanceView()
                    }
                }

                Section("Controls") {
                    NavigationLink("Phone Player Settings") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                }

                Section("Library & Accounts") {
                    NavigationLink("Connections") {
                        ABSConnectionsSettingsView()
                    }
                    NavigationLink("Echo Pro") {
                        ProTranscriptsSettingsView()
                    }
                }

                Section("Study & Notes") {
                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }

                    SettingsStudyRows()

                    Button {
                        showingAllStudyNotesExport = true
                    } label: {
                        Label("Export All Study Notes", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.databaseService == nil)
                }

                Section("Advanced & Privacy") {
                    NavigationLink("Pronunciation") {
                        PronunciationDictionaryView(store: .shared)
                    }
                    NavigationLink("Advanced") {
                        SettingsAdvancedView()
                    }
                }

                #if DEBUG
                    SettingsSilenceDetectionSection()
                #endif

                SettingsSupportAboutSection(
                    buildMetadata: buildMetadata,
                    showingFeedback: $showingFeedback
                )
```

Then replace `private struct BuildMetadataSection` with this renamed combined support/about section:

```swift
private struct SettingsSupportAboutSection: View {
    let buildMetadata: AppBuildMetadata
    @Binding var showingFeedback: Bool
    @State private var copiedCommit = false

    var body: some View {
        Section {
            NavigationLink("Feedback & Support") {
                FeedbackSupportView()
                    .navigationTitle("Feedback & Support")
            }
            NavigationLink {
                HelpView()
                    .navigationTitle("Help")
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            Button {
                showingFeedback = true
            } label: {
                Label("Send Feedback", systemImage: "bubble.left.and.text.bubble.right")
            }
            Link(destination: FeedbackSupport.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }

            LabeledContent("Version", value: buildMetadata.versionString)
            LabeledContent {
                HStack {
                    Text(buildMetadata.commitString)
                        .textSelection(.enabled)
                    Button("Copy", systemImage: copiedCommit ? "checkmark" : "doc.on.doc") {
                        copyCommitHash()
                    }
                    .disabled(buildMetadata.gitCommitHash == nil)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy commit hash")
                }
            } label: {
                Text("Commit")
            }
        } header: {
            Text("Support & About")
        } footer: {
            Text("Use these details when comparing installs or reporting a bug. The commit hash is stamped into the app at build time.")
        }
    }

    private func copyCommitHash() {
        guard let gitCommitHash = buildMetadata.gitCommitHash else { return }

        #if canImport(UIKit)
            UIPasteboard.general.string = gitCommitHash
            copiedCommit = true
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(gitCommitHash, forType: .string)
            copiedCommit = true
        #endif
    }
}
```

- [ ] **Step 4: Replace the study section helper with a row helper**

Because `Section("Study & Notes")` now owns the grouping, replace `SettingsStudySection` with this row-only helper:

```swift
private struct SettingsStudyRows: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Stepper(value: $settings.studyGlobalNewChapterLimit, in: 1...12) {
            LabeledContent("Global New Chapters") {
                Text(limitText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var limitText: String {
        let limit = settings.studyGlobalNewChapterLimit
        let unit = limit == 1 ? "chapter" : "chapters"
        return "\(limit) \(unit) per day"
    }
}
```

Call `SettingsStudyRows()` inside `Section("Study & Notes")`; the tests from Step 1 already assert this.

- [ ] **Step 5: Run the tests**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: all `SettingsExtractionTests` pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/SettingsView.swift EchoTests/SettingsExtractionTests.swift
git commit -m "feat: reorganize settings information architecture"
```

---

### Task 4: Reader Defaults In Appearance

**Files:**
- Create: `EchoCore/Views/ReaderDefaultsSettingsView.swift`
- Modify: `EchoCore/Views/SettingsAppearanceView.swift:53-67`
- Modify: `EchoTests/SettingsExtractionTests.swift:11-47`

**Interfaces:**
- Consumes: `SettingsManager.readerFontSize`, `SettingsManager.readerLineSpacing`, `SettingsManager.readerCardTint`.
- Produces: `ReaderDefaultsSettingsView` and an Appearance row named `Reader Defaults`.

- [ ] **Step 1: Add failing extraction tests**

Add after `themeSelectionSubViewIsExtracted()`:

```swift
    @Test func readerDefaultsSubViewIsExtracted() throws {
        let source = try Self.source(named: "ReaderDefaultsSettingsView.swift")
        #expect(source.contains("struct ReaderDefaultsSettingsView"))
        #expect(source.contains("readerFontSize"))
        #expect(source.contains("readerLineSpacing"))
        #expect(source.contains("readerCardTint"))
    }
```

Add to `settingsViewNoLongerDeclaresExtractedSubViews()`:

```swift
        #expect(!source.contains("private struct ReaderDefaultsSettingsView"))
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: `readerDefaultsSubViewIsExtracted` fails because the file does not exist yet.

- [ ] **Step 3: Create the reader defaults screen**

Create `EchoCore/Views/ReaderDefaultsSettingsView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ReaderDefaultsSettingsView: View {
    @Environment(SettingsManager.self) private var settings

    private let colorSwatches: [ReaderDefaultsColorSwatch] = [
        ReaderDefaultsColorSwatch(hex: "#F5F0E8", name: "Sepia"),
        ReaderDefaultsColorSwatch(hex: "#FFF8E7", name: "Cream"),
        ReaderDefaultsColorSwatch(hex: "#FFFFFF", name: "White"),
        ReaderDefaultsColorSwatch(hex: "#F0F0F0", name: "Light Gray"),
        ReaderDefaultsColorSwatch(hex: "#2C2C2C", name: "Dark"),
        ReaderDefaultsColorSwatch(hex: "#000000", name: "Black"),
        ReaderDefaultsColorSwatch(hex: "#E8F5E9", name: "Soft Green"),
        ReaderDefaultsColorSwatch(hex: "#E3F2FD", name: "Soft Blue"),
    ]

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Font Size") {
                Stepper(
                    "\(Int(settings.readerFontSize)) pt",
                    value: $settings.readerFontSize,
                    in: 12...28,
                    step: 1
                )
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: settings.readerFontSize))
                    .lineLimit(2)
            }

            Section("Line Spacing") {
                VStack(alignment: .leading) {
                    Slider(value: $settings.readerLineSpacing, in: 1.0...2.5, step: 0.1)
                    Text(lineSpacingMultiplierText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Card Background") {
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                    ForEach(colorSwatches) { swatch in
                        Button {
                            settings.readerCardTint = swatch.hex
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: swatch.hex))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if settings.readerCardTint == swatch.hex {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(swatch.usesLightCheckmark ? .white : .black)
                                        }
                                    }
                                    .overlay {
                                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
                                    }
                                Text(swatch.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.readerFontSize = SettingsManager.Defaults.readerFontSize
                    settings.readerLineSpacing = SettingsManager.Defaults.readerLineSpacing
                    settings.readerCardTint = SettingsManager.Defaults.readerCardTint
                }
            }
        }
        .navigationTitle("Reader Defaults")
    }

    private var lineSpacingMultiplierText: String {
        settings.readerLineSpacing.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

private struct ReaderDefaultsColorSwatch: Identifiable {
    let hex: String
    let name: LocalizedStringResource

    var id: String { hex }

    var usesLightCheckmark: Bool {
        hex == "#000000" || hex == "#2C2C2C"
    }
}
```

- [ ] **Step 4: Link it from Appearance**

In `EchoCore/Views/SettingsAppearanceView.swift`, add a `NavigationLink` inside `Section("Typography")` after the font row:

```swift
                NavigationLink {
                    ReaderDefaultsSettingsView()
                } label: {
                    HStack {
                        Text("Reader Defaults")
                        Spacer()
                        Text("\(Int(settings.readerFontSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 5: Run tests**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: all `SettingsExtractionTests` pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/ReaderDefaultsSettingsView.swift EchoCore/Views/SettingsAppearanceView.swift EchoTests/SettingsExtractionTests.swift
git commit -m "feat: expose reader defaults in appearance settings"
```

---

### Task 5: Watch App Settings Form And Progress Controls

**Files:**
- Modify: `EchoCore/Views/WatchAppSettingsView.swift:30-438`
- Modify: `EchoTests/WatchAppDesignerAccessibilityTests.swift:6-46`

**Interfaces:**
- Consumes: existing watch page slot state, `settings.watchArtworkLayout`, `settings.linearBarMode`, `settings.circularRingMode`, visibility toggles, `model.syncToWatch()`.
- Produces: `WatchAppSettingsView` as a `Form`; progress segmented controls with `Book`/`Chapter` labels.

- [ ] **Step 1: Add failing watch structure tests**

Append this test to `WatchAppDesignerAccessibilityTests`:

```swift
    @Test func watchSettingsUsesFormSectionsAndSegmentedProgressControls() throws {
        let source = try Self.source(named: "WatchAppSettingsView.swift")
        #expect(source.contains("Form {"))
        #expect(source.contains("Section(\"Face\")"))
        #expect(source.contains("Section(\"Progress\")"))
        #expect(source.contains("Section(\"Controls\")"))
        #expect(source.contains("Section(\"Layout Designer\")"))
        #expect(source.contains("Section(\"Available Actions\")"))
        #expect(source.contains("Section(\"Presets\")"))
        #expect(!source.contains("ScrollView {"))

        let progressSlice = try Self.slice(
            of: source,
            after: "Section(\"Progress\")",
            until: "Section(\"Controls\")"
        )
        #expect(progressSlice.contains("Picker(\"Circular Ring\""))
        #expect(progressSlice.contains("Text(\"Book\").tag(\"total\")"))
        #expect(progressSlice.contains("Text(\"Chapter\").tag(\"chapter\")"))
        #expect(progressSlice.contains("Picker(\"Linear Bar\""))
        #expect(progressSlice.contains(".pickerStyle(.segmented)"))
        #expect(!progressSlice.contains(".pickerStyle(.menu)"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/WatchAppDesignerAccessibilityTests
```

Expected: `watchSettingsUsesFormSectionsAndSegmentedProgressControls` fails because the view still uses a top-level `ScrollView` and progress menu pickers.

- [ ] **Step 3: Replace the top-level `ScrollView` with `Form` sections**

In `EchoCore/Views/WatchAppSettingsView.swift`, replace the current top-level `ScrollView` body in `var body` with this structure. Keep the helper types below line 441 unchanged.

```swift
        Form {
            Section("Face") {
                Picker("Face Style", selection: $settings.watchArtworkLayout) {
                    Label("Classic", systemImage: "photo").tag("classic")
                    Label("Full Face", systemImage: "rectangle.expand.vertical").tag("immersive")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.watchArtworkLayout) { _, _ in
                    model.syncToWatch()
                }

                Picker("Classic Background", selection: $settings.watchBackgroundStyle) {
                    Text("Blurred").tag("artwork")
                    Text("Black").tag("black")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.watchBackgroundStyle) { _, _ in
                    model.syncToWatch()
                }

                Toggle("Scroll Title", isOn: $settings.watchTitleScrollEnabled)
                    .onChange(of: settings.watchTitleScrollEnabled) { _, _ in
                        model.syncToWatch()
                    }

                if settings.watchTitleScrollEnabled {
                    Picker("Scroll Speed", selection: $settings.watchTitleScrollSpeed) {
                        Text("Slow").tag(15.0)
                        Text("Normal").tag(30.0)
                        Text("Fast").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.watchTitleScrollSpeed) { _, _ in
                        model.syncToWatch()
                    }
                }

                Toggle("Show Date", isOn: $settings.watchDateEnabled)
                    .onChange(of: settings.watchDateEnabled) { _, _ in
                        model.syncToWatch()
                    }

                if settings.watchDateEnabled {
                    Picker("Date Format", selection: $settings.watchDateFormat) {
                        Text("Auto").tag("auto")
                        Text("Mon Jun 8").tag("long")
                        Text("Mon 06/08").tag("short")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.watchDateFormat) { _, _ in
                        model.syncToWatch()
                    }
                }
            }

            Section("Progress") {
                Picker("Circular Ring", selection: $settings.circularRingMode) {
                    Text("Book").tag("total")
                    Text("Chapter").tag("chapter")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.circularRingMode) { _, _ in
                    model.syncToWatch()
                }

                Toggle("Show Circular Ring", isOn: Binding(
                    get: { !settings.circularRingHidden },
                    set: { settings.circularRingHidden = !$0 }
                ))
                .onChange(of: settings.circularRingHidden) { _, _ in
                    model.syncToWatch()
                }

                Picker("Linear Bar", selection: $settings.linearBarMode) {
                    Text("Chapter").tag("chapter")
                    Text("Book").tag("total")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.linearBarMode) { _, _ in
                    model.syncToWatch()
                }

                Toggle("Show Linear Bar", isOn: Binding(
                    get: { !settings.linearBarHidden },
                    set: { settings.linearBarHidden = !$0 }
                ))
                .onChange(of: settings.linearBarHidden) { _, _ in
                    model.syncToWatch()
                }
            }

            Section("Controls") {
                Picker("Digital Crown", selection: $settings.crownAction) {
                    Text("Volume").tag("volume")
                    Text("Scrubbing").tag("scrub")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.crownAction) { _, _ in
                    model.syncToWatch()
                }

                VStack(alignment: .leading) {
                    Text("Volume Sensitivity")
                    HStack {
                        Image(systemName: "tortoise")
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.crownVolumeSensitivity, in: 0.01...0.1, step: 0.01)
                        Image(systemName: "hare")
                            .foregroundStyle(.secondary)
                    }
                    Text("\(settings.crownVolumeSensitivity, specifier: "%.2f")×")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading) {
                    Text("Scrubbing Sensitivity")
                    HStack {
                        Image(systemName: "tortoise")
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.crownScrubSensitivity, in: 0.1...1.0, step: 0.1)
                        Image(systemName: "hare")
                            .foregroundStyle(.secondary)
                    }
                    Text("\(settings.crownScrubSensitivity, specifier: "%.1f")×")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Button Haptics", isOn: Binding(
                    get: { settings.isHapticFeedbackEnabled },
                    set: {
                        settings.isHapticFeedbackEnabled = $0
                        model.syncToWatch()
                    }
                ))

                Stepper(value: $settings.watchQuickBookmarkTimeoutSeconds, in: 1...15) {
                    LabeledContent("Quick Bookmark", value: "\(settings.watchQuickBookmarkTimeoutSeconds)s")
                }
                .onChange(of: settings.watchQuickBookmarkTimeoutSeconds) { _, _ in
                    model.syncToWatch()
                }
            }

            Section("Layout Designer") {
                VStack(spacing: 8) {
                    Text("Page \(selectedPage + 1) of 5")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TabView(selection: $selectedPage) {
                        WatchPreviewCanvas(slots: $page1Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(0)
                        WatchPreviewCanvas(slots: $page2Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(1)
                        WatchPreviewCanvas(slots: $page3Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(2)
                        WatchPreviewCanvas(slots: $page4Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(3)
                        WatchPreviewCanvas(slots: $page5Slots, backgroundStyle: settings.watchBackgroundStyle, onChange: saveSlots).tag(4)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .frame(height: 320)
                    .indexViewStyle(.page(backgroundDisplayMode: .always))

                    Text("Choose actions for this page below, or drag actions into the watch preview.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    selectedPageSlotPickers
                }
                .frame(maxWidth: .infinity)
            }

            Section("Available Actions") {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(palette) { action in
                            PaletteItem(action: action)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }

            Section("Presets") {
                Button {
                    newPresetName = ""
                    showingSaveAlert = true
                } label: {
                    Label("Save Current", systemImage: "plus.circle")
                }

                if settings.watchPresets.isEmpty {
                    Text("No presets saved yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.watchPresets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                Text("P1: \(preset.page1.map { $0 == .empty ? "Empty" : $0.rawValue }.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()

                            Button("Load") {
                                page1Slots = padded(preset.page1)
                                page2Slots = padded(preset.page2)
                                page3Slots = padded(preset.page3 ?? [])
                                page4Slots = padded(preset.page4 ?? [])
                                page5Slots = padded(preset.page5 ?? [])
                                saveSlots()
                                Haptic.play(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                settings.watchPresets.removeAll(where: { $0.id == preset.id })
                                Haptic.play(.light)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }

            Section {
                Button {
                    saveSlots()
                    model.syncToWatch()
                    Haptic.play(.medium)
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .navigationTitle("Watch App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSlots() }
        .alert("Save Current Layout", isPresented: $showingSaveAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                saveCurrentAsPreset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for this watch layout configuration.")
        }
```

- [ ] **Step 4: Keep the Swift concurrency drag/drop fix**

In `DropSlot.onDrop`, preserve the existing main-actor hop. If the file still contains `DispatchQueue.main.async`, replace that dispatch body with:

```swift
                    Task { @MainActor in
                        slot = action
                        onChange()
                    }
```

- [ ] **Step 5: Run tests**

Run:

```bash
make test-only FILTER=EchoTests/WatchAppDesignerAccessibilityTests
```

Expected: all `WatchAppDesignerAccessibilityTests` pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/WatchAppSettingsView.swift EchoTests/WatchAppDesignerAccessibilityTests.swift
git commit -m "feat: normalize watch settings layout"
```

---

### Task 6: Phone Player Settings Form And Terminology

**Files:**
- Modify: `EchoCore/Views/PhonePlayerSettingsView.swift:56-338`
- Modify: `EchoTests/PhonePlayerPaletteTests.swift:91-123`

**Interfaces:**
- Consumes: existing phone slots, long-press slots, `PhoneSlotPickerGrid`, `PhonePreviewCanvas`, `SoundscapePickerView`, `ChimeSettingsView`.
- Produces: `PhonePlayerSettingsView` as a `Form` with `Layout`, `Mini-Player`, `Player Buttons`, `Focus Tools`, `Available Actions`, and `Presets` sections.

- [ ] **Step 1: Add failing phone settings structure test**

Append this test to `PhonePlayerPaletteTests`:

```swift
    @Test func phoneSettingsUsesFormSectionsAndSharedDesignerTerms() throws {
        let source = try Self.source(named: "PhonePlayerSettingsView.swift")
        #expect(source.contains("Form {"))
        #expect(source.contains("Section(\"Layout\")"))
        #expect(source.contains("Section(\"Mini-Player\")"))
        #expect(source.contains("Section(\"Player Buttons\")"))
        #expect(source.contains("Section(\"Focus Tools\")"))
        #expect(source.contains("Section(\"Available Actions\")"))
        #expect(source.contains("Section(\"Presets\")"))
        #expect(source.contains("Reset to Defaults"))
        #expect(!source.contains("ScrollView {"))
        #expect(!source.contains("Phone App Designer Info"))
        #expect(!source.contains("Layout Presets"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/PhonePlayerPaletteTests
```

Expected: `phoneSettingsUsesFormSectionsAndSharedDesignerTerms` fails because the view still uses a top-level `ScrollView` and `Layout Presets`.

- [ ] **Step 3: Replace the top-level phone `ScrollView` with `Form` sections**

In `EchoCore/Views/PhonePlayerSettingsView.swift`, replace the body `ScrollView` with:

```swift
        Form {
            Section("Layout") {
                Picker("Player Layout", selection: $settings.playerLayoutStyle) {
                    Text("Default").tag("default")
                    Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Compact uses a smaller scrubber and reorganizes transport controls for a more minimal player.")
            }

            Section("Mini-Player") {
                ForEach(0..<3, id: \.self) { slot in
                    Picker(
                        String(localized: "Slot \(slot + 1)"),
                        selection: Binding(
                            get: {
                                settings.miniPlayerPage.indices.contains(slot)
                                    ? settings.miniPlayerPage[slot] : .empty
                            },
                            set: { newAction in
                                var page = settings.miniPlayerPage
                                while page.count < 3 { page.append(.empty) }
                                page[slot] = newAction
                                settings.miniPlayerPage = page
                            }
                        )
                    ) {
                        ForEach(miniPlayerChoices) { action in
                            Label(miniPlayerChoiceName(action), systemImage: action.iconName)
                                .tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("The three buttons shown in the mini-player on Now Playing and Read surfaces.")
            }

            Section("Player Buttons") {
                Picker("Configure", selection: $configMode) {
                    Text("Tap Actions").tag(ConfigMode.tap)
                    Text("Long Press").tag(ConfigMode.longPress)
                }
                .pickerStyle(.segmented)

                VStack(spacing: 16) {
                    PhonePreviewCanvas(
                        slots: configMode == .tap ? $slots : $longPressSlots,
                        onChange: saveSlots
                    )
                    PhoneSlotPickerGrid(
                        slots: configMode == .tap ? $slots : $longPressSlots,
                        choices: phoneSlotChoices,
                        onChange: saveSlots
                    )
                }
                .frame(maxWidth: .infinity)

                Text("Choose actions for each slot, or drag actions into the phone preview.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Focus Tools") {
                Button {
                    showingSoundscapePicker = true
                } label: {
                    Label("Soundscape", systemImage: "waveform")
                }

                Button {
                    showingChimeSettings = true
                } label: {
                    Label("Interval Chime", systemImage: "bell")
                }
            }

            Section("Available Actions") {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(palette) { action in
                            PaletteItem(action: action)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }

            Section("Presets") {
                Button {
                    newPresetName = ""
                    showingSaveAlert = true
                } label: {
                    Label("Save Current", systemImage: "plus.circle")
                }

                if settings.phonePresets.isEmpty {
                    Text("No presets saved yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.phonePresets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                Text("Slots: \(preset.slots.map { $0 == .empty ? "Empty" : $0.rawValue }.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()

                            Button("Load") {
                                slots = padded(preset.slots)
                                longPressSlots = padded(preset.longPressSlots ?? [])
                                saveSlots()
                                Haptic.play(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                settings.phonePresets.removeAll(where: { $0.id == preset.id })
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }

                Button("Reset to Defaults", role: .destructive) {
                    slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]
                    longPressSlots = Array(repeating: .empty, count: 5)
                    saveSlots()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        }
        .navigationTitle("Phone Player Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSlots() }
        .sheet(isPresented: $showingSoundscapePicker) {
            SoundscapePickerView(engine: model.audioEngine.soundscapeMixer)
        }
        .sheet(isPresented: $showingChimeSettings) {
            ChimeSettingsView(engine: model.audioEngine.chimePlayer)
        }
        .alert("Save Current Layout", isPresented: $showingSaveAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                saveCurrentAsPreset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for this phone layout configuration.")
        }
```

- [ ] **Step 4: Run tests**

Run:

```bash
make test-only FILTER=EchoTests/PhonePlayerPaletteTests
```

Expected: all `PhonePlayerPaletteTests` pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/PhonePlayerSettingsView.swift EchoTests/PhonePlayerPaletteTests.swift
git commit -m "feat: normalize phone player settings layout"
```

---

### Task 7: Playback Options More Controls Label

**Files:**
- Modify: `EchoCore/Views/PlaybackOptionsSheet.swift:80-92`
- Modify: `EchoTests/PlaybackOptionsSheetTests.swift:7-59`

**Interfaces:**
- Consumes: `PhonePlayerSettingsView`.
- Produces: toolbar link labeled `More Controls`.

- [ ] **Step 1: Add failing toolbar label test**

Add this test to `PlaybackOptionsSheetTests`:

```swift
    @Test func sheetLinksToDurableControlsSettings() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(source.contains("PhonePlayerSettingsView()"))
        #expect(source.contains("Text(\"More Controls\")"))
        #expect(!source.contains("Text(\"More\")"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/PlaybackOptionsSheetTests
```

Expected: `sheetLinksToDurableControlsSettings` fails because the toolbar label is still `More`.

- [ ] **Step 3: Rename the toolbar label and comment**

In `EchoCore/Views/PlaybackOptionsSheet.swift`, replace:

```swift
                // BookPlayer-style "More" → the full player-controls surface
                // (skip intervals, smart rewind, quick-action speeds, layout).
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhonePlayerSettingsView()
                    } label: {
                        Text("More")
                    }
                }
```

with:

```swift
                // Durable button/layout customization lives in Settings > Controls.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhonePlayerSettingsView()
                    } label: {
                        Text("More Controls")
                    }
                }
```

- [ ] **Step 4: Run tests**

Run:

```bash
make test-only FILTER=EchoTests/PlaybackOptionsSheetTests
```

Expected: all `PlaybackOptionsSheetTests` pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/PlaybackOptionsSheet.swift EchoTests/PlaybackOptionsSheetTests.swift
git commit -m "chore: clarify playback options controls link"
```

---

### Task 8: Help And Documentation Paths

**Files:**
- Modify: `EchoCore/Views/HelpContent.swift:48-61,151,221-232`
- Modify: `ARCHITECTURE.md:1020-1033`
- Modify: `docs/guides/user-manual.md:440,502`
- Modify: `docs/manual.html:519,581`
- Modify: `EchoTests/SettingsExtractionTests.swift` or create `EchoTests/SettingsHelpPathTests.swift`

**Interfaces:**
- Consumes: new settings IA labels.
- Produces: user-facing help/docs paths matching:
  - `Settings > Controls > Phone Player Settings`
  - `Settings > Now Playing > Playback Defaults`
  - `Settings > Now Playing > Playback Defaults > Smart Rewind`
  - `Settings > Controls > Watch App Settings`
  - `Settings > Appearance > Reader Defaults`

- [ ] **Step 1: Add failing help path test**

Create `EchoTests/SettingsHelpPathTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct SettingsHelpPathTests {
    @Test func helpContentUsesCurrentSettingsPaths() throws {
        let source = try Self.source("EchoCore/Views/HelpContent.swift")

        #expect(source.contains("Settings > Controls > Phone Player Settings"))
        #expect(source.contains("Settings > Now Playing > Playback Defaults"))
        #expect(source.contains("Settings > Now Playing > Playback Defaults > Smart Rewind"))
        #expect(source.contains("Settings > Controls > Watch App Settings"))
        #expect(!source.contains("Settings > Phone Controls"))
        #expect(!source.contains("Settings > Playback > Default Speed"))
        #expect(!source.contains("Settings > Smart Rewind"))
        #expect(!source.contains("Settings > Watch App"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
make test-only FILTER=EchoTests/SettingsHelpPathTests
```

Expected: the new test fails because `HelpContent.swift` still has stale paths.

- [ ] **Step 3: Update `HelpContent.swift` paths**

In `EchoCore/Views/HelpContent.swift`, replace these sentences:

```swift
            Each button can be configured with a Tap Action (primary) and a Long Press Action (secondary). Customize both in Settings > Phone Controls. Long-press a button for 0.5 seconds to trigger its secondary action with haptic feedback.
```

with:

```swift
            Each button can be configured with a Tap Action (primary) and a Long Press Action (secondary). Customize both in Settings > Controls > Phone Player Settings. Long-press a button for 0.5 seconds to trigger its secondary action with haptic feedback.
```

Replace:

```swift
            The default speed for new books is 1.25×, but you can change this in Settings > Playback > Default Speed. This setting is overridden if you manually select a different speed for a specific book.
```

with:

```swift
            The default speed for new books is 1.25×, but you can change this in Settings > Now Playing > Playback Defaults. This setting is overridden if you manually select a different speed for a specific book.
```

Replace:

```swift
            Configure Smart Rewind in Settings > Smart Rewind. The feature is off by default. All automatic rewind amounts and the manual skip backward button respect chapter boundaries — you will never rewind past the start of the current chapter.
```

with:

```swift
            Configure Smart Rewind in Settings > Now Playing > Playback Defaults > Smart Rewind. The feature is off by default. All automatic rewind amounts and the manual skip backward button respect chapter boundaries — you will never rewind past the start of the current chapter.
```

Replace:

```swift
            • Up to five customizable Player Pages — Each page holds up to 5 action slots that you can configure from the iPhone Settings > Watch App screen. Swipe between pages to configure them. Empty pages are hidden on the watch.
```

with:

```swift
            • Up to five customizable Player Pages — Each page holds up to 5 action slots that you can configure from the iPhone Settings > Controls > Watch App Settings screen. Swipe between pages to configure them. Empty pages are hidden on the watch.
```

Replace:

```swift
            Configure all watch options from the iPhone app under Settings > Watch App.
```

with:

```swift
            Configure all watch options from the iPhone app under Settings > Controls > Watch App Settings.
```

- [ ] **Step 4: Update docs**

In `ARCHITECTURE.md`, replace:

```markdown
The iOS player supports two layout variants, selected via **Settings > Customization > Phone Player Designer > Player Layout Style** (`PhonePlayerSettingsView`):
```

with:

```markdown
The iOS player supports two layout variants, selected via **Settings > Controls > Phone Player Settings > Layout** (`PhonePlayerSettingsView`):
```

Replace the `### Settings Restructure (BookPlayer redesign, June 2026)` paragraph at `ARCHITECTURE.md:1031-1033` with:

```markdown
### Settings Restructure (Settings cleanup, June 2026)

`SettingsView` is a thin app-level shell organized by user intent: Now Playing, Appearance, Controls, Library & Accounts, Study & Notes, Advanced & Privacy, and Support & About. Durable playback defaults live in `SettingsNowPlayingView`; app styling and reader defaults live under `SettingsAppearanceView`; phone/watch control designers live under Controls. The quick in-context `PlaybackOptionsSheet` still edits the current listening session and links to `PhonePlayerSettingsView` for durable controls. The former extracted sub-views remain in their own files (`SettingsAppearanceView`, `FontSelectionView`, `ThemeSelectionView`, `ProTranscriptsSettingsView`, `AppIconSelectionView`, `SettingsAdvancedView`) so `SettingsView` stays a routing shell.
```

In `docs/guides/user-manual.md`, replace `Settings → Watch App` with `Settings → Controls → Watch App Settings`.

In `docs/manual.html`, replace `Settings → Watch App` with `Settings → Controls → Watch App Settings` and update the watch-app settings table label if present.

- [ ] **Step 5: Run tests**

Run:

```bash
make test-only FILTER=EchoTests/SettingsHelpPathTests
```

Expected: `SettingsHelpPathTests` passes.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/HelpContent.swift ARCHITECTURE.md docs/guides/user-manual.md docs/manual.html EchoTests/SettingsHelpPathTests.swift
git commit -m "docs: update settings help paths"
```

---

### Task 9: Final Verification And Cleanup

**Files:**
- Modify only files touched by previous tasks if verification exposes issues.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: green targeted tests and a clean worktree.

- [ ] **Step 1: Run source-scanning settings tests**

Run:

```bash
make test-only FILTER=EchoTests/SettingsExtractionTests
make test-only FILTER=EchoTests/WatchAppDesignerAccessibilityTests
make test-only FILTER=EchoTests/PhonePlayerPaletteTests
make test-only FILTER=EchoTests/PlaybackOptionsSheetTests
make test-only FILTER=EchoTests/SettingsHelpPathTests
```

Expected: all commands pass.

- [ ] **Step 2: Run settings/defaults behavior tests**

Run:

```bash
make test-only FILTER=EchoTests/EchoCoreTests
```

Expected: all `EchoCoreTests` pass.

- [ ] **Step 3: Build the app tests if test-without-building reports stale products**

Run only if any `make test-only` command fails because test products are stale:

```bash
make build-tests
```

Expected: build-for-testing succeeds.

- [ ] **Step 4: Run full unit tests**

Run:

```bash
make test
```

Expected: the Echo unit test action succeeds. UI tests remain intentionally excluded from the Echo scheme's test action.

- [ ] **Step 5: Inspect the diff for accidental unrelated changes**

Run:

```bash
git status --short
git diff --check
git diff --stat origin/nightly...HEAD
```

Expected: only settings cleanup files, docs, and tests are changed; `git diff --check` prints no whitespace errors.

- [ ] **Step 6: Commit final fixes if needed**

If Step 1-5 required edits, commit them:

```bash
git add EchoCore/Views EchoCore/Services EchoTests ARCHITECTURE.md docs/guides/user-manual.md docs/manual.html
git commit -m "chore: verify settings cleanup"
```

Expected: either no commit is needed, or the final commit contains only verification fixes.

---

## Plan Self-Review Notes

- Spec coverage:
  - Root IA is covered by Task 3.
  - Watch defaults and no-reset behavior are covered by Task 1.
  - Watch progress segmented controls and watch settings uniformity are covered by Task 5.
  - Phone Player Settings uniformity is covered by Task 6.
  - Playback Options session orientation is covered by Task 7.
  - Reader defaults under Appearance are covered by Task 4.
  - Help/docs paths are covered by Task 8.
  - Verification is covered by Task 9.
- No deployment targets, Swift language version, or dependencies change.
- Existing persisted watch settings remain respected because Task 1 only changes default constants and adds a persisted-value override test.
