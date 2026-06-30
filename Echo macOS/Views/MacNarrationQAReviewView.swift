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

import GRDB
import SwiftUI

struct MacNarrationQAReviewView: View {
    @State private var model: NarrationQAReviewModel
    @State private var selectedIssueID: String?
    @State private var isRunning = false

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
                Text(issue.issueType)
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

            HStack(spacing: 8) {
                Spacer()
                Button("Ignore") {
                    model.ignore(issue)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if issue.suggestedFixJSON != nil {
                    Button("Save Override") {
                        Task {
                            await model.acceptFix(issue: issue, scope: .book(issue.audiobookID))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
