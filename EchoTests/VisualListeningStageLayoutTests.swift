// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite(.serialized)
struct VisualListeningStageLayoutTests {
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func longParagraphKeepsPictureVisibleAndTextScrollable(typeSize: DynamicTypeSize) async throws {
        let imageURL = try makeFigure()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let snapshot = makeSnapshot(imageURL: imageURL, wordIndex: 0)
        let window = try makeWindow()
        let previousKeyWindow = window.windowScene?.keyWindow
        let host = UIHostingController(rootView: stage(snapshot, typeSize: typeSize))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await settleLayout(window)

        let subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        #expect(subtitle.text == Self.paragraph)
        #expect(subtitle.isScrollEnabled)
        #expect(subtitle.contentSize.height > subtitle.bounds.height)
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: window)
        #expect(subtitleFrame.minY >= 0)
        #expect(subtitleFrame.maxY <= window.bounds.maxY)
        #expect(subtitleFrame.height < window.bounds.height / 2)
        #expect(
            magentaPixelCount(in: window) > 326 * 80,
            "The figure must retain visible space even when its paragraph is much taller than the stage."
        )
    }

    @Test func spokenWordStaysVisibleAfterSeekingAndChangingParagraph() async throws {
        let imageURL = try makeFigure()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let window = try makeWindow()
        let previousKeyWindow = window.windowScene?.keyWindow
        let host = UIHostingController(
            rootView: stage(makeSnapshot(imageURL: imageURL, wordIndex: 0)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await settleLayout(window)

        host.rootView = stage(makeSnapshot(imageURL: imageURL, wordIndex: 110))
        await settleLayout(window)
        var subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        #expect(subtitle.contentOffset.y > 0)
        expectWordVisible(110, in: subtitle)

        host.rootView = stage(
            makeSnapshot(imageURL: imageURL, wordIndex: 110), typeSize: .accessibility3)
        await settleLayout(window)
        subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        expectWordVisible(110, in: subtitle)

        host.rootView = stage(makeSnapshot(imageURL: imageURL, wordIndex: 0))
        await settleLayout(window)
        subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        expectWordVisible(0, in: subtitle)

        host.rootView = stage(makeSnapshot(imageURL: imageURL, wordIndex: 0, blockID: "next"))
        await settleLayout(window)
        subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        #expect(subtitle.contentOffset.y <= 1)
        expectWordVisible(0, in: subtitle)
    }

    @Test func codeListingAlsoKeepsItsOwnViewportAboveTheSubtitle() async throws {
        var snapshot = makeSnapshot(imageURL: URL(fileURLWithPath: "/unused"), wordIndex: 0)
        snapshot.visualCue = VisualListeningVisualCue(
            blockID: "code",
            content: .code(
                text: String(repeating: "let value = 42\n", count: 80), language: "swift"),
            caption: nil, subtitleBlockID: "paragraph", chapterIndex: 0, sequenceIndex: 0,
            displayStartTime: 0, displayEndTime: 100, syncPoint: .begin, source: .explicitTimeline)
        let window = try makeWindow()
        let previousKeyWindow = window.windowScene?.keyWindow
        let host = UIHostingController(rootView: stage(snapshot))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await settleLayout(window)

        let subtitle = try #require(
            descendants(of: window, ofType: UITextView.self).first { $0.text == Self.paragraph })
        let code = try #require(
            descendants(of: window, ofType: UIScrollView.self).first {
                !($0 is UITextView)
            })
        let subtitleFrame = subtitle.convert(subtitle.bounds, to: window)
        let codeFrame = code.convert(code.bounds, to: window)
        #expect(codeFrame.height > 100)
        #expect(codeFrame.maxY <= subtitleFrame.minY)
        #expect(subtitleFrame.maxY <= window.bounds.maxY)
    }

    private static let paragraph = (0..<140)
        .map { "A synthetic illustration accompanies spoken word \($0)." }
        .joined(separator: " ")

    private func makeSnapshot(
        imageURL: URL, wordIndex: Int, blockID: String = "paragraph"
    ) -> VisualListeningSnapshot {
        VisualListeningSnapshot(
            visualCue: VisualListeningVisualCue(
                blockID: "figure", content: .image(path: imageURL.path), caption: nil,
                subtitleBlockID: blockID, chapterIndex: 0, sequenceIndex: 0,
                displayStartTime: 0, displayEndTime: 100, syncPoint: .begin,
                source: .derivedFromNearbyText),
            subtitleCue: VisualListeningSubtitleCue(
                blockID: blockID, text: Self.paragraph, activeWordIndex: wordIndex,
                alreadyHeardWordCount: wordIndex),
            activeBlockID: blockID)
    }

    private func stage(
        _ snapshot: VisualListeningSnapshot, typeSize: DynamicTypeSize = .large
    ) -> AnyView {
        AnyView(
            VisualListeningStageView(
                snapshot: snapshot, syncPoint: .constant(.begin),
                appFont: SettingsManager.systemFontName
            )
            .frame(width: 326, height: 360)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.colorScheme, .light)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea())
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
                $0.activationState == .foregroundActive
            })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 326, height: 360)
        return window
    }

    private func settleLayout(_ window: UIWindow) async {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
    }

    private func expectWordVisible(_ index: Int, in textView: UITextView) {
        let range = NSRange(WordTokenizer.wordRanges(in: Self.paragraph)[index], in: Self.paragraph)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let glyphs = textView.layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        let rect = textView.layoutManager.boundingRect(
            forGlyphRange: glyphs, in: textView.textContainer
        )
        .offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
        #expect(rect.minY >= textView.bounds.minY - 1)
        #expect(rect.maxY <= textView.bounds.maxY + 1)
    }

    private func descendants<T: UIView>(of view: UIView, ofType: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: $0, ofType: ofType) }
    }

    private func makeFigure() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160)).image {
            context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    private func magentaPixelCount(in window: UIWindow) -> Int {
        let width = Int(window.bounds.width)
        let height = Int(window.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage,
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cgImage, in: window.bounds)
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 220 && pixels[$0 + 1] < 40 && pixels[$0 + 2] > 220
        }.count
    }
}
