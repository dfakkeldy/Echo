// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Per-book narration-QA review list: each row shows the source text, what the
/// transcriber heard, the issue label, and ignore/resolve actions. Override +
/// regenerate actions arrive in M4. iOS-only (excluded from macOS/echo-cli).
struct NarrationQAReviewView: View {
    @State private var model: NarrationQAReviewModel

    init(model: NarrationQAReviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
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
                    }
                    .swipeActions {
                        Button("Resolve") { model.markResolved(issue) }.tint(.green)
                        Button("Ignore", role: .destructive) { model.ignore(issue) }
                    }
                }
            }
        }
        .navigationTitle("Narration QA")
        .onAppear { model.load() }
    }
}
