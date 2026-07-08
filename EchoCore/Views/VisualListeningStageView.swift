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
                    if let subtitleCue = snapshot.subtitleCue {
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
        .onChange(of: snapshot.imageCue?.imagePath) { _, _ in
            loadImageIfNeeded()
        }
        .accessibilityElement(children: .contain)
    }

    private var visualStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if let image {
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
        .animation(.easeInOut(duration: 0.25), value: snapshot.imageCue?.id)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        if let caption = snapshot.imageCue?.caption, !caption.isEmpty {
            return String(localized: "Current figure: \(caption)")
        }
        if let subtitle = snapshot.subtitleCue?.text, !subtitle.isEmpty {
            return String(localized: "Current figure for subtitle: \(subtitle)")
        }
        return String(localized: "Current figure")
    }

    private func loadImageIfNeeded() {
        guard let imagePath = snapshot.imageCue?.imagePath else {
            image = nil
            loadedImagePath = nil
            return
        }
        guard imagePath != loadedImagePath else { return }
        loadedImagePath = imagePath
        image = visualListeningImage(at: imagePath)
    }

    private func visualListeningImage(at imagePath: String) -> UIImage? {
        var url = URL(fileURLWithPath: imagePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let filename = url.lastPathComponent
            let dirName = url.deletingLastPathComponent().lastPathComponent
            url = FileLocations.applicationSupportDirectory
                .appendingPathComponent("EPUBAssets")
                .appendingPathComponent(dirName)
                .appendingPathComponent(filename)
        }
        return UIImage(contentsOfFile: url.path)
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
