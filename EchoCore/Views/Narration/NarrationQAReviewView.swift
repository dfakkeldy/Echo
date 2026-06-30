// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI

/// Per-book narration-QA review list: each row shows the source text, what the
/// transcriber heard, the issue label, and ignore/resolve actions. Override +
/// regenerate actions arrive in M4. iOS-only (excluded from macOS/echo-cli).
struct NarrationQAReviewView: View {
    @State private var model: NarrationQAReviewModel
    @State private var isRunning = false
    @State private var pendingPronunciationFix: NarrationQualityIssueRecord?
    @State private var applyingIssueID: String?

    init(model: NarrationQAReviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            if let error = model.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if model.issues.isEmpty {
                ContentUnavailableView(
                    "No issues", systemImage: "checkmark.seal",
                    description: Text("Run narration QA to check this book."))
            } else {
                ForEach(model.issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.issueType.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Expected", value: issue.expectedText)
                        LabeledContent(
                            "Heard", value: issue.heardText.isEmpty ? "\u{2014}" : issue.heardText)
                        if hasActionablePronunciationFix(issue) {
                            Button("Add Pronunciation", systemImage: "textformat.abc") {
                                pendingPronunciationFix = issue
                            }
                            .buttonStyle(.bordered)
                            .disabled(applyingIssueID != nil)
                        }
                    }
                    .swipeActions {
                        Button("Resolve") { model.markResolved(issue) }.tint(.green)
                        Button("Ignore", role: .destructive) { model.ignore(issue) }
                    }
                }
            }
        }
        .navigationTitle("Narration QA")
        .confirmationDialog(
            "Add Pronunciation",
            isPresented: Binding(
                get: { pendingPronunciationFix != nil },
                set: { isPresented in
                    if !isPresented { pendingPronunciationFix = nil }
                }),
            titleVisibility: .visible
        ) {
            if let issue = pendingPronunciationFix {
                Button("This Book") {
                    applyPronunciationFix(issue, scope: .book(issue.audiobookID))
                }
                Button("All Books") {
                    applyPronunciationFix(issue, scope: .global)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPronunciationFix = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isRunning = true
                        await model.runFullQA()
                        isRunning = false
                    }
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Label("Run QA", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .disabled(isRunning)
            }
        }
        .onAppear { model.load() }
    }

    private func hasActionablePronunciationFix(_ issue: NarrationQualityIssueRecord) -> Bool {
        guard issue.issueType == NarrationQAIssueType.pronunciation.rawValue,
            let json = issue.suggestedFixJSON,
            let data = json.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: data),
            fix.ipa?.isEmpty == false
        else { return false }
        return true
    }

    private func applyPronunciationFix(_ issue: NarrationQualityIssueRecord, scope: FixScope) {
        pendingPronunciationFix = nil
        applyingIssueID = issue.id
        Task { @MainActor in
            await model.acceptFix(issue: issue, scope: scope)
            applyingIssueID = nil
        }
    }
}
