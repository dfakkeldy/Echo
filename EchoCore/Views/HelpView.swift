// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HelpView: View {
    @Environment(SettingsManager.self) private var settings
    /// Topics open one at a time by tap; all start closed so the list of
    /// headings is the first thing to scan.
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(HelpContent.sections) { section in
                    // A DisclosureGroup: the trailing chevron turns down as
                    // the topic expands in place (it does not push a page).
                    DisclosureGroup(isExpanded: binding(for: section.id)) {
                        topicBody(section.body)
                            .padding(.vertical, 6)
                    } label: {
                        Label {
                            // Regular weight, like every other list row.
                            Text(section.title)
                                .customFont(.body, appFont: settings.appFont)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: Self.symbol(for: section.id))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Paragraphs in order. A paragraph that opens with a bold lead-in
    /// ("**Keeping files available offline:**") shows that lead-in as a
    /// sub-head on its own line, with space above, so long topics scan.
    private func topicBody(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(body).enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 4) {
                    if let heading = block.heading {
                        Text(heading)
                            .customFont(.subheadline, weight: .semibold, appFont: settings.appFont)
                            .foregroundStyle(.primary)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if !block.text.isEmpty {
                        Text(Self.rendered(block.text))
                            .customFont(.subheadline, appFont: settings.appFont)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineSpacing(4)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    struct HelpBlock: Equatable {
        var heading: String?
        var text: String
    }

    /// Splits a help body on blank lines and lifts a leading `**Lead-in:**`
    /// out as the block's heading (trailing colon dropped).
    static func blocks(_ body: String) -> [HelpBlock] {
        body.components(separatedBy: "\n\n").compactMap { raw in
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { return nil }
            guard paragraph.hasPrefix("**"),
                let close = paragraph.range(
                    of: "**", range: paragraph.index(paragraph.startIndex, offsetBy: 2)..<paragraph.endIndex)
            else {
                return HelpBlock(heading: nil, text: paragraph)
            }
            var heading = String(paragraph[paragraph.index(paragraph.startIndex, offsetBy: 2)..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Only a "Lead-in:" is a sub-head; other bold openers stay inline.
            guard heading.hasSuffix(":") else { return HelpBlock(heading: nil, text: paragraph) }
            heading.removeLast()
            let rest = String(paragraph[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return HelpBlock(heading: heading, text: rest)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    /// One SF Symbol per topic so the closed list scans by shape as well as
    /// by word. Unknown ids fall back to a neutral glyph.
    static func symbol(for id: String) -> String {
        switch id {
        case "loading": "folder"
        case "playback": "playpause"
        case "speed": "gauge.with.dots.needle.67percent"
        case "volume-boost": "speaker.wave.3"
        case "loop": "repeat"
        case "bookmarks": "bookmark"
        case "flashcards": "rectangle.on.rectangle.angled"
        case "sleep-timer": "moon.zzz"
        case "smart-rewind": "gobackward"
        case "epub-reader": "book"
        case "pdf": "doc.richtext"
        case "playlist": "list.bullet"
        case "watch": "applewatch"
        case "appearance": "gearshape"
        default: "questionmark.circle"
        }
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
