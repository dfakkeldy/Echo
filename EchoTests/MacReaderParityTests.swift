// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS reader-interaction parity in MacReaderFeedView.
/// The `Echo macOS` target is not compiled into EchoTests, so we assert against
/// source text via `MacSource`. Alignment work goes through the shared,
/// macOS-clean `AlignmentService`.
struct MacReaderParityTests {

    @Test func articleWorkshopEditsInheritedAndExplicitChapterVoices() throws {
        let workshop = try MacSource.read("Views/MacArticleWorkshopView.swift")
        let editor = try MacSource.read("Views/MacAnthologyVoiceEditor.swift")

        #expect(workshop.contains("private let anthologyService: AnthologyService"))
        #expect(workshop.contains("Button(\"Edit Voices\""))
        #expect(workshop.contains("service.loadProject"))
        #expect(workshop.contains("MacAnthologyVoiceEditor("))
        #expect(workshop.contains(".sheet("))
        #expect(workshop.contains("articleWorkshop.editVoices."))

        #expect(editor.contains("struct MacAnthologyVoiceEditor: View"))
        #expect(editor.contains("@State internal var viewModel: AnthologyBuilderViewModel"))
        #expect(editor.contains("let preferredVoice: VoiceID"))
        #expect(editor.contains("Picker(\"Narration Voice\""))
        #expect(editor.contains("Text(\"Echo Preferred Voice\").tag(String?.none)"))
        #expect(editor.contains("viewModel.updateEntry("))
        #expect(editor.contains("narrationVoiceID: voiceID"))
        #expect(editor.contains("viewModel.isSaving"))
        #expect(editor.contains("viewModel.userMessage"))
        #expect(editor.contains("Inherited from Echo Preferred Voice"))
        #expect(editor.contains("Explicit chapter voice:"))
        #expect(editor.contains("articleWorkshop.chapterVoice."))
    }

