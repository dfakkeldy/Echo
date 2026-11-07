// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FeedbackSupportView: View {
    private let buildMetadata = AppBuildMetadata()
    @State private var showingFeedbackForm = false

    var body: some View {
        Form {
            #if os(iOS)
                // The in-app form (rating, category, optional diagnostics)
                // lives here so Support has one entry in root Settings.
                Section {
                    Button {
                        showingFeedbackForm = true
                    } label: {
                        Label("Send Feedback", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
            #endif
            Section {
                // Each row leaves Echo (Mail or the browser), so each carries
                // a trailing arrow.up.right.
                Link(destination: FeedbackSupport.emailURL(buildMetadata: buildMetadata)) {
                    ExternalLinkRow(title: "Email Support", systemImage: "envelope")
                }

                Link(destination: FeedbackSupport.githubIssuesURL) {
                    ExternalLinkRow(title: "Open GitHub Issues", systemImage: "ladybug")
                }

                Link(destination: FeedbackSupport.manualURL) {
                    ExternalLinkRow(title: "Open Manual", systemImage: "book")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Email opens with Echo's version and commit already filled in. No logs, book paths, or listening data are attached."
                    )
                    // Show the facts the email will carry.
                    Text("Version \(buildMetadata.versionString) · \(buildMetadata.commitString)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                .settingsFooterStyle()
            }
        }
        #if os(iOS)
            .sheet(isPresented: $showingFeedbackForm) {
                FeedbackFormView()
            }
        #endif
    }
}

private struct ExternalLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    FeedbackSupportView()
}
