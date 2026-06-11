import Foundation
import Observation
import os.log

@MainActor @Observable
final class TimelineService {
    private let logger = Logger(category: "TimelineService")
    private let db: DatabaseService?
    private let calendar = Calendar.current

    // MARK: - Viewport state

    private(set) var viewportStart: Date = Date().addingTimeInterval(-3600)
    private(set) var viewportEnd: Date = Date().addingTimeInterval(3600)
    private(set) var loadedStart: Date?
    private(set) var loadedEnd: Date?
    private let viewportSpan: TimeInterval = 7200 // 2-hour default window

    // MARK: - Published state

    private(set) var groups: [TimelineGroup] = []
    private(set) var timeScale: TimelineScope = .chapter
    private(set) var isLoadingEarlier: Bool = false
    private(set) var isLoadingLater: Bool = false
    private(set) var isViewingMode: Bool = true
    private(set) var now: Date = Date()

    // MARK: - Load generation (prevents stale results from stacking)

    private var loadGeneration = 0

    // MARK: - Dependencies

    private var hasDatabase: Bool { db != nil }


    // MARK: - "Now" timer

    @ObservationIgnored private var nowTimer: Timer?

    // MARK: - Init

    init(databaseService: DatabaseService? = nil) {
        self.db = databaseService
        startNowTimer()

    }

    deinit {
        nowTimer?.invalidate()
    }

    // MARK: - Viewport management

    func recenterOnNow() {
        let span = viewportEnd.timeIntervalSince(viewportStart)
        now = Date()
        viewportStart = now.addingTimeInterval(-span / 2)
        viewportEnd = now.addingTimeInterval(span / 2)
        loadCurrentWindow(force: true)
    }

    func setTimeScale(_ scale: TimelineScope) {
        guard scale != timeScale else { return }
        timeScale = scale
        adjustViewportForScale()
        loadCurrentWindow(force: true)
    }

    // MARK: - Infinite scroll

    func loadEarlier() {
        guard !isLoadingEarlier else { return }
        isLoadingEarlier = true
        loadGeneration += 1
        let gen = loadGeneration
        Task {
            defer { isLoadingEarlier = false }
            let extendedStart = viewportStart.addingTimeInterval(-viewportSpan)
            do {
                let events = try loadEvents(in: extendedStart...viewportStart)
                guard gen == loadGeneration else { return }
                let newGroups = groupEvents(events)
                await MainActor.run {
                    var merged = newGroups + self.groups
                    merged = deduplicate(groups: merged)
                    self.groups = merged
                    self.loadedStart = extendedStart
                    self.viewportStart = extendedStart
                }
            } catch {
                logger.error("Failed to load earlier events: \(error.localizedDescription)")
            }
        }
    }

    func loadLater() {
        guard !isLoadingLater else { return }
        isLoadingLater = true
        loadGeneration += 1
        let gen = loadGeneration
        Task {
            defer { isLoadingLater = false }
            let extendedEnd = viewportEnd.addingTimeInterval(viewportSpan)
            do {
                let events = try loadEvents(in: viewportEnd...extendedEnd)
                guard gen == loadGeneration else { return }
                let newGroups = groupEvents(events)
                await MainActor.run {
                    var merged = self.groups + newGroups
                    merged = deduplicate(groups: merged)
                    self.groups = merged
                    self.loadedEnd = extendedEnd
                    self.viewportEnd = extendedEnd
                }
            } catch {
                logger.error("Failed to load later events: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private data loading

    private func loadCurrentWindow(force: Bool = false) {
        loadGeneration += 1
        let gen = loadGeneration
        Task {
            do {
                let events = try loadEvents(in: viewportStart...viewportEnd)
                guard gen == loadGeneration else { return }
                let newGroups = groupEvents(events)
                await MainActor.run {
                    self.groups = newGroups
                    self.loadedStart = self.viewportStart
                    self.loadedEnd = self.viewportEnd
                }
            } catch {
                logger.error("Failed to load timeline window: \(error.localizedDescription)")
            }
        }
    }

    private func loadEvents(in range: ClosedRange<Date>) throws -> [RealTimeEventRecord] {
        guard let db else { return [] }
        let dao = RealTimeEventDAO(db: db.writer)
        return try dao.events(in: range)
    }

    private func groupEvents(_ records: [RealTimeEventRecord]) -> [TimelineGroup] {
        let cards = records.map { ContentCard(from: RealTimeEvent(from: $0)) }
        return timeScale.group(cards, calendar: calendar)
    }

    private func adjustViewportForScale() {
        let center = viewportStart.addingTimeInterval(
            viewportEnd.timeIntervalSince(viewportStart) / 2
        )
        let span: TimeInterval = switch timeScale {
        case .transcription: 300      // 5 min
        case .chapter: 7200           // 2 hr
        case .book: 604800            // 7 days
        }
        viewportStart = center.addingTimeInterval(-span / 2)
        viewportEnd = center.addingTimeInterval(span / 2)
    }


    // MARK: - Now timer

    private func startNowTimer() {
        nowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
            }
        }
    }

    private func stopTimers() {
        nowTimer?.invalidate()
        nowTimer = nil
    }

    // MARK: - Helpers

    private func deduplicate(groups: [TimelineGroup]) -> [TimelineGroup] {
        var seen: Set<String> = []
        return groups.filter { seen.insert($0.id).inserted }
    }
}