    @Test func chapterVoiceSheetCannotDismissWhileSavingAndOnlySavingRowPickerDisables()
        throws
    {
        let editor = try MacSource.read("Views/MacAnthologyVoiceEditor.swift")

        #expect(
            editor.contains(
                "@State private var pendingSaveCountsByEntryID: [String: Int] = [:]"))
        #expect(
            editor.contains(
                "viewModel.isSaving || pendingSaveCountsByEntryID.isEmpty == false"))
        #expect(editor.contains(".interactiveDismissDisabled(saveIsPending)"))
        #expect(editor.contains(".onExitCommand"))
        #expect(editor.contains("guard saveIsPending == false else { return }"))
        #expect(editor.contains("Button(\"Close\") { dismiss() }"))
        #expect(editor.contains(".disabled(saveIsPending)"))
        #expect(
            editor.contains(
                ".disabled((pendingSaveCountsByEntryID[entry.entry.id] ?? 0) > 0)"))
        #expect(editor.contains("pendingSaveCountsByEntryID.removeValue(forKey: entryID)"))
        #expect(editor.contains("if pendingSaveCount == 1"))
        #expect(editor.contains("pendingSaveCountsByEntryID[entryID] = pendingSaveCount - 1"))
        #expect(editor.contains("pendingSaveEntryIDs") == false)

        let onChange = try #require(editor.range(of: ".onChange(of: voiceID)"))
        let handlerRange = onChange.lowerBound..<editor.endIndex
        let pendingRegistration = try #require(
            editor.range(
                of: "pendingSaveCountsByEntryID[entryID, default: 0] += 1",
                range: handlerRange))
        let taskCreation = try #require(
            editor.range(
                of: "Task {",
                range: handlerRange))
        let awaitedSave = try #require(
            editor.range(
                of: "await viewModel.updateEntry(",
                range: handlerRange))
        let pendingClear = try #require(
            editor.range(
                of: "if let pendingSaveCount = pendingSaveCountsByEntryID[entryID]",
                range: handlerRange))
        let finalPendingRemoval = try #require(
            editor.range(
                of: "pendingSaveCountsByEntryID.removeValue(forKey: entryID)",
                range: handlerRange))
        let intermediatePendingDecrement = try #require(
            editor.range(
                of: "pendingSaveCountsByEntryID[entryID] = pendingSaveCount - 1",
                range: handlerRange))
        #expect(
            pendingRegistration.lowerBound < taskCreation.lowerBound,
            "The editor must synchronously register the saving row before creating the task.")
        #expect(taskCreation.lowerBound < awaitedSave.lowerBound)
        #expect(
            awaitedSave.lowerBound < pendingClear.lowerBound,
            "The editor must retain the saving-row registration through the awaited save.")
        #expect(pendingClear.lowerBound < finalPendingRemoval.lowerBound)
        #expect(pendingClear.lowerBound < intermediatePendingDecrement.lowerBound)
    }

    @Test func chapterVoiceSaveAndParentLoadErrorsMoveAccessibilityFocusWithoutKeyboardFocus()
        throws
    {
        let workshop = try MacSource.read("Views/MacArticleWorkshopView.swift")
        let editor = try MacSource.read("Views/MacAnthologyVoiceEditor.swift")

        #expect(editor.contains("@AccessibilityFocusState private var saveErrorIsFocused: Bool"))
        #expect(editor.contains(".accessibilityFocused($saveErrorIsFocused)"))
        #expect(editor.contains(".onChange(of: viewModel.retryActionAvailable)"))
        #expect(editor.contains("saveErrorIsFocused = true"))
        #expect(editor.contains("AccessibilityNotification.LayoutChanged().post()"))
        #expect(editor.contains("AccessibilityNotification.Announcement") == false)

        #expect(
            workshop.contains(
                "@AccessibilityFocusState private var voiceEditorLoadErrorIsFocused: Bool"))
        #expect(workshop.contains(".accessibilityFocused($voiceEditorLoadErrorIsFocused)"))
        #expect(workshop.contains(".onChange(of: voiceEditorLoadMessage)"))
        #expect(workshop.contains("voiceEditorLoadErrorIsFocused = true"))
        #expect(workshop.contains("AccessibilityNotification.LayoutChanged().post()"))
        #expect(workshop.contains("AccessibilityNotification.Announcement") == false)

        #expect(editor.contains("@FocusState private var pickerIsFocused: Bool"))
    }

    @Test func macCommercialAudioAlignmentUsesCodeFilteringSourcePolicy() throws {
        let src = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(
            src.contains("CommercialAudioAlignmentSource.blocks(from: parsed.blocks)"),
            "The macOS DTW entry point must use the shared source-block filter before tokenizing.")
        #expect(
            src.contains("sourceBlocks: parsed.blocks"),
            "The macOS DTW sidecar writer must bind anchors to the parsed source identity.")
    }

    @Test func narrationSidecarWritersAttachSourceIdentity() throws {
        let batch = try MacSource.read("Services/MacBatchProcessingService.swift")
        #expect(batch.contains("sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: block)"))
        #expect(batch.contains("NarrationPlanTrackOffsets.chapterOffsets("))
        #expect(batch.contains("expectedFilePathsByTrackID"))

        let headless = try projectSource(
            "EchoCore/Services/Narration/HeadlessNarrationRunner.swift"
        )
        #expect(headless.contains("AlignmentSidecar.attachingSourceIdentities("))
    }

    @Test func batchNarrationUsesTrustedChapterPlanThroughRetry() throws {
        let src = try MacSource.read("Services/MacBatchProcessingService.swift")

        #expect(src.contains("AnthologyNarrationManifestResolver(db: dbService.writer).resolve("))
        #expect(src.contains("epubURL: epubURL.standardizedFileURL"))
        #expect(src.contains("NarrationChapterRenderPlanner.plan("))
        #expect(src.contains("sourceChapterKey: chapter.sourceChapterKey"))
        #expect(src.contains("voice: chapter.voice"))
        #expect(src.contains("let failedChapter = chapter"))
        #expect(src.contains("sourceChapterKey: failedChapter.sourceChapterKey"))
        #expect(src.contains("voice: failedChapter.voice"))
    }

    @Test func readerHasAlignmentContextMenu() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("alignmentMenu"),
            "The reader cards must offer a right-click alignment context menu.")
        #expect(
            src.contains("\"Align to Now\""),
            "The alignment menu must offer Align to Now (and the other per-block actions).")
    }

    @Test func alignmentRoutesThroughSharedService() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("AlignmentService(db:"),
            "Manual alignment must use the shared AlignmentService, not a macOS reimplementation.")
        #expect(
            src.contains("moveBlockToCurrentTime") && src.contains("resetAlignment"),
            "The menu must wire the AlignmentService editing entry points (move/hide/erase/reset).")
    }

    @Test func alignmentReloadsFeed() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("performAlignment("),
            "A performAlignment helper must apply the edit and reload the feed.")
    }

    @Test func readerRendersCodeAsSelectableHorizontalCard() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")

        #expect(
            src.contains("case EPubBlockRecord.Kind.code.rawValue:"),
            "The macOS reader must route code blocks to a dedicated renderer.")
        #expect(src.contains("ScrollView(.horizontal)"))
        #expect(src.contains("design: .monospaced"))
        #expect(src.contains(".textSelection(.enabled)"))
        #expect(src.contains("block.codeLanguage"))
        #expect(
            src.contains("Button(\"Seek to code listing\", systemImage: \"play.fill\""),
            "Selectable code should keep seeking available as a separate accessible control.")
    }

    @Test func readerEqualityInvalidatesStableIDKindTextAndLanguageChanges() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("lhs.block == rhs.block"),
            "MacBlockCardView equality must compare the full block, not only its stable ID.")

        let original = readerBlock()
        var changedKind = original
        changedKind.blockKind = EPubBlockRecord.Kind.code.rawValue
        var changedText = original
        changedText.text = "let value = 42"
        var changedLanguage = original
        changedLanguage.codeLanguage = "swift"

        #expect(changedKind.id == original.id)
        #expect(changedText.id == original.id)
        #expect(changedLanguage.id == original.id)
        #expect(changedKind != original)
        #expect(changedText != original)
        #expect(changedLanguage != original)
    }

    private func readerBlock() -> EPubBlockRecord {
        EPubBlockRecord(
            id: "stable-block-id",
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Flattened prose.",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: 2,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            codeLanguage: nil,
            createdAt: nil,
            modifiedAt: nil)
    }

    /// Reads a non-macOS source, applying the same whitespace normalization as
    /// `MacSource.read` so these assertions tolerate formatter line-wrapping.
    private func projectSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return MacSource.normalized(
                    try String(contentsOf: candidate, encoding: .utf8))
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
