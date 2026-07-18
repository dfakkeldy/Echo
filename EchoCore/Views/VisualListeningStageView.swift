// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
import SwiftUI
import UIKit

struct VisualListeningStageView: View {
    let snapshot: VisualListeningSnapshot
    @Binding var syncPoint: VisualListeningSyncPoint
    let appFont: String

    @State private var image: UIImage?
    @State private var loadedImagePath: String?

    var body: some View {
        VStack(spacing: 12) {
            visualStage
                .overlay(alignment: .bottom) {
                    if !isCodeVisual, let subtitleCue = snapshot.subtitleCue {
                        VisualListeningSubtitleView(cue: subtitleCue, appFont: appFont)
                            .padding(12)
                    }
                }

            Picker("Image timing", selection: $syncPoint) {
                Text("Begin").tag(VisualListeningSyncPoint.begin)
                Text("Middle").tag(VisualListeningSyncPoint.midpoint)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Image timing"))
        }
        .onAppear(perform: loadImageIfNeeded)
        .onChange(of: snapshot.visualCue?.imagePath) { _, _ in
            loadImageIfNeeded()
        }
        .accessibilityElement(children: .contain)
    }

    private var visualStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if case .code(let text, _) = snapshot.visualCue?.content {
                VisualListeningCodeView(
                    text: text,
                    subtitleCue: snapshot.subtitleCue,
                    appFont: appFont
                )
            } else if let image {
                Image(uiImage: image)
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
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.25), value: snapshot.visualCue?.id)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var isCodeVisual: Bool {
        if case .code = snapshot.visualCue?.content { return true }
        return false
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

    private func loadImageIfNeeded() {
        guard let imagePath = snapshot.visualCue?.imagePath else {
            image = nil
            loadedImagePath = nil
            return
        }
        guard imagePath != loadedImagePath else { return }
        loadedImagePath = imagePath
        image = visualListeningImage(at: imagePath)
    }

    private func visualListeningImage(at imagePath: String) -> UIImage? {
        guard let url = VisualListeningImageLocator.resolvedURL(forStoredPath: imagePath)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

private struct VisualListeningCodeView: View {
    let text: String
    let subtitleCue: VisualListeningSubtitleCue?
    let appFont: String

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let subtitleCue {
                VisualListeningSubtitleView(cue: subtitleCue, appFont: appFont)
                    .padding(12)
            }
        }
    }
}

private struct VisualListeningSubtitleView: View {
    let cue: VisualListeningSubtitleCue
    let appFont: String

    var body: some View {
        Text(attributedSubtitle)
            .customFont(.headline, weight: .semibold, appFont: appFont)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
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
                subtitle[attributedRange].foregroundColor = .primary.opacity(0.72)
            } else {
                subtitle[attributedRange].foregroundColor = .secondary
            }
        }

        return subtitle
    }
}
#endif
