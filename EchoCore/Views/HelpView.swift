// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HelpView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(HelpContent.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(Self.rendered(section.body))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                }
            }
            .padding()
        }
        .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
    }

    /// Help bodies use inline markdown (`**Bold:**` lead-ins). A plain String
    /// in `Text` renders the asterisks literally, so parse it here and keep
    /// line breaks and bullet spacing as written.
    static func rendered(_ body: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}
