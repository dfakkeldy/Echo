// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct MacAnthologyVoiceEditor: View {
    @State internal var viewModel: AnthologyBuilderViewModel
    @State private var pendingSaveEntryIDs: Set<String> = []
    @State private var retryIsPending = false
    @AccessibilityFocusState private var saveErrorIsFocused: Bool
    let preferredVoice: VoiceID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Uses your current Echo narration voice. Changing that preference updates inherited chapters the next time they are narrated."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("articleWorkshop.chapterVoice.help")
                }

                Section("Chapters") {
                    ForEach(viewModel.project.entries, id: \.entry.id) { entry in
                        MacAnthologyVoiceRow(
                            entry: entry,
                            viewModel: viewModel,
                            preferredVoice: preferredVoice,
                            pendingSaveEntryIDs: $pendingSaveEntryIDs)
                    }
                }

                if let message = viewModel.userMessage {
                    Section("Save Status") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityFocused($saveErrorIsFocused)
                        if viewModel.retryActionAvailable {
                            Button("Try Again") {
                                retryIsPending = true
                                Task {
                                    await viewModel.retry()
                                    retryIsPending = false
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("articleWorkshop.chapterVoice.saveError")
                }
            }
            .navigationTitle("Edit Voices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(saveIsPending)
                }
            }
        }
        .interactiveDismissDisabled(saveIsPending)
        .onExitCommand {
            guard saveIsPending == false else { return }
            dismiss()
        }
        .onChange(of: viewModel.retryActionAvailable) { _, retryActionAvailable in
            guard retryActionAvailable, viewModel.userMessage != nil else {
                saveErrorIsFocused = false
                return
            }
            saveErrorIsFocused = true
            AccessibilityNotification.LayoutChanged().post()
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private var saveIsPending: Bool {
        viewModel.isSaving || pendingSaveEntryIDs.isEmpty == false || retryIsPending
    }
}

private struct MacAnthologyVoiceRow: View {
    let entry: AnthologyProjectEntry
    let viewModel: AnthologyBuilderViewModel
    let preferredVoice: VoiceID

    @State private var voiceID: String?
    @Binding private var pendingSaveEntryIDs: Set<String>
    @FocusState private var pickerIsFocused: Bool

    init(
        entry: AnthologyProjectEntry,
        viewModel: AnthologyBuilderViewModel,
        preferredVoice: VoiceID,
        pendingSaveEntryIDs: Binding<Set<String>>
    ) {
        self.entry = entry
        self.viewModel = viewModel
        self.preferredVoice = preferredVoice
        _voiceID = State(initialValue: entry.entry.narrationVoiceID)
        _pendingSaveEntryIDs = pendingSaveEntryIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chapterTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text("Current voice: \(effectiveVoice.displayName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "articleWorkshop.chapterVoice.effective.\(entry.entry.id)"
                )

            Picker("Narration Voice", selection: $voiceID) {
                Text("Echo Preferred Voice").tag(String?.none)
                    .accessibilityIdentifier("articleWorkshop.chapterVoice.inherited")
                ForEach(VoiceCatalog.sections) { section in
                    Section(section.title) {
                        ForEach(section.voices) { voice in
                            Text("\(voice.displayName) — \(voice.descriptor)")
                                .tag(Optional(voice.id.rawValue))
                        }
                    }
                }
            }
            .focused($pickerIsFocused)
            .disabled(pendingSaveEntryIDs.contains(entry.entry.id))
            .accessibilityIdentifier("articleWorkshop.chapterVoice.\(entry.entry.id)")
            .accessibilityValue(Text(voiceAccessibilityValue))
            .onChange(of: voiceID) { _, voiceID in
                let entryID = entry.entry.id
                let restoreFocus = pickerIsFocused
                pendingSaveEntryIDs.insert(entryID)
                Task {
                    await viewModel.updateEntry(
                        id: entryID,
                        chapterTitleOverride: entry.entry.chapterTitleOverride,
                        narrationVoiceID: voiceID)
                    pendingSaveEntryIDs.remove(entryID)
                    if restoreFocus {
                        pickerIsFocused = true
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var effectiveVoice: NarrationVoice {
        voiceID.flatMap { VoiceCatalog.voice(for: VoiceID($0)) }
            ?? VoiceCatalog.voice(for: preferredVoice)
            ?? VoiceCatalog.default
    }

    private var voiceAccessibilityValue: String {
        guard let voiceID,
            let voice = VoiceCatalog.voice(for: VoiceID(voiceID))
        else {
            let preferred =
                VoiceCatalog.voice(for: preferredVoice)?.displayName
                ?? VoiceCatalog.default.displayName
            return String(
                localized: "Inherited from Echo Preferred Voice: \(preferred)"
            )
        }
        return String(localized: "Explicit chapter voice: \(voice.displayName)")
    }

    private var chapterTitle: String {
        let candidate =
            entry.entry.chapterTitleOverride
            ?? entry.cleanArticle?.metadata.title
            ?? entry.capture.title
        let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Untitled Article") : title
    }
}
