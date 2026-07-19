// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The internal layout profile a rendered slideshow frame uses. Selection is
/// solely by orientation -- `width >= height` is `.legacyLandscape`,
/// `height > width` is `.phonePortrait` -- so a square resolves to
/// `.legacyLandscape` deterministically. See `SlideshowVideoDimensions.layoutProfile`.
nonisolated enum SlideshowFrameLayoutProfile: Equatable, Sendable {
    case legacyLandscape
    case phonePortrait
}

/// The two first-class slideshow video export presets exposed by the CLI and
/// platform UI. Custom CLI `--size` values bypass this type and go straight
/// through `SlideshowVideoDimensions.parse(_:)`.
nonisolated enum SlideshowVideoFormat: String, CaseIterable, Identifiable, Sendable {
    case landscape
    case portrait

    var id: Self { self }

    var dimensions: SlideshowVideoDimensions {
        switch self {
        case .landscape: .landscape
        case .portrait: .portrait
        }
    }
}

/// A validated pixel size for slideshow video export.
///
/// The stored initializer is private: callers either use the known-valid
/// `.landscape`/`.portrait` presets or the throwing `validating(width:height:)`/
/// `parse(_:)` factories. This makes it impossible to construct an invalid
/// `SlideshowVideoDimensions` value, so `VideoExportService` and
/// `SlideshowFrameRenderer` can accept this type without re-checking bounds.
nonisolated struct SlideshowVideoDimensions: Equatable, Hashable, Sendable {
    static let landscape = SlideshowVideoDimensions(validatedWidth: 1920, height: 1080)
    static let portrait = SlideshowVideoDimensions(validatedWidth: 1080, height: 1920)

    let width: Int
    let height: Int

    var layoutProfile: SlideshowFrameLayoutProfile {
        width >= height ? .legacyLandscape : .phonePortrait
    }

    private init(validatedWidth width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Parses a `WxH` string using the existing CLI spelling: exactly two
    /// non-empty integer components separated by a lowercase `x`. An
    /// uppercase `X`, a missing or whitespace-only component, a non-integer
    /// component, or any other component count throws `.malformedSize`.
    /// On success the two integers are range-validated via
    /// `validating(width:height:)`.
    static func parse(_ value: String) throws -> Self {
        let components = value.components(separatedBy: "x")
        guard components.count == 2,
            let width = Int(components[0]), let height = Int(components[1])
        else {
            throw SlideshowVideoDimensionError.malformedSize
        }
        return try validating(width: width, height: height)
    }

    /// Validates a raw pixel size against every product dimension rule,
    /// reporting the first failed rule in this order:
    ///
    /// 1. Both dimensions are positive.
    /// 2. Both dimensions are even (required by Echo's H.264 path).
    /// 3. The shortest side is at least 180 pixels.
    /// 4. The longest side is no more than 4096 pixels.
    /// 5. The pixel area is no more than 8,847,360 (4096 x 2160).
    /// 6. The aspect ratio is no more than 4:1.
    static func validating(width: Int, height: Int) throws -> Self {
        guard width > 0, height > 0 else {
            throw SlideshowVideoDimensionError.nonPositive
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw SlideshowVideoDimensionError.odd
        }

        let shortSide = min(width, height)
        let longSide = max(width, height)

        guard shortSide >= 180 else {
            throw SlideshowVideoDimensionError.shortestSideTooSmall
        }
        guard longSide <= 4096 else {
            throw SlideshowVideoDimensionError.longestSideTooLarge
        }

        let (area, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, area <= 8_847_360 else {
            throw SlideshowVideoDimensionError.pixelAreaTooLarge
        }

        // Safe: `longSide` is already bounded to <= 4096 by the guard above,
        // so `shortSide * 4` cannot overflow -- this is exactly why the area
        // multiplication above can never see an overflowing pair either.
        guard longSide <= shortSide * 4 else {
            throw SlideshowVideoDimensionError.aspectRatioTooExtreme
        }

        return SlideshowVideoDimensions(validatedWidth: width, height: height)
    }
}

/// Product-level validation failures for `SlideshowVideoDimensions`. Each
/// case maps to exactly one rule in `validating(width:height:)`, checked in
/// that order, so only the first failing rule is ever reported.
nonisolated enum SlideshowVideoDimensionError: LocalizedError, Equatable, Sendable {
    case malformedSize
    case nonPositive
    case odd
    case shortestSideTooSmall
    case longestSideTooLarge
    case pixelAreaTooLarge
    case aspectRatioTooExtreme

    var errorDescription: String? {
        switch self {
        case .malformedSize:
            String(localized: "videoExportErrorMalformedSize")
        case .nonPositive:
            String(localized: "videoExportErrorNonPositiveDimensions")
        case .odd:
            String(localized: "videoExportErrorOddDimensions")
        case .shortestSideTooSmall:
            String(localized: "videoExportErrorShortestSideTooSmall")
        case .longestSideTooLarge:
            String(localized: "videoExportErrorLongestSideTooLarge")
        case .pixelAreaTooLarge:
            String(localized: "videoExportErrorPixelAreaTooLarge")
        case .aspectRatioTooExtreme:
            String(localized: "videoExportErrorAspectRatioTooExtreme")
        }
    }
}

/// Failure when a caller supplies conflicting format options -- e.g.
/// `--portrait` together with an explicit `--size`. The CLI (Task 7) maps
/// this to an actionable `ValidationError`; this type only signals the
/// conflict, with no precedence between the two options.
nonisolated enum SlideshowVideoDimensionRequestError: Error, Equatable, Sendable {
    case conflictingOptions
}

/// Resolves the video dimensions for a single export request from a
/// `--portrait` flag and an optional `--size` string, matching the CLI
/// resolution table: neither option resolves to Landscape; `--portrait`
/// alone resolves to Portrait; `--size` alone resolves to validated custom
/// dimensions; both together conflict.
nonisolated enum SlideshowVideoDimensionRequest {
    static func resolve(portrait: Bool, size: String?) throws -> SlideshowVideoDimensions {
        switch (portrait, size) {
        case (true, .some):
            throw SlideshowVideoDimensionRequestError.conflictingOptions
        case (true, .none):
            return .portrait
        case (false, .some(let size)):
            return try SlideshowVideoDimensions.parse(size)
        case (false, .none):
            return .landscape
        }
    }
}
