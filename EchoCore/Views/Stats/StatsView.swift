// SPDX-License-Identifier: GPL-3.0-or-later
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
    @State private var dailyReviews: [DailyReviewCount] = []
    @State private var retentionCurve: [RetentionCurvePoint] = []
    @State private var gradeDistribution: [GradeDistribution] = []
    @State private var speedTrend: [SpeedTrendPoint] = []
    @State private var timeOfDayHistogram: [HourBucket] = []
    @State private var plannerAdherence: PlannerAdherence?
    @State private var showingStudySession = false
    @State private var studySessionViewModel: StudySessionViewModel?
    @State private var studySessionLaunchError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                bucketPicker
                overviewSection
                if !bucketedTotals.isEmpty { listeningChart }
                if !speedTrend.isEmpty || timeOfDayHistogram.contains(where: { $0.totalAdjustedDuration > 0 }) {
                    ListeningInsightsSectionView(
                        speedTrend: speedTrend,
                        timeOfDayHistogram: timeOfDayHistogram
                    )
                }
                if !perBookTotals.isEmpty { booksSection }
                srsSection
                if let p = plannerAdherence, p.totalPlannedSessions > 0 { plannerSection }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .task { await loadAll() }
        .onChange(of: selectedBucket) { _, _ in Task { await loadBucketed() } }
        .sheet(isPresented: $showingStudySession) {
            if let vm = studySessionViewModel {
                StudySessionView(viewModel: vm)
            }
        }
        .alert(
            "Could Not Start Study",
            isPresented: Binding(
                get: { studySessionLaunchError != nil },
                set: { if !$0 { studySessionLaunchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(studySessionLaunchError ?? "")
        }
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
                StudyLibraryLinksView(onReviewTap: launchStudySession)

                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    StatCardView(title: "Due", value: "\(s.dueCount)",
                                 systemImage: "bell", tint: .red)
                    StatCardView(title: "Cards", value: "\(s.totalCards)",
                                 systemImage: "rectangle.stack", tint: .indigo)
                    StatCardView(title: "Retention", value: percentage(s.retentionRate),
                                 systemImage: "brain", tint: .teal)
                    StatCardView(title: "Avg Ease", value: oneDecimal(s.averageEase),
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

                if !dailyReviews.isEmpty {
                    DailyReviewChartView(counts: dailyReviews)
                }

                if !retentionCurve.isEmpty {
                    RetentionCurveChartView(points: retentionCurve)
                }

                let reviewedGrades = gradeDistribution.filter { $0.count > 0 }
                if !reviewedGrades.isEmpty {
                    GradeDistributionChartView(distribution: reviewedGrades)
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
                    subtitle: percentage(plannerAdherence?.completionRate ?? 0),
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
        await loadListeningInsights()
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

    private func loadListeningInsights() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            let calendar = Calendar.current
            speedTrend = try await repo.fetchSpeedTrend(calendar: calendar)
            timeOfDayHistogram = try await repo.fetchTimeOfDayHistogram(calendar: calendar)
        } catch {
            logger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func loadSRS() async {
        guard let db = model.databaseService else { return }
        do {
            let repo = StatsRepository(reader: db.writer)
            let calendar = Calendar.current
            let now = Date()
            let today = calendar.startOfDay(for: now)
            let startDate = calendar.date(byAdding: .day, value: -30, to: today) ?? .distantPast
            let endDate = calendar.date(byAdding: .day, value: 1, to: today) ?? now

            srsStats = try await repo.fetchSRSStats(now: now, calendar: calendar)
            dueForecast = try await repo.fetchDueForecast(days: 30, now: now, calendar: calendar)
            dailyReviews = try await repo.fetchDailyReviewCounts(
                from: startDate,
                to: endDate,
                calendar: calendar
            )
            retentionCurve = try await repo.fetchRetentionCurve()
            gradeDistribution = try await repo.fetchGradeDistribution()
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

    private func launchStudySession() {
        guard let db = model.databaseService else {
            studySessionLaunchError = String(
                localized: "The app database is unavailable. Reopen the book and try again.")
            return
        }
        let vm = StudySessionViewModel(
            db: db.writer,
            updateReviewNotification: { [weak model] dueCount in
                ReviewNotificationService.updateNotification(
                    dueCount: dueCount,
                    isEnabled: model?.settingsManager?.reviewNotificationsEnabled ?? false
                )
            }
        )
        vm.onRequestAssignmentPlayback = { [weak model] card in
            model?.playStudyAssignment(card)
        }
        vm.onRetirePrompt = { [weak model] prompt in
            model?.pendingRetirePrompt = prompt
        }

        do {
            try vm.loadQueue(
                globalNewChapterLimit: model.settingsManager?.studyGlobalNewChapterLimit
                    ?? SettingsManager.Defaults.studyGlobalNewChapterLimit,
                globalNewCardLimit: model.settingsManager?.studyNewCardsPerDayLimit
                    ?? SettingsManager.Defaults.studyNewCardsPerDayLimit
            )
            studySessionViewModel = vm
            showingStudySession = true
        } catch {
            studySessionViewModel = nil
            showingStudySession = false
            studySessionLaunchError = String(
                localized: "The study queue could not be loaded. Try again.")
            logger.error("Failed to launch study session: \(error.localizedDescription)")
        }
    }

    private func fmt(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func percentage(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

private struct ListeningInsightsSectionView: View {
    let speedTrend: [SpeedTrendPoint]
    let timeOfDayHistogram: [HourBucket]

    var body: some View {
        Section("Listening Patterns") {
            if !speedTrend.isEmpty {
                SpeedTrendChartView(points: speedTrend)
            }

            if timeOfDayHistogram.contains(where: { $0.totalAdjustedDuration > 0 }) {
                TimeOfDayHistogramChartView(buckets: timeOfDayHistogram)
            }
        }
    }
}

private struct SpeedTrendChartView: View {
    let points: [SpeedTrendPoint]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Playback Speed")
                .bold()
            Chart(points, id: \.date) { point in
                LineMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Speed", point.averageSpeed)
                )
                .foregroundStyle(.cyan)
                PointMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Speed", point.averageSpeed)
                )
                .foregroundStyle(.cyan)
            }
            .frame(height: 150)
            .chartYAxisLabel("speed")
        }
    }
}

private struct TimeOfDayHistogramChartView: View {
    let buckets: [HourBucket]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Time of Day")
                .bold()
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", hourLabel(bucket.id)),
                    y: .value("Minutes", bucket.totalAdjustedDuration / 60)
                )
                .foregroundStyle(.blue.opacity(0.7))
            }
            .frame(height: 150)
            .chartXAxisLabel("hour")
            .chartYAxisLabel("minutes")
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        "\(hour):00"
    }
}

private struct StudyLibraryLinksView: View {
    let onReviewTap: () -> Void

    var body: some View {
        Group {
            Button("Review Queue", systemImage: "rectangle.stack.fill", action: onReviewTap)

            NavigationLink {
                CardInboxView()
            } label: {
                Label("Card Inbox", systemImage: "tray")
            }

            NavigationLink {
                DeckListView()
            } label: {
                Label("Decks", systemImage: "rectangle.stack")
            }
        }
    }
}

private struct DailyReviewChartView: View {
    let counts: [DailyReviewCount]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Daily Reviews")
                .bold()
            Chart(counts) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value("Reviews", point.count)
                )
                .foregroundStyle(.indigo.opacity(0.7))
            }
            .frame(height: 150)
            .chartYAxisLabel("reviews")
        }
    }
}

private struct RetentionCurveChartView: View {
    let points: [RetentionCurvePoint]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Retention Curve")
                .bold()
            Chart(points) { point in
                LineMark(
                    x: .value("Interval", point.intervalDays),
                    y: .value("Retention", point.retentionRate * 100)
                )
                .foregroundStyle(.teal)
                PointMark(
                    x: .value("Interval", point.intervalDays),
                    y: .value("Retention", point.retentionRate * 100)
                )
                .foregroundStyle(.teal)
            }
            .frame(height: 150)
            .chartXAxisLabel("days")
            .chartYAxisLabel("remembered %")
            .chartYScale(domain: 0...100)
        }
    }
}

private struct GradeDistributionChartView: View {
    let distribution: [GradeDistribution]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Grade Mix")
                .bold()
            Chart(distribution) { item in
                BarMark(
                    x: .value("Grade", item.grade),
                    y: .value("Cards", item.count)
                )
                .foregroundStyle(.mint.opacity(0.7))
            }
            .frame(height: 150)
            .chartXAxisLabel("grade")
            .chartYAxisLabel("cards")
        }
    }
}
