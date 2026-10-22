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
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        visualStage

                        if let subtitleCue = snapshot.subtitleCue {
                            VisualListeningSubtitleView(cue: subtitleCue, appFont: appFont)
                                .frame(height: geometry.size.height * 0.42)
                                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                                .clipShape(.rect(cornerRadius: 12))
                        }
                    }
                }

                Picker("Visual timing", selection: $syncPoint) {
                    Text("Begin").tag(VisualListeningSyncPoint.begin)
                    Text("Middle").tag(VisualListeningSyncPoint.midpoint)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(Text("Visual timing"))
            }
            .task(id: snapshot.visualCue?.id) {
                await loadImageIfNeeded()
            }
            .accessibilityElement(children: .contain)
        }

        private var visualStage: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                if case .code(let text, _) = snapshot.visualCue?.content {
                    VisualListeningCodeView(text: text)
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
            image = nil
            loadedImagePath = nil
            guard let path = snapshot.visualCue?.imagePath else { return }
            let decoded = await ReaderImageLoader.shared.image(storedPath: path)
            guard !Task.isCancelled, snapshot.visualCue?.imagePath == path, let decoded else {
                return
            }
            loadedImagePath = path
            image = UIImage(cgImage: decoded)
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
#endif
