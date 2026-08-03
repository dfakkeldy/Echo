// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct MacAnthologyVoiceEditor: View {
    @State internal var viewModel: AnthologyBuilderViewModel
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
                            preferredVoice: preferredVoice)
                    }
                }

                if let message = viewModel.userMessage {
                    Section("Save Status") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if viewModel.retryActionAvailable {
                            Button("Try Again") {
                                Task { await viewModel.retry() }
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
                        .disabled(viewModel.isSaving)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .onExitCommand {
            guard viewModel.isSaving == false else { return }
            dismiss()
        }
        .onChange(of: viewModel.retryActionAvailable) { _, retryActionAvailable in
            guard retryActionAvailable, let message = viewModel.userMessage else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}

private struct MacAnthologyVoiceRow: View {
    let entry: AnthologyProjectEntry
    let viewModel: AnthologyBuilderViewModel
    let preferredVoice: VoiceID

    @State private var voiceID: String?
    @State private var isUpdating = false
    @FocusState private var pickerIsFocused: Bool

    init(
        entry: AnthologyProjectEntry,
        viewModel: AnthologyBuilderViewModel,
        preferredVoice: VoiceID
    ) {
        self.entry = entry
        self.viewModel = viewModel
        self.preferredVoice = preferredVoice
        _voiceID = State(initialValue: entry.entry.narrationVoiceID)
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
            .disabled(isUpdating && viewModel.isSaving)
            .accessibilityIdentifier("articleWorkshop.chapterVoice.\(entry.entry.id)")
            .accessibilityValue(Text(voiceAccessibilityValue))
            .onChange(of: voiceID) { _, voiceID in
                let restoreFocus = pickerIsFocused
                isUpdating = true
                Task {
                    await viewModel.updateEntry(
                        id: entry.entry.id,
                        chapterTitleOverride: entry.entry.chapterTitleOverride,
                        narrationVoiceID: voiceID)
                    isUpdating = false
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
