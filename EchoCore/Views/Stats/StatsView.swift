import SwiftUI
import Charts

/// Main stats screen: overview, listening charts, SRS, and planner sections.
import os.log

struct StatsView: View {
    @Environment(PlayerModel.self) private var model
    @State private var selectedBucket: StatsBucket = .week
    @State private var overview: StatsOverview?
    private let logger = Logger(category: "StatsView")
    @State private var bucketedTotals: [BucketTotal] = []
    @State private var perBookTotals: [BookTotal] = []
    @State private var srsStats: SRSStats?
    @State private var dueForecast: [DueForecastPoint] = []
    @State private var plannerAdherence: PlannerAdherence?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                bucketPicker
                overviewSection
                if !bucketedTotals.isEmpty { listeningChart }
                if !perBookTotals.isEmpty { booksSection }
                srsSection
                if let p = plannerAdherence, p.totalPlannedSessions > 0 { plannerSection }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .task { await loadAll() }
        .onChange(of: selectedBucket) { _, _ in Task { await loadBucketed() } }
    }

    // MARK: - Bucket Picker

    private var bucketPicker: some View {
        Picker("Range", selection: $selectedBucket) {
            ForEach([StatsBucket.day, .week, .month, .year, .all], id: \.self) { b in
                Text(b.rawValue.capitalized).tag(b)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        if let o = overview {
            Section("Overview") {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    StatCardView(title: "Total", value: fmt(o.totalListeningDuration),
                                 systemImage: "clock", tint: .green)
                    StatCardView(title: "Today", value: fmt(o.todayDuration),
                                 systemImage: "sun.max", tint: .blue)
                    StatCardView(title: "Streak", value: "\(o.streak.currentStreakDays)d",
                                 subtitle: "best \(o.streak.longestStreakDays)d",
                                 systemImage: "flame", tint: .orange)
                    StatCardView(title: "Daily Avg", value: fmt(o.dailyAverage),
                                 subtitle: "\(o.activeDays) active days",
                                 systemImage: "calendar", tint: .purple)
                }
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - Listening Chart

    private var listeningChart: some View {
        Section("Listening") {
            Chart(bucketedTotals) { bucket in
                BarMark(
                    x: .value("Date", bucket.startDate, unit: selectedBucket.calendarComponent),
                    y: .value("Minutes", bucket.totalAdjustedDuration / 60)
                )
                .foregroundStyle(.blue.opacity(0.6))
            }
            .frame(height: 200)
            .chartYAxisLabel("minutes")
        }
    }

    // MARK: - Books

    private var booksSection: some View {
        Section("Books") {
            Chart(perBookTotals.prefix(8)) { book in
                SectorMark(
                    angle: .value("Time", book.totalAdjustedDuration),
                    innerRadius: .ratio(0.5),
                    angularInset: 1
                )
                .foregroundStyle(by: .value("Book", book.title))
            }
            .frame(height: 220)

            ForEach(perBookTotals) { book in
                NavigationLink {
                    BookStatsView(bookID: book.id, bookTitle: book.title)
                } label: {
                    HStack {
                        Text(book.title).lineLimit(1)
                        Spacer()
                        Text(fmt(book.totalAdjustedDuration))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - SRS

    @ViewBuilder
    private var srsSection: some View {
        if let s = srsStats {
            Section("Study (SRS)") {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    StatCardView(title: "Due", value: "\(s.dueCount)",
                                 systemImage: "bell", tint: .red)
                    StatCardView(title: "Cards", value: "\(s.totalCards)",
                                 systemImage: "rectangle.stack", tint: .indigo)
                    StatCardView(title: "Retention", value: String(format: "%.0f%%", s.retentionRate * 100),
                                 systemImage: "brain", tint: .teal)
                    StatCardView(title: "Avg Ease", value: String(format: "%.1f", s.averageEase),
                                 systemImage: "gauge", tint: .mint)
                }

                if !dueForecast.isEmpty {
                    Chart(dueForecast) { point in
                        LineMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Due", point.dueCount)
                        )
                        .foregroundStyle(.red.opacity(0.6))
                    }
                    .frame(height: 150)
                    .chartYAxisLabel("cards due")
                }
            }
        }
    }

    // MARK: - Planner

    private var plannerSection: some View {
        Section("Planner") {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                StatCardView(
                    title: "Completed",
                    value: "\(plannerAdherence?.completedSessions ?? 0)/\(plannerAdherence?.totalPlannedSessions ?? 0)",
                    subtitle: String(format: "%.0f%%", (plannerAdherence?.completionRate ?? 0) * 100),
                    systemImage: "checklist", tint: .green)
                StatCardView(
                    title: "In Session",
                    value: fmt(plannerAdherence?.actualListenedDuringPlanned ?? 0),
                    systemImage: "headphones", tint: .purple)
            }
        }
    }

    // MARK: - Loaders

    private func loadAll() async {
        await loadOverview()
        await loadBucketed()
        await loadSRS()
        await loadPlanner()
    }

    private func loadOverview() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            overview = try await repo.fetchOverview()
            perBookTotals = try await repo.fetchPerBookTotals()
        } catch {
            logger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func loadBucketed() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            bucketedTotals = try await repo.fetchBucketedTotals(by: selectedBucket)
        } catch {
            logger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func loadSRS() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            srsStats = try await repo.fetchSRSStats()
            dueForecast = try await repo.fetchDueForecast(days: 30)
        } catch {
            logger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func loadPlanner() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            plannerAdherence = try await repo.fetchPlannerAdherence()
        } catch {
            logger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func fmt(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
