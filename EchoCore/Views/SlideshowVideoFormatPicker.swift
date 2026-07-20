// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import SwiftUI

    /// Shared Landscape/Portrait format picker for slideshow video export.
    /// Task 9 (iOS) and Task 10 (macOS) embed this view in their export
    /// configuration screens. It is intentionally platform-neutral SwiftUI
    /// -- no UIKit/AppKit imports -- so one implementation renders
    /// identically on both hosts.
    ///
    /// The `#if os(iOS) || os(macOS)` guard keeps this view out of the
    /// watchOS-based Widget target. echo-cli is a macOS command-line target
    /// (SDKROOT=macosx, same as the macOS app), so `#if os()` cannot exclude
    /// it -- it is excluded instead via a membershipException on the
    /// echo-cli target in project.pbxproj (mirroring the cross-platform
    /// views `StudyCheckpointPanelView` / `AICardGenerationSettingsView`),
    /// because echo-cli lacks the string catalog's generated localization
    /// symbols this view depends on.
    struct SlideshowVideoFormatPicker: View {
        @Binding var selection: SlideshowVideoFormat

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Picker(String(localized: .videoExportFormatLabel), selection: $selection) {
                    ForEach(SlideshowVideoFormat.allCases) { format in
                        Text(Self.visibleLabel(for: format)).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(.videoExportFormatLabel))
                .accessibilityValue(Text(Self.accessibilityValue(for: selection)))

                // Orientation is communicated by text and the exact pixel
                // dimensions, never by color or an icon alone.
                Text(Self.resolutionText(for: selection))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(.videoExportFormatExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        private static func visibleLabel(
            for format: SlideshowVideoFormat
        ) -> LocalizedStringResource {
            switch format {
            case .landscape: .videoExportFormatLandscape
            case .portrait: .videoExportFormatPortrait
            }
        }

        /// Pure mapping from format identity to its localized accessibility
        /// value -- identity plus exact resolution, e.g. "Portrait, 1080 by
        /// 1920" -- so VoiceOver announces orientation from text alone,
        /// never from color or an icon.
        nonisolated static func accessibilityValue(for format: SlideshowVideoFormat) -> String {
            switch format {
            case .landscape:
                String(localized: .videoExportFormatLandscapeAccessibilityValue)
            case .portrait:
                String(localized: .videoExportFormatPortraitAccessibilityValue)
            }
        }

        private static func resolutionText(for format: SlideshowVideoFormat) -> String {
            let dimensions = format.dimensions
            return "\(dimensions.width.formatted(.number.grouping(.never)))"
                + " × \(dimensions.height.formatted(.number.grouping(.never)))"
        }
    }
#endif
