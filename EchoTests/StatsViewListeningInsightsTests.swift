// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct StatsViewListeningInsightsTests {
    @Test func statsViewWiresSpeedTrendInsight() throws {
        let source = try Self.statsViewSource()

        #expect(source.contains("@State private var speedTrend"))
        #expect(source.contains("loadListeningInsights()"))
        #expect(source.contains("fetchSpeedTrend"))
        #expect(source.contains("ListeningInsightsSectionView"))
        #expect(source.contains("SpeedTrendChartView"))
    }

    @Test func statsViewWiresTimeOfDayInsight() throws {
        let source = try Self.statsViewSource()

        #expect(source.contains("@State private var timeOfDayHistogram"))
        #expect(source.contains("fetchTimeOfDayHistogram"))
        #expect(source.contains("TimeOfDayHistogramChartView"))
    }

    private static func statsViewSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views/Stats/StatsView.swift")

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
