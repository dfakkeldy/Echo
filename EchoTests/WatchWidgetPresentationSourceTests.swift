// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchWidgetPresentationSourceTests {
    @Test("widget timeline entries carry the persisted cover accent")
    func widgetEntryCarriesAccent() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")

        #expect(source.contains("let artworkAccentColorHex: String?"))
        #expect(source.contains("defaults.string(forKey: \"artworkAccentColorHex\")"))
        #expect(source.contains("artworkAccentColorHex: artworkAccentColorHex"))
    }

    @Test("widget timeline entries carry the persisted cover ramp")
    func widgetEntryCarriesCoverRamp() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")

        #expect(source.contains("let coverRampTopHex: String?"))
        #expect(source.contains("let coverRampBottomHex: String?"))
        #expect(source.contains("defaults.string(forKey: \"coverRampTopHex\")"))
        #expect(source.contains("defaults.string(forKey: \"coverRampBottomHex\")"))
    }

    @Test("the container background goes through the ramp policy")
    func containerBackgroundUsesRampPolicy() {
        // `make test` cannot compile the watchOS widget target, so the wiring
        // is guarded by source scan the way the accent's already is.
        let source = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoWidgetEntryView.swift"
        )

        #expect(source.contains("WidgetCoverRampPolicy.style("))
        #expect(source.contains(".containerBackground(for: .widget)"))
        // Tinted and vibrant faces flatten supplied colour, so the ramp must
        // stay gated on the rendering mode rather than painted unconditionally.
        #expect(source.contains("preservesExactCoverColor: renderingMode == .fullColor"))
    }

    @Test("widget declares both supported Watch families")
    func widgetFamilies() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")
        #expect(
            source.contains(
                ".supportedFamilies([.accessoryCircular, .accessoryRectangular])"
            )
        )
    }

    @Test("entry router selects focused family views")
    func familyRouter() {
        let source = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoWidgetEntryView.swift"
        )
        #expect(source.contains(#"@Environment(\.widgetFamily)"#))
        #expect(source.contains("EchoCircularWidgetView(entry: entry)"))
        #expect(source.contains("EchoRectangularWidgetView(entry: entry)"))
        #expect(source.contains(".accessibilityValue(entry.accessibilityValue)"))
        #expect(source.contains("guard progressFraction.isFinite else { return 0 }"))
    }

    @Test("circular and rectangular views use approved policies")
    func presentationPolicies() {
        let circular = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoCircularWidgetView.swift"
        )
        let rectangular = Self.sourceIfPresent(
            at: "Echo Widget/Views/EchoRectangularWidgetView.swift"
        )

        #expect(circular.contains("WatchProgressRingMetrics.complicationLineWidth"))
        #expect(circular.contains("WatchProgressRingMetrics.complicationInset"))
        #expect(circular.contains("EchoWidgetArtworkView"))
        #expect(circular.contains(".widgetAccentable()"))
        #expect(rectangular.contains(#"@Environment(\.widgetRenderingMode)"#))
        #expect(rectangular.contains("renderingMode == .fullColor"))
        #expect(rectangular.contains("WidgetProgressAccentPolicy.style"))
        #expect(rectangular.contains("WatchProgressRingMetrics.rectangularGaugeHeight"))
        #expect(rectangular.contains("EchoWidgetArtworkView"))
    }

    static func sourceIfPresent(at relativePath: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return
            (try? String(
                contentsOf: repositoryRoot.appending(path: relativePath),
                encoding: .utf8
            )) ?? ""
    }
}
