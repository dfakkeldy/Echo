// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MacVisualStageView: View {
    let snapshot: VisualListeningSnapshot
    @Binding var syncPoint: VisualListeningSyncPoint
    let folderURL: URL?
    let appFont: String

    @State private var cgImage: CGImage?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            visualStage

            VStack(alignment: .leading, spacing: 12) {
                if let subtitleCue = snapshot.subtitleCue {
                    MacVisualSubtitleView(cue: subtitleCue, appFont: appFont)
                }

                Picker("Visual timing", selection: $syncPoint) {
                    Text("Begin").tag(VisualListeningSyncPoint.begin)
                    Text("Middle").tag(VisualListeningSyncPoint.midpoint)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel(Text("Visual timing"))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 320, alignment: .topLeading)
        }
        .task(id: snapshot.visualCue?.imagePath) {
            await loadImageIfNeeded()
        }
        .accessibilityElement(children: .contain)
    }

    private var visualStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.07))

            if case .code(let text, _) = snapshot.visualCue?.content {
                VisualListeningCodeView(text: text)
            } else if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.25), value: snapshot.visualCue?.id)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        let isCode: Bool
        if case .code = snapshot.visualCue?.content { isCode = true } else { isCode = false }
        if let caption = snapshot.visualCue?.caption, !caption.isEmpty {
            return isCode
                ? String(localized: "Current code listing: \(caption)")
                : String(localized: "Current figure: \(caption)")
        }
        if isCode { return String(localized: "Current code listing") }
        if let subtitle = snapshot.subtitleCue?.text, !subtitle.isEmpty {
            return String(localized: "Current figure for subtitle: \(subtitle)")
        }
        return String(localized: "Current figure")
    }

    private func loadImageIfNeeded() async {
        guard let resolvedURL = visualListeningImageURL() else {
            cgImage = nil
            return
        }
        cgImage = await MacImageDecode.loadCGImage(url: resolvedURL, maxPixelSize: 1600)
    }

    /// Resolves the on-disk location for the current cue's image path (either
    /// a direct path or one relative to the book's `EPUBAssets` folder). Only
    /// does cheap existence checks — the actual read + decode happens off-main
    /// in `MacImageDecode`.
    private func visualListeningImageURL() -> URL? {
        guard let imagePath = snapshot.visualCue?.imagePath else { return nil }
        if FileManager.default.fileExists(atPath: imagePath) {
            return URL(fileURLWithPath: imagePath)
        }

        guard let folderURL else { return nil }
        let assetsDir = SafeFileName.fromAudiobookID(folderURL.absoluteString)
        let resolvedURL =
            folderURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDir)
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent(imagePath)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return nil }
        return resolvedURL
    }
}

private struct VisualListeningCodeView: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(Text("Code listing"))
        .accessibilityValue(Text(text))
    }
}

private struct MacVisualSubtitleView: View {
    let cue: VisualListeningSubtitleCue
    let appFont: String

    var body: some View {
        Text(attributedSubtitle)
            .customFont(.headline, weight: .semibold, appFont: appFont)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .accessibilityLabel(Text("Subtitle: \(cue.text)"))
    }

    private var attributedSubtitle: AttributedString {
        var subtitle = AttributedString(cue.text)
        let ranges = WordTokenizer.wordRanges(in: cue.text)

        for (index, range) in ranges.enumerated() {
            guard let lower = AttributedString.Index(range.lowerBound, within: subtitle),
                let upper = AttributedString.Index(range.upperBound, within: subtitle)
            else { continue }

            let attributedRange = lower..<upper
            if cue.activeWordIndex == index {
                subtitle[attributedRange].foregroundColor = .primary
            } else if index < cue.alreadyHeardWordCount {
                subtitle[attributedRange].foregroundColor = .primary.opacity(0.76)
            } else {
                subtitle[attributedRange].foregroundColor = .secondary
            }
        }

        return subtitle
    }
}
