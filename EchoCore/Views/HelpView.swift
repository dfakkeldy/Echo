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
                    DisclosureGroup(isExpanded: binding(for: section.id)) {
                        Text(Self.rendered(section.body))
                            .customFont(.subheadline, appFont: settings.appFont)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    } label: {
                        Label {
                            Text(section.title)
                                .customFont(.body, weight: .semibold, appFont: settings.appFont)
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
