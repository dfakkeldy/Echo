// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FeedbackSupportView: View {
    private let buildMetadata = AppBuildMetadata()

    var body: some View {
        Form {
            Section {
                Link(destination: FeedbackSupport.emailURL(buildMetadata: buildMetadata)) {
                    Label("Email Support", systemImage: "envelope")
                }

                Link(destination: FeedbackSupport.githubIssuesURL) {
                    Label("Open GitHub Issues", systemImage: "ladybug")
                }

                Link(destination: FeedbackSupport.manualURL) {
                    Label("Open Manual", systemImage: "book")
                }
            } footer: {
                Text(
                    "Email opens with Echo's version and commit already filled in. No logs, book paths, or listening data are attached."
                )
            }
        }
    }
}

#Preview {
    FeedbackSupportView()
}
