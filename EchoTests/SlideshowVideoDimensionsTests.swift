// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct SlideshowVideoDimensionsTests {
    // MARK: - Presets

    @Test func landscapePresetHasExpectedDimensionsAndProfile() {
        #expect(SlideshowVideoDimensions.landscape.width == 1920)
        #expect(SlideshowVideoDimensions.landscape.height == 1080)
        #expect(SlideshowVideoDimensions.landscape.layoutProfile == .legacyLandscape)
    }

    @Test func portraitPresetHasExpectedDimensionsAndProfile() {
        #expect(SlideshowVideoDimensions.portrait.width == 1080)
        #expect(SlideshowVideoDimensions.portrait.height == 1920)
        #expect(SlideshowVideoDimensions.portrait.layoutProfile == .phonePortrait)
    }

    @Test func formatDimensionsMatchPresets() {
        #expect(SlideshowVideoFormat.landscape.dimensions == .landscape)
        #expect(SlideshowVideoFormat.portrait.dimensions == .portrait)
    }

    // MARK: - Request resolution

    @Test func requestResolutionDefaultsToLandscape() throws {
        #expect(
            try SlideshowVideoDimensionRequest.resolve(portrait: false, size: nil) == .landscape)
    }

    @Test func requestResolutionPortraitFlagResolvesToPortrait() throws {
        #expect(try SlideshowVideoDimensionRequest.resolve(portrait: true, size: nil) == .portrait)
    }

    @Test func requestResolutionCustomSizeUsesValidating() throws {
        #expect(
            try SlideshowVideoDimensionRequest.resolve(portrait: false, size: "640x360")
                == SlideshowVideoDimensions.validating(width: 640, height: 360)
        )
    }

    @Test func requestResolutionConflictThrows() {
        #expect(throws: SlideshowVideoDimensionRequestError.conflictingOptions) {
            try SlideshowVideoDimensionRequest.resolve(portrait: true, size: "1080x1920")
        }
    }

    // MARK: - Parsing

    @Test func parseAcceptsLowercaseXSeparator() throws {
        let parsed = try SlideshowVideoDimensions.parse("1920x1080")
        #expect(parsed == .landscape)
    }

    @Test func parseAcceptsCustomLowercaseXSize() throws {
        let parsed = try SlideshowVideoDimensions.parse("640x360")
        #expect(parsed.width == 640)
        #expect(parsed.height == 360)
    }

    @Test func parseRejectsUppercaseXSeparator() {
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("1920X1080")
        }
    }

    @Test func parseRejectsMissingComponent() {
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("1920x")
        }
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("x1080")
        }
    }

    @Test func parseRejectsWhitespaceOnlyComponent() {
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("   x1080")
        }
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("1920x   ")
        }
    }

    @Test func parseRejectsNonIntegerComponent() {
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("abcx1080")
        }
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("1920x12.5")
        }
    }

    @Test func parseRejectsExtraComponents() {
        #expect(throws: SlideshowVideoDimensionError.malformedSize) {
            try SlideshowVideoDimensions.parse("1920x1080x60")
        }
    }

    // MARK: - Validation order: positive

    @Test func validatingRejectsZeroWidth() {
        #expect(throws: SlideshowVideoDimensionError.nonPositive) {
            try SlideshowVideoDimensions.validating(width: 0, height: 1080)
        }
    }

    @Test func validatingRejectsZeroHeight() {
        #expect(throws: SlideshowVideoDimensionError.nonPositive) {
            try SlideshowVideoDimensions.validating(width: 1920, height: 0)
        }
    }

    @Test func validatingRejectsNegativeWidth() {
        #expect(throws: SlideshowVideoDimensionError.nonPositive) {
            try SlideshowVideoDimensions.validating(width: -640, height: 360)
        }
    }

    @Test func validatingRejectsNegativeHeight() {
        #expect(throws: SlideshowVideoDimensionError.nonPositive) {
            try SlideshowVideoDimensions.validating(width: 640, height: -360)
        }
    }

    // MARK: - Validation order: even

    @Test func validatingRejectsOddWidth() {
        #expect(throws: SlideshowVideoDimensionError.odd) {
            try SlideshowVideoDimensions.validating(width: 641, height: 360)
        }
    }

    @Test func validatingRejectsOddHeight() {
        #expect(throws: SlideshowVideoDimensionError.odd) {
            try SlideshowVideoDimensions.validating(width: 640, height: 361)
        }
    }

    // MARK: - Validation order: shortest side

    @Test func validatingRejectsShortestSideBelow180() {
        #expect(throws: SlideshowVideoDimensionError.shortestSideTooSmall) {
            try SlideshowVideoDimensions.validating(width: 178, height: 1080)
        }
    }

    @Test func validatingAcceptsShortestSideExactly180() throws {
        let dims = try SlideshowVideoDimensions.validating(width: 180, height: 320)
        #expect(dims.width == 180)
        #expect(dims.height == 320)
    }

    // MARK: - Validation order: longest side

    @Test func validatingRejectsLongestSideAbove4096() {
        #expect(throws: SlideshowVideoDimensionError.longestSideTooLarge) {
            try SlideshowVideoDimensions.validating(width: 4098, height: 1080)
        }
    }

    @Test func validatingAcceptsLongestSideExactly4096() throws {
        // 4096 x 1080 keeps aspect within 4:1 and area within the pixel cap.
        let dims = try SlideshowVideoDimensions.validating(width: 4096, height: 1080)
        #expect(dims.width == 4096)
        #expect(dims.height == 1080)
    }

    // MARK: - Validation order: pixel area

    @Test func validatingRejectsExcessivePixelArea() {
        // 4096 x 2162 is even, within side bounds, within 4:1, but area exceeds 8,847,360.
        #expect(throws: SlideshowVideoDimensionError.pixelAreaTooLarge) {
            try SlideshowVideoDimensions.validating(width: 4096, height: 2162)
        }
    }

    @Test func validatingAcceptsExactMaximumPixelArea() throws {
        // 4096 x 2160 == 8,847,360 pixels exactly, the maximum allowed area.
        let dims = try SlideshowVideoDimensions.validating(width: 4096, height: 2160)
        #expect(dims.width == 4096)
        #expect(dims.height == 2160)
        #expect(dims.width * dims.height == 8_847_360)
    }

    // MARK: - Validation order: aspect ratio

    @Test func validatingRejectsAspectRatioBeyond4to1() {
        // 800 x 196: even, sides within bounds, area within cap, but 800/196 > 4.
        #expect(throws: SlideshowVideoDimensionError.aspectRatioTooExtreme) {
            try SlideshowVideoDimensions.validating(width: 800, height: 196)
        }
    }

    @Test func validatingAcceptsExactly4to1AspectRatio() throws {
        let dims = try SlideshowVideoDimensions.validating(width: 720, height: 180)
        #expect(dims.width == 720)
        #expect(dims.height == 180)
    }

    // MARK: - Known-valid practical sizes

    @Test func validatingAcceptsKnownPracticalDimensions() throws {
        for (width, height) in [
            (320, 180), (640, 360), (1920, 1080), (1080, 1920), (3840, 2160), (2160, 3840),
        ] {
            let dims = try SlideshowVideoDimensions.validating(width: width, height: height)
            #expect(dims.width == width)
            #expect(dims.height == height)
        }
    }

    // MARK: - Layout profile selection

    @Test func layoutProfileIsLegacyLandscapeWhenWidthGreaterThanHeight() throws {
        let dims = try SlideshowVideoDimensions.validating(width: 1920, height: 1080)
        #expect(dims.layoutProfile == .legacyLandscape)
    }

    @Test func layoutProfileIsPhonePortraitWhenHeightGreaterThanWidth() throws {
        let dims = try SlideshowVideoDimensions.validating(width: 1080, height: 1920)
        #expect(dims.layoutProfile == .phonePortrait)
    }

    @Test func layoutProfileIsLegacyLandscapeWhenSquare() throws {
        // 720x720: a square resolves to legacyLandscape deterministically
        // because profile selection is `width >= height`, not orientation.
        let dims = try SlideshowVideoDimensions.validating(width: 720, height: 720)
        #expect(dims.layoutProfile == .legacyLandscape)
    }

    // MARK: - CD-6: Int.max overflow safety

    @Test func intMaxIntMaxThrowsOddNotAreaOverflow() {
        // Int.max is odd, so under the mandated validation order (positive, even,
        // short side, long side, area, aspect) the ODD rule fires before the area
        // multiplication is ever attempted.
        #expect(throws: SlideshowVideoDimensionError.odd) {
            try SlideshowVideoDimensions.validating(width: .max, height: .max)
        }
    }

    @Test func evenOversizedPairThrowsLongestSideTooLargeProvingAreaCannotOverflow() {
        // Int.max - 1 is even, so this reaches the long-side guard, which fires
        // before the area multiplication -- proving the area check can never
        // actually see an overflowing multiply for any input that passes rule 4.
        #expect(throws: SlideshowVideoDimensionError.longestSideTooLarge) {
            try SlideshowVideoDimensions.validating(width: .max - 1, height: .max - 1)
        }
    }

    // MARK: - Error copy (English)

    @Test func errorDescriptionsMatchApprovedEnglishCopy() {
        #expect(
            SlideshowVideoDimensionError.malformedSize.errorDescription
                == "--size must look like 1920x1080.")
        #expect(
            SlideshowVideoDimensionError.nonPositive.errorDescription
                == "Video width and height must both be positive.")
        #expect(
            SlideshowVideoDimensionError.odd.errorDescription
                == "Video width and height must both be even for H.264.")
        #expect(
            SlideshowVideoDimensionError.shortestSideTooSmall.errorDescription
                == "Video's shortest side must be at least 180 pixels.")
        #expect(
            SlideshowVideoDimensionError.longestSideTooLarge.errorDescription
                == "Video's longest side must be no more than 4096 pixels.")
        #expect(
            SlideshowVideoDimensionError.pixelAreaTooLarge.errorDescription
                == "Video dimensions exceed the maximum 8,847,360-pixel area.")
        #expect(
            SlideshowVideoDimensionError.aspectRatioTooExtreme.errorDescription
                == "Video aspect ratio must not exceed 4:1.")
    }

    // MARK: - CD-4: catalog manual + bilingual coverage

    @Test func catalogContainsManualBilingualDimensionAndConflictKeys() throws {
        let strings = try Self.catalogStrings()
        for key in [
            "videoExportErrorMalformedSize",
            "videoExportErrorNonPositiveDimensions",
            "videoExportErrorOddDimensions",
            "videoExportErrorShortestSideTooSmall",
            "videoExportErrorLongestSideTooLarge",
            "videoExportErrorPixelAreaTooLarge",
            "videoExportErrorAspectRatioTooExtreme",
            "videoExportErrorConflictingFormatOptions",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "Missing catalog key: \(key)")
            #expect(
                entry["extractionState"] as? String == "manual",
                "\(key) should be a manual catalog entry.")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["en"] != nil, "\(key) should include English.")
            #expect(localizations["nl"] != nil, "\(key) should include Dutch.")
        }
    }

    private static func catalogStrings() throws -> [String: Any] {
        let catalogURL = try repositoryRoot().appending(path: "EchoCore/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Localizable.xcstrings must be a JSON object."
        )
        return try #require(
            root["strings"] as? [String: Any], "Localizable.xcstrings must contain strings.")
    }

    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "Echo.xcodeproj").path)
            {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
