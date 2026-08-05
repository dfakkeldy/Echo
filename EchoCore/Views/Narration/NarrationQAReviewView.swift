// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI

/// Per-book narration-QA review list: each row shows the source text, what the
/// transcriber heard, the issue label, ignore/resolve actions, and accepted
/// pronunciation fixes. iOS-only (excluded from macOS/echo-cli).
struct NarrationQAReviewView: View {
    private struct PendingPronunciationAction {
        enum Kind {
            case legacy
            case currentAdvisory
            case alternative(String)
        }

        let issue: NarrationQualityIssueRecord
        let kind: Kind
    }

    @State private var model: NarrationQAReviewModel
    @State private var isRunning = false
    @State private var pendingPronunciationAction: PendingPronunciationAction?
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
                        Label(
                            issueLabel(issue),
                            systemImage: issueIcon(issue)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        LabeledContent("Expected", value: issue.expectedText)
                        LabeledContent(
                            "Heard", value: issue.heardText.isEmpty ? "\u{2014}" : issue.heardText)

                        if let presentation = model.pronunciationPresentation(for: issue) {
                            pronunciationEvidence(presentation, issue: issue)
                        } else if hasLegacyActionablePronunciationFix(issue) {
                            Button("Add Pronunciation", systemImage: "textformat.abc") {
                                pendingPronunciationAction = PendingPronunciationAction(
                                    issue: issue, kind: .legacy)
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
            "Apply Pronunciation",
            isPresented: Binding(
                get: { pendingPronunciationAction != nil },
                set: { isPresented in
                    if !isPresented { pendingPronunciationAction = nil }
                }),
            titleVisibility: .visible
        ) {
            if let action = pendingPronunciationAction {
                if hasSourceOccurrence(action.issue) {
                    Button("This Occurrence") {
                        applyPronunciationAction(action, scope: .occurrence)
                    }
                }
                Button("This Book") {
                    applyPronunciationAction(
                        action, scope: .book(action.issue.audiobookID))
                }
                Button("All Books") {
                    applyPronunciationAction(action, scope: .global)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPronunciationAction = nil
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

    @ViewBuilder
    private func pronunciationEvidence(
        _ presentation: NarrationQAReviewModel.PronunciationReviewPresentation,
        issue: NarrationQualityIssueRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Pronunciation evidence")
                .font(.subheadline.weight(.semibold))
            LabeledContent("Category", value: displayName(presentation.category.rawValue))
            LabeledContent("Reason", value: displayName(presentation.selectionReason.rawValue))
            if let observation = presentation.neuralShadowObservation {
                LabeledContent("Neural shadow", value: displayName(observation.rawValue))
            }
            LabeledContent(
                "Occurrences",
                value: String(presentation.occurrenceCount))

            if let selected = presentation.selectedCandidate {
                Text("Current decision")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                LabeledContent("IPA") {
                    Text(selected.ipa)
                        .font(.body.monospaced())
                        .accessibilityLabel("Current IPA, \(selected.ipa)")
                }
                LabeledContent("Candidate ID", value: selected.candidateID)
                LabeledContent("Source", value: displayName(selected.source.rawValue))
                LabeledContent("Authority", value: displayName(selected.authority.rawValue))
                LabeledContent("Validation", value: displayName(selected.validation.rawValue))

                if model.canAcceptCurrentCandidate(for: issue) {
                    Button("Use Current Pronunciation", systemImage: "textformat.abc") {
                        pendingPronunciationAction = PendingPronunciationAction(
                            issue: issue, kind: .currentAdvisory)
                    }
                    .buttonStyle(.bordered)
                    .disabled(applyingIssueID != nil)
                }
            } else if presentation.chosenCandidateID != nil {
                Text("Current candidate details unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("No candidate accepted")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !presentation.alternatives.isEmpty {
                Text("Alternatives")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                ForEach(presentation.alternatives, id: \.candidateID) { alternative in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alternative.ipa)
                            .font(.body.monospaced())
                            .accessibilityLabel("Alternative IPA, \(alternative.ipa)")
                        Text(
                            "\(alternative.source) \u{2022} "
                                + "\(displayName(alternative.authority.rawValue)) authority \u{2022} "
                                + displayName(alternative.validation.rawValue)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if alternative.validation == .eligible {
                            Button("Use This Candidate") {
                                pendingPronunciationAction = PendingPronunciationAction(
                                    issue: issue,
                                    kind: .alternative(alternative.candidateID))
                            }
                            .buttonStyle(.bordered)
                            .disabled(applyingIssueID != nil)
                            .accessibilityLabel(
                                "Use pronunciation \(alternative.ipa) from \(alternative.source)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func hasLegacyActionablePronunciationFix(
        _ issue: NarrationQualityIssueRecord
    ) -> Bool {
        guard issue.evidenceJSON == nil,
            issue.issueType == NarrationQAIssueType.pronunciation.rawValue,
            issue.origin != NarrationQualityIssueOrigin.acoustic.rawValue,
            let json = issue.suggestedFixJSON,
            let data = json.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: data),
            fix.ipa?.isEmpty == false
        else { return false }
        return true
    }

    private func issueLabel(_ issue: NarrationQualityIssueRecord) -> String {
        if issue.origin == NarrationQualityIssueOrigin.acoustic.rawValue {
            return "Acoustic pronunciation review"
        }
        if issue.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue {
            return "Pronunciation review"
        }
        return issue.issueType.capitalized
    }

    private func issueIcon(_ issue: NarrationQualityIssueRecord) -> String {
        if issue.origin == NarrationQualityIssueOrigin.acoustic.rawValue {
            return "waveform.badge.exclamationmark"
        }
        if issue.issueType == NarrationQAIssueType.pronunciation.rawValue {
            return "textformat.abc"
        }
        return "waveform.badge.magnifyingglass"
    }

    private func displayName(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func hasSourceOccurrence(_ issue: NarrationQualityIssueRecord) -> Bool {
        issue.sourceBlockID != nil && issue.sourceWordStart != nil && issue.sourceWordEnd != nil
    }

    private func applyPronunciationAction(
        _ action: PendingPronunciationAction,
        scope: FixScope
    ) {
        pendingPronunciationAction = nil
        applyingIssueID = action.issue.id
        Task { @MainActor in
            switch action.kind {
            case .legacy:
                await model.acceptFix(issue: action.issue, scope: scope)
            case .currentAdvisory:
                await model.acceptCurrentCandidate(for: action.issue, scope: scope)
            case .alternative(let candidateID):
                await model.acceptCandidate(candidateID, for: action.issue, scope: scope)
            }
            applyingIssueID = nil
        }
    }
}
