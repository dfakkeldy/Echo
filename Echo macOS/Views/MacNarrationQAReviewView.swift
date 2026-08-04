// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacNarrationQAReviewView.swift
//  Echo macOS
//
//  macOS window for reviewing narration QA issues. Uses the cross-platform
//  NarrationQAReviewModel as its data source. Each issue row shows expected
//  text, heard text, issue type badge, and confidence. Actions: Ignore /
//  Resolve / Save Override (acceptFix).
//

import Foundation
import GRDB
import SwiftUI

struct MacNarrationQAReviewView: View {
    @State private var model: NarrationQAReviewModel
    @State private var selectedIssueID: String?
    @State private var isRunning = false
    @State private var applyingIssueID: String?

    init(db: DatabaseWriter, audiobookID: String) {
        _model = State(initialValue: NarrationQAReviewModel(db: db, audiobookID: audiobookID))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { model.lastError = nil }
                }
                .padding()
                .background(.orange.opacity(0.1))
            }

            if model.issues.isEmpty {
                ContentUnavailableView(
                    "No Issues Found",
                    systemImage: "checkmark.circle",
                    description: Text("Narration QA didn't detect any issues.")
                )
            } else {
                List(model.issues, selection: $selectedIssueID) { issue in
                    issueRow(issue)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(model.issues.count) issues")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        isRunning = true
                        await model.runFullQA()
                        isRunning = false
                    }
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run QA", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .disabled(isRunning)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 500, minHeight: 350)
        .task { model.load() }
    }

    private func issueRow(_ issue: NarrationQualityIssueRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(issueLabel(issue), systemImage: issueIcon(issue))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(issueTypeColor(issue.issueType).opacity(0.2))
                    .clipShape(.capsule)

                Spacer()

                Text(confidenceText(issue.confidence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Expected").font(.caption).foregroundStyle(.secondary)
                    Text(issue.expectedText).font(.body.monospaced())
                }
                VStack(alignment: .leading) {
                    Text("Heard").font(.caption).foregroundStyle(.secondary)
                    Text(issue.heardText).font(.body.monospaced())
                }
            }

            if let presentation = model.pronunciationPresentation(for: issue) {
                pronunciationEvidence(presentation, issue: issue)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Ignore") {
                    model.ignore(issue)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if model.pronunciationPresentation(for: issue) != nil
                    || hasLegacyActionablePronunciationFix(issue)
                {
                    Menu("Save Override") {
                        pronunciationScopeButtons(issue: issue, candidateID: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(applyingIssueID != nil)
                }

                Button("Resolved") {
                    model.markResolved(issue)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pronunciationEvidence(
        _ presentation: NarrationQAReviewModel.PronunciationReviewPresentation,
        issue: NarrationQualityIssueRecord
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Current IPA")
                    .foregroundStyle(.secondary)
                Text(presentation.selectedIPA)
                    .font(.body.monospaced())
                    .accessibilityLabel("Current IPA, \(presentation.selectedIPA)")
            }
            GridRow {
                Text("Candidate ID")
                    .foregroundStyle(.secondary)
                Text(presentation.chosenCandidateID ?? "Recorded decision")
            }
            GridRow {
                Text("Authority")
                    .foregroundStyle(.secondary)
                Text(displayName(presentation.selectedAuthority.rawValue))
            }
            GridRow {
                Text("Reason")
                    .foregroundStyle(.secondary)
                Text(displayName(presentation.selectionReason.rawValue))
            }
            GridRow {
                Text("Occurrences")
                    .foregroundStyle(.secondary)
                Text(String(presentation.occurrenceCount))
            }
        }
        .font(.callout)

        if !presentation.alternatives.isEmpty {
            Text("Alternatives")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            ForEach(presentation.alternatives, id: \.candidateID) { alternative in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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

                    Spacer()

                    if alternative.validation == .eligible {
                        Menu("Use Candidate") {
                            pronunciationScopeButtons(
                                issue: issue,
                                candidateID: alternative.candidateID)
                        }
                        .controlSize(.small)
                        .disabled(applyingIssueID != nil)
                        .accessibilityLabel(
                            "Use pronunciation \(alternative.ipa) from \(alternative.source)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pronunciationScopeButtons(
        issue: NarrationQualityIssueRecord,
        candidateID: String?
    ) -> some View {
        if hasSourceOccurrence(issue) {
            Button("This Occurrence") {
                applyPronunciation(issue, candidateID: candidateID, scope: .occurrence)
            }
        }
        Button("This Book") {
            applyPronunciation(
                issue, candidateID: candidateID, scope: .book(issue.audiobookID))
        }
        Button("All Books") {
            applyPronunciation(issue, candidateID: candidateID, scope: .global)
        }
    }

    private func applyPronunciation(
        _ issue: NarrationQualityIssueRecord,
        candidateID: String?,
        scope: FixScope
    ) {
        applyingIssueID = issue.id
        Task { @MainActor in
            if let candidateID {
                await model.acceptCandidate(candidateID, for: issue, scope: scope)
            } else {
                await model.acceptFix(issue: issue, scope: scope)
            }
            applyingIssueID = nil
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

    private func hasSourceOccurrence(_ issue: NarrationQualityIssueRecord) -> Bool {
        issue.sourceBlockID != nil && issue.sourceWordStart != nil && issue.sourceWordEnd != nil
    }

    private func issueLabel(_ issue: NarrationQualityIssueRecord) -> String {
        if issue.origin == NarrationQualityIssueOrigin.acoustic.rawValue {
            return "Acoustic pronunciation review"
        }
        if issue.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue {
            return "Pronunciation review"
        }
        return issue.issueType
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

    private func issueTypeColor(_ type: String) -> Color {
        switch type {
        case "pronunciation": return .orange
        case "omission": return .red
        case "insertion": return .blue
        case "substitution": return .purple
        case "lowConfidence": return .gray
        default: return .secondary
        }
    }

    private func confidenceText(_ c: Double) -> String {
        String(format: "%.0f%%", c * 100)
    }
}
