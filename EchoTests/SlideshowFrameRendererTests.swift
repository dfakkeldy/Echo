// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import Echo

struct SlideshowFrameRendererTests {
    // MARK: - Frame + fixture helpers

    private func frame(
        subtitle: String? = "Hello world of tests",
        activeWord: Int? = nil, heard: Int = 0,
        visual: VisualListeningVisualContent? = nil,
        caption: String? = "A caption"
    ) -> SlideshowFramePlan {
        SlideshowFramePlan(
            startTime: 0, duration: 1,
            visualContent: visual, caption: caption,
            subtitleText: subtitle, activeWordIndex: activeWord,
            alreadyHeardWordCount: heard)
    }

    /// Exact frame bytes (premultiplied-last sRGB) for equality/inequality checks.
    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.height * context.bytesPerRow)
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.2, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private static func splitImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()
    }

    private static func orientedTIFF(
        _ image: CGImage, orientation: UInt32
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).tiff")
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, "public.tiff" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - Raster analysis

    /// Decoded RGBA pixels with a background reference taken from the top-left
    /// corner (always in the outer margin). Memory rows run top-to-bottom; CG
    /// coordinates are bottom-left, so `cgPoint` flips the row.
    private struct Raster {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init(_ image: CGImage) {
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let count = image.width * image.height * 4
            bytes = [UInt8](
                UnsafeBufferPointer(
                    start: context.data!.assumingMemoryBound(to: UInt8.self), count: count))
            width = image.width
            height = image.height
        }

        private var backgroundRGB: (Int, Int, Int) {
            (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }

        private func isBackground(_ offset: Int) -> Bool {
            let bg = backgroundRGB
            return abs(Int(bytes[offset]) - bg.0)
                + abs(Int(bytes[offset + 1]) - bg.1)
                + abs(Int(bytes[offset + 2]) - bg.2) <= 12
        }

        private func isBright(_ offset: Int) -> Bool {
            bytes[offset] > 150 && bytes[offset + 1] > 150 && bytes[offset + 2] > 150
        }

        private func cgY(row: Int) -> CGFloat { CGFloat(height - row) - 0.5 }
        private func cgX(col: Int) -> CGFloat { CGFloat(col) + 0.5 }

        /// Any non-background pixel whose center falls inside `rect`.
        func hasContent(in rect: CGRect) -> Bool {
            for row in 0..<height {
                let y = cgY(row: row)
                if y < rect.minY || y > rect.maxY { continue }
                let base = row * width * 4
                for col in 0..<width {
                    let x = cgX(col: col)
                    if x < rect.minX || x > rect.maxX { continue }
                    if !isBackground(base + col * 4) { return true }
                }
            }
            return false
        }

        /// Every pixel whose center is outside all `rects` (expanded 1.5px for
        /// anti-aliasing slack) must be background.
        func onlyBackgroundOutside(_ rects: [CGRect]) -> Bool {
            let expanded = rects.map { $0.insetBy(dx: -1.5, dy: -1.5) }
            for row in 0..<height {
                let y = cgY(row: row)
                let base = row * width * 4
                for col in 0..<width {
                    let point = CGPoint(x: cgX(col: col), y: y)
                    if expanded.contains(where: { $0.contains(point) }) { continue }
                    if !isBackground(base + col * 4) { return false }
                }
            }
            return true
        }

        /// Bounding box (CG coordinates) of all non-background pixels.
        func nonBackgroundBox() -> CGRect? {
            var minCol = width
            var maxCol = -1
            var minRow = height
            var maxRow = -1
            for row in 0..<height {
                let base = row * width * 4
                for col in 0..<width where !isBackground(base + col * 4) {
                    minCol = min(minCol, col)
                    maxCol = max(maxCol, col)
                    minRow = min(minRow, row)
                    maxRow = max(maxRow, row)
                }
            }
            guard maxCol >= 0 else { return nil }
            let left = cgX(col: minCol)
            let right = cgX(col: maxCol)
            let top = cgY(row: minRow)  // topmost row = highest CG-y
            let bottom = cgY(row: maxRow)
            return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }

        /// Rightmost bright (code-text) pixel center inside `rect`, if any.
        func rightmostBrightX(in rect: CGRect) -> CGFloat? {
            var maxCol = -1
            for row in 0..<height {
                let y = cgY(row: row)
                if y < rect.minY || y > rect.maxY { continue }
                let base = row * width * 4
                for col in 0..<width {
                    let x = cgX(col: col)
                    if x < rect.minX || x > rect.maxX { continue }
                    if isBright(base + col * 4) { maxCol = max(maxCol, col) }
                }
            }
            return maxCol >= 0 ? cgX(col: maxCol) : nil
        }
    }

    private func diffPixelCount(_ a: Raster, _ b: Raster) -> Int {
        guard a.bytes.count == b.bytes.count else { return max(a.bytes.count, b.bytes.count) }
        var count = 0
        var i = 0
        while i < a.bytes.count {
            if a.bytes[i] != b.bytes[i] || a.bytes[i + 1] != b.bytes[i + 1]
                || a.bytes[i + 2] != b.bytes[i + 2] || a.bytes[i + 3] != b.bytes[i + 3]
            {
                count += 1
            }
            i += 4
        }
        return count
    }

    // MARK: - Exact output size

    @Test func rendersLandscapeAtExactSize() throws {
        let renderer = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        let image = try #require(renderer.render(frame()))
        #expect(image.width == 1920)
        #expect(image.height == 1080)
    }

    @Test func rendersPortraitAtExactSize() throws {
        let renderer = SlideshowFrameRenderer(dimensions: .portrait, coverArt: nil)
        let image = try #require(renderer.render(frame()))
        #expect(image.width == 1080)
        #expect(image.height == 1920)
    }

    @Test func rendersValidatedCustomSize() throws {
        let renderer = SlideshowFrameRenderer(
            dimensions: try SlideshowVideoDimensions.validating(width: 640, height: 360),
            coverArt: nil)
        let image = try #require(renderer.render(frame()))
        #expect(image.width == 640)
        #expect(image.height == 360)
    }

    @Test func renderedFrameIsNotBlank() throws {
        let renderer = SlideshowFrameRenderer(
            dimensions: try SlideshowVideoDimensions.validating(width: 320, height: 180),
            coverArt: nil)
        let image = try #require(renderer.render(frame()))
        #expect(Set(pixels(image)).count > 2)  // background + at least one text shade
    }

    // MARK: - Legacy no-drift pixel parity (1920x1080)

    @Test func legacyLandscapeImageSimpleSubtitleParity() throws {
        let figure = try #require(Self.solidImage(width: 40, height: 40))
        let loader: @Sendable (String) -> CGImage? = { _ in figure }
        let production = SlideshowFrameRenderer(
            dimensions: .landscape, coverArt: nil, imageLoader: loader)
        let reference = LegacyLandscapeFrameReferenceRenderer(
            width: 1920, height: 1080, coverArt: nil, imageLoader: loader)
        let sample = frame(
            subtitle: "Hello world of tests", activeWord: nil, heard: 0,
            visual: .image(path: "/fixture/legacy.png"), caption: "A caption")

        let produced = try #require(production.render(sample))
        let expected = try #require(reference.render(sample))
        #expect(pixels(produced) == pixels(expected))
    }

    @Test func legacyLandscapeKaraokeParity() throws {
        let figure = try #require(Self.solidImage(width: 40, height: 40))
        let loader: @Sendable (String) -> CGImage? = { _ in figure }
        let production = SlideshowFrameRenderer(
            dimensions: .landscape, coverArt: nil, imageLoader: loader)
        let reference = LegacyLandscapeFrameReferenceRenderer(
            width: 1920, height: 1080, coverArt: nil, imageLoader: loader)
        let sample = frame(
            subtitle: "Hello world of tests", activeWord: 1, heard: 1,
            visual: .image(path: "/fixture/legacy.png"), caption: "A caption")

        let produced = try #require(production.render(sample))
        let expected = try #require(reference.render(sample))
        #expect(pixels(produced) == pixels(expected))
    }

    // MARK: - Subtitle emphasis

    @Test func activeWordChangesThePixels() throws {
        let renderer = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        let a = try #require(renderer.render(frame(activeWord: 0, heard: 0)))
        let b = try #require(renderer.render(frame(activeWord: 2, heard: 0)))
        #expect(pixels(a) != pixels(b))
    }

    @Test func baseHeardAndActiveAreThreeDistinctStates() throws {
        let renderer = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        // Word 0 in three states while a later word (3) stays active/valid.
        let base = try #require(renderer.render(frame(activeWord: 3, heard: 0)))
        let heardWord = try #require(renderer.render(frame(activeWord: 3, heard: 1)))
        let activeWord = try #require(renderer.render(frame(activeWord: 0, heard: 0)))
        #expect(pixels(base) != pixels(heardWord))  // heard wash is visible
        #expect(pixels(heardWord) != pixels(activeWord))  // heard != active styling
        #expect(pixels(base) != pixels(activeWord))
    }

    @Test func karaokePageMembershipIsStableAcrossActiveWord() throws {
        let dimensions = SlideshowVideoDimensions.landscape
        let layout = SlideshowFrameLayout(dimensions: dimensions)
        let subtitle = (0..<300).map { "w\($0)" }.joined(separator: " ")
        // The renderer paginates an overflowing subtitle at the minimum size.
        let pages = SlideshowTextFitter.karaokePages(
            for: subtitle, in: layout.subtitleRect,
            fontSize: layout.minimumSubtitleFontSize,
            maximumLineCount: layout.subtitleLineLimit)
        try #require(pages.count >= 2)
        let firstPage = try #require(pages.first { $0.sourceWordRange.count >= 2 })
        let sameA = firstPage.sourceWordRange.lowerBound
        let sameB = sameA + 1
        let otherPage = try #require(pages.first { $0.sourceWordRange.lowerBound > sameB })
        let differentPageWord = otherPage.sourceWordRange.lowerBound

        let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
        let a = Raster(
            try #require(renderer.render(frame(subtitle: subtitle, activeWord: sameA))))
        let b = Raster(
            try #require(renderer.render(frame(subtitle: subtitle, activeWord: sameB))))
        let other = Raster(
            try #require(
                renderer.render(frame(subtitle: subtitle, activeWord: differentPageWord))))

        let samePageDiff = diffPixelCount(a, b)
        let crossPageDiff = diffPixelCount(a, other)
        #expect(samePageDiff > 0)  // emphasis moved
        // Two active words on the same page only re-style two words; crossing to a
        // different page swaps the entire displayed text, changing far more pixels.
        #expect(crossPageDiff > samePageDiff * 4)
    }

    @Test func activeWordIsVisibleOnItsOwnPage() throws {
        let dimensions = SlideshowVideoDimensions.landscape
        let layout = SlideshowFrameLayout(dimensions: dimensions)
        let subtitle = (0..<300).map { "w\($0)" }.joined(separator: " ")
        let pages = SlideshowTextFitter.karaokePages(
            for: subtitle, in: layout.subtitleRect,
            fontSize: layout.minimumSubtitleFontSize,
            maximumLineCount: layout.subtitleLineLimit)
        try #require(pages.count >= 2)
        let early = pages.first!.sourceWordRange.lowerBound
        let late = pages.last!.sourceWordRange.lowerBound

        let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
        let earlyFrame = Raster(
            try #require(renderer.render(frame(subtitle: subtitle, activeWord: early))))
        let lateFrame = Raster(
            try #require(renderer.render(frame(subtitle: subtitle, activeWord: late))))
        #expect(earlyFrame.hasContent(in: layout.subtitleRect))
        #expect(lateFrame.hasContent(in: layout.subtitleRect))
        // Selecting the page that contains the active word yields a different
        // displayed window than a far-away active word.
        #expect(diffPixelCount(earlyFrame, lateFrame) > 0)
    }

    // MARK: - Image + cover fallback

    @Test func unreadableImageFallsBackToCoverArt() throws {
        let cover = try #require(Self.solidImage(width: 4, height: 4))
        let withCover = SlideshowFrameRenderer(dimensions: .landscape, coverArt: cover)
        let withoutCover = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        let missing = frame(
            subtitle: nil, visual: .image(path: "/nowhere/gone-book/x.jpg"), caption: nil)
        let fallback = try #require(withCover.render(missing))
        let blank = try #require(withoutCover.render(missing))
        #expect(pixels(fallback) != pixels(blank))
        #expect(
            Raster(fallback).hasContent(in: SlideshowFrameLayout(dimensions: .landscape).figureRect)
        )
    }

    @Test func noActiveVisualUsesCoverArt() throws {
        let cover = try #require(Self.solidImage(width: 8, height: 8))
        let layout = SlideshowFrameLayout(dimensions: .landscape)
        let withCover = SlideshowFrameRenderer(dimensions: .landscape, coverArt: cover)
        let withoutCover = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        let noVisual = frame(subtitle: nil, visual: nil, caption: nil)
        #expect(Raster(try #require(withCover.render(noVisual))).hasContent(in: layout.figureRect))
        // Without cover art the figure region stays dark.
        #expect(
            !Raster(try #require(withoutCover.render(noVisual))).hasContent(in: layout.figureRect))
    }

    @Test func appliesRotatedAndMirroredImageOrientationMetadata() throws {
        let source = try #require(Self.splitImage(width: 40, height: 100))
        let uprightURL = try Self.orientedTIFF(source, orientation: 1)
        let rotatedURL = try Self.orientedTIFF(source, orientation: 6)
        let mirroredURL = try Self.orientedTIFF(source, orientation: 7)
        defer {
            try? FileManager.default.removeItem(at: uprightURL)
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.removeItem(at: mirroredURL)
        }

        let renderer = SlideshowFrameRenderer(
            dimensions: try SlideshowVideoDimensions.validating(width: 200, height: 200),
            coverArt: nil)
        let upright = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .image(path: uprightURL.path), caption: nil)))
        let rotated = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .image(path: rotatedURL.path), caption: nil)))
        let mirrored = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .image(path: mirroredURL.path), caption: nil)))
        #expect(pixels(upright) != pixels(rotated))
        #expect(pixels(rotated) != pixels(mirrored))
    }

    // MARK: - Aspect fit (uncropped) at both presets

    private func assertAspectFit(
        dimensions: SlideshowVideoDimensions, imageWidth: Int, imageHeight: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let image = try #require(Self.solidImage(width: imageWidth, height: imageHeight))
        let renderer = SlideshowFrameRenderer(
            dimensions: dimensions, coverArt: nil, imageLoader: { _ in image })
        let rendered = Raster(
            try #require(
                renderer.render(frame(subtitle: nil, visual: .image(path: "x"), caption: nil))))
        let box = try #require(rendered.nonBackgroundBox(), sourceLocation: sourceLocation)
        let figure = SlideshowFrameLayout(dimensions: dimensions).figureRect
        let scale = min(figure.width / CGFloat(imageWidth), figure.height / CGFloat(imageHeight))
        let expectedWidth = CGFloat(imageWidth) * scale
        let expectedHeight = CGFloat(imageHeight) * scale

        // Preserved aspect ratio => no stretch/crop.
        #expect(
            abs(box.width / box.height - CGFloat(imageWidth) / CGFloat(imageHeight)) < 0.08,
            "aspect drift", sourceLocation: sourceLocation)
        // Contained inside the figure region => no overflow.
        #expect(box.minX >= figure.minX - 2, "left overflow", sourceLocation: sourceLocation)
        #expect(box.maxX <= figure.maxX + 2, "right overflow", sourceLocation: sourceLocation)
        #expect(box.minY >= figure.minY - 2, "bottom overflow", sourceLocation: sourceLocation)
        #expect(box.maxY <= figure.maxY + 2, "top overflow", sourceLocation: sourceLocation)
        // Maximally scaled => one dimension fills the region.
        #expect(
            max(box.width / figure.width, box.height / figure.height) > 0.9,
            "not fitted", sourceLocation: sourceLocation)
        #expect(abs(box.width - expectedWidth) < 6, "width", sourceLocation: sourceLocation)
        #expect(abs(box.height - expectedHeight) < 6, "height", sourceLocation: sourceLocation)
    }

    @Test func aspectFitUncroppedLandscapePreset() throws {
        try assertAspectFit(dimensions: .landscape, imageWidth: 40, imageHeight: 100)  // portrait
        try assertAspectFit(dimensions: .landscape, imageWidth: 100, imageHeight: 40)  // landscape
        try assertAspectFit(dimensions: .landscape, imageWidth: 50, imageHeight: 50)  // square
    }

    @Test func aspectFitUncroppedPortraitPreset() throws {
        try assertAspectFit(dimensions: .portrait, imageWidth: 40, imageHeight: 100)  // portrait
        try assertAspectFit(dimensions: .portrait, imageWidth: 100, imageHeight: 40)  // landscape
        try assertAspectFit(dimensions: .portrait, imageWidth: 50, imageHeight: 50)  // square
    }

    // MARK: - Code cards

    @Test func codeCardWithLanguageDiffersFromWithout() throws {
        for dimensions in [SlideshowVideoDimensions.landscape, .portrait] {
            let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
            let source = "let x = 1\nprint(x)"
            let withLanguage = try #require(
                renderer.render(
                    frame(
                        subtitle: nil, visual: .code(text: source, language: "swift"), caption: nil)
                ))
            let withoutLanguage = try #require(
                renderer.render(
                    frame(subtitle: nil, visual: .code(text: source, language: nil), caption: nil)))
            #expect(pixels(withLanguage) != pixels(withoutLanguage))
            let figure = SlideshowFrameLayout(dimensions: dimensions).figureRect
            #expect(Raster(withLanguage).hasContent(in: figure))
            #expect(Raster(withoutLanguage).hasContent(in: figure))
        }
    }

    @Test func codeCardFillsFigureAndSuppressesCaption() throws {
        let dimensions = SlideshowVideoDimensions.landscape
        let layout = SlideshowFrameLayout(dimensions: dimensions)
        let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
        let narration = "Listing one shows the loop"

        let codeFrame = Raster(
            try #require(
                renderer.render(
                    frame(
                        subtitle: narration,
                        visual: .code(text: "for i in 0..<3 {\n  print(i)\n}", language: "swift"),
                        caption: "Listing one"))))
        // Figure region carries the code card; subtitle carries the narration once.
        #expect(codeFrame.hasContent(in: layout.figureRect))
        #expect(codeFrame.hasContent(in: layout.subtitleRect))
        // Caption region is deliberately left empty for code cues.
        #expect(!codeFrame.hasContent(in: layout.captionRect.insetBy(dx: 4, dy: 4)))

        // A non-code cue with the same caption DOES render the caption.
        let imageFrame = Raster(
            try #require(
                renderer.render(frame(subtitle: narration, visual: nil, caption: "Listing one"))))
        #expect(imageFrame.hasContent(in: layout.captionRect.insetBy(dx: 4, dy: 4)))
    }

    @Test func longCodeLineIsTruncatedContainedAndDeterministic() throws {
        let dimensions = SlideshowVideoDimensions.landscape
        let layout = SlideshowFrameLayout(dimensions: dimensions)
        let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
        let shortPrefix = String(repeating: "a", count: 400)
        let longer = shortPrefix + String(repeating: "a", count: 400)

        let a = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .code(text: shortPrefix, language: nil), caption: nil))
        )
        let b = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .code(text: longer, language: nil), caption: nil)))
        // Both overflow and truncate to the same visible prefix + ellipsis.
        #expect(pixels(a) == pixels(b))
        // The truncated line stays inside the code content width.
        let content = layout.codeContentRect(hasLanguageLabel: false)
        let rightmost = try #require(Raster(a).rightmostBrightX(in: layout.figureRect))
        #expect(rightmost <= content.maxX + 1.5)
    }

    @Test func excessiveCodeLinesAreVerticallyTruncatedDeterministically() throws {
        let dimensions = SlideshowVideoDimensions.landscape
        let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
        let firstBlock = (0..<200).map { "line\($0)" }
        let a = firstBlock.joined(separator: "\n")
        let b = (firstBlock + (200..<400).map { "line\($0)" }).joined(separator: "\n")

        let renderedA = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .code(text: a, language: nil), caption: nil)))
        let renderedB = try #require(
            renderer.render(
                frame(subtitle: nil, visual: .code(text: b, language: nil), caption: nil)))
        // Off-screen source lines cannot change the visible window (shared prefix +
        // a final ellipsis row).
        #expect(pixels(renderedA) == pixels(renderedB))
    }

    @Test func differentCodePayloadsDoNotReuseBase() throws {
        let renderer = SlideshowFrameRenderer(dimensions: .landscape, coverArt: nil)
        let a = try #require(
            renderer.render(
                frame(
                    subtitle: "same", visual: .code(text: "let a = 1", language: nil), caption: nil)
            ))
        let b = try #require(
            renderer.render(
                frame(
                    subtitle: "same", visual: .code(text: "let b = 2", language: nil), caption: nil)
            ))
        // If the base were reused across differing code payloads, b would show a's
        // card and the pixels would be identical.
        #expect(pixels(a) != pixels(b))
    }

    // MARK: - Bounded caption + simple subtitle

    @Test func longCaptionAndSubtitleStayBoundedAndVisible() throws {
        for dimensions in [SlideshowVideoDimensions.landscape, .portrait] {
            let layout = SlideshowFrameLayout(dimensions: dimensions)
            let renderer = SlideshowFrameRenderer(dimensions: dimensions, coverArt: nil)
            let longCaption = String(
                repeating: "An extraordinarily long caption that cannot fit. ", count: 12)
            let longSubtitle = String(
                repeating: "an unusually long simple subtitle line ", count: 20)
            let rendered = Raster(
                try #require(
                    renderer.render(
                        frame(
                            subtitle: longSubtitle, activeWord: nil, visual: nil,
                            caption: longCaption))))
            // Bounded fitting keeps content drawn inside its own region...
            #expect(rendered.hasContent(in: layout.captionRect))
            #expect(rendered.hasContent(in: layout.subtitleRect))
            // ...and never paints outside the declared regions.
            #expect(
                rendered.onlyBackgroundOutside([
                    layout.subtitleRect, layout.captionRect, layout.figureRect,
                ]))
        }
    }

    // MARK: - Region containment

    @Test func everyRegionDrawsInsideItsDeclaredRect() throws {
        let figureImage = try #require(Self.solidImage(width: 60, height: 40))
        for dimensions in [SlideshowVideoDimensions.landscape, .portrait] {
            let layout = SlideshowFrameLayout(dimensions: dimensions)
            let renderer = SlideshowFrameRenderer(
                dimensions: dimensions, coverArt: nil, imageLoader: { _ in figureImage })
            let rendered = Raster(
                try #require(
                    renderer.render(
                        frame(
                            subtitle: "Hello world of tests", activeWord: 1, heard: 1,
                            visual: .image(path: "/fixture/inside.png"), caption: "A caption"))))
            #expect(
                rendered.onlyBackgroundOutside([
                    layout.subtitleRect, layout.captionRect, layout.figureRect,
                ]))
        }
    }

    // MARK: - Base-frame caching

    @Test func reusesBaseFrameWhenOnlySubtitleStateChanges() throws {
        let figure = try #require(Self.solidImage(width: 40, height: 40))
        let loadCount = Mutex(0)
        let renderer = SlideshowFrameRenderer(
            dimensions: .landscape,
            coverArt: nil,
            imageLoader: { _ in
                loadCount.withLock { $0 += 1 }
                return figure
            })

        let first = try #require(
            renderer.render(
                frame(
                    subtitle: "First subtitle state", activeWord: 0, heard: 0,
                    visual: .image(path: "/fixture/same-image.png"), caption: "Same caption")))
        let second = try #require(
            renderer.render(
                frame(
                    subtitle: "Second subtitle state", activeWord: 1, heard: 1,
                    visual: .image(path: "/fixture/same-image.png"), caption: "Same caption")))

        #expect(pixels(first) != pixels(second))
        #expect(loadCount.withLock { $0 } == 1)
    }
}
