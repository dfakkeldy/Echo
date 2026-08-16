// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// Structural tests for three macOS complaints:
///
///   1. long-running work gave no sign of life — the batch queue's bar jumped
///      to 66% in a millisecond and then sat there for the whole run;
///   2. nothing said whether the open EPUB was actually aligned to its audio;
///   3. the trailing pane could not be hidden.
///
/// These are source-scanning (see ``MacSource``) because the `Echo macOS`
/// target is not compiled into EchoTests: the wiring can be asserted, the
/// arithmetic cannot be executed. The behaviour that *can* be executed —
/// deciding whether a book is aligned — lives in `BookAlignmentSummary` and is
/// unit-tested for real in `BookAlignmentSummaryTests`.
struct MacAlignmentVisibilityTests {

    // MARK: - 1. Progress that actually moves

    /// THE regression. Two hardcoded jumps were fired back-to-back *before* the
    /// single multi-hour `align` await, so the bar reached 66% instantly and
    /// then froze. If these literals ever come back, the freeze is back.
    @Test func batchRunnerNoLongerFakesAlignmentProgress() throws {
        let source = try MacSource.read("Services/MacBatchProcessingService.swift")
        #expect(!source.contains("progress(.transcribing, 0.33, \"Transcribing…\")"))
        #expect(!source.contains("progress(.aligning, 0.66, \"Aligning…\")"))
    }

    /// The queue item's bar is now driven by the aligner's own reports.
    @Test func batchRunnerForwardsAlignmentProgress() throws {
        let source = try MacSource.read("Services/MacBatchProcessingService.swift")
        #expect(source.contains("onProgress: { report in"))
        #expect(source.contains("indeterminate: report.fraction == nil"))
        #expect(source.contains("static func queueProgress(forAlignmentFraction fraction: Double)"))
        #expect(source.contains("static let alignBandStart = 0.10"))
    }

    /// An indeterminate report carries no fraction, so the mapping has to hold
    /// the last known one. Recomputing from zero would drag the bar backwards
    /// to the band floor every time alignment entered DTW or the rebuild.
    @Test func indeterminatePhasesDoNotRewindTheBar() throws {
        let source = try MacSource.read("Services/MacBatchProcessingService.swift")
        #expect(source.contains("var lastAlignFraction = 0.0"))
        #expect(
            source.contains("if let fraction = report.fraction { lastAlignFraction = fraction }"))
    }

    /// The aligner publishes progress to a caller, not only to observable
    /// properties nothing was reading. Non-optional with a no-op default: an
    /// optional closure parameter is implicitly `@escaping` and could not
    /// accept the runner's non-escaping reporter.
    @Test func alignmentServiceReportsToItsCaller() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(source.contains("onProgress: (Progress) -> Void = { _ in }"))
        #expect(source.contains("struct Progress: Equatable, Sendable"))
        #expect(source.contains("static func transcribeMessage("))
    }

    /// Transcription is the long pole and it *can* say how far along it is, so
    /// it must report per chunk rather than once at the start.
    @Test func transcriptionReportsPerChunk() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(
            source.contains(
                "let heard = totalDuration > 0 ? min(1.0, chunkStartTime / totalDuration) : 0"))
        #expect(source.contains("elapsed: Date().timeIntervalSince(transcriptionStart)"))
    }

    /// Phases whose duration genuinely cannot be predicted report `nil`, which
    /// asks for an indeterminate bar. A determinate bar parked on one number
    /// for ten minutes is indistinguishable from a hang.
    @Test func unpredictablePhasesReportIndeterminate() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(source.contains("report(nil, \"Preparing the speech model…\")"))
        #expect(source.contains("report(nil, \"Building the read-along timeline…\")"))
    }

    /// "Stop and Remove" during the match has to actually stop. The
    /// non-cancellable bisection burned CPU on a book the user had removed.
    @Test func matchingIsCancellable() throws {
        let source = try MacSource.read("Services/MacAlignmentService.swift")
        #expect(source.contains("TokenDTW.alignWithBisectionCancellable("))
        #expect(!source.contains("candidates: TokenDTW.alignWithBisection(epub:"))
    }

    /// Per-chunk reports run into the hundreds for a full-length book. They all
    /// reach the in-memory `activity`, but only rounded-percentage or message
    /// changes are written back to `batch_queue`.
    @Test func persistedProgressIsThrottledButActivityIsNot() throws {
        let source = try MacSource.read("Services/MacBatchProcessingService.swift")
        #expect(source.contains("private(set) var activity: Activity?"))
        #expect(source.contains("var lastPersisted: (percent: Int, message: String?) = (-1, nil)"))
        #expect(
            source.contains(
                "guard percent != lastPersisted.percent || message != lastPersisted.message"))
    }

    /// Batch work runs for hours and used to be invisible unless the queue
    /// sheet happened to be open.
    @Test func mainWindowShowsAPersistentActivityStrip() throws {
        let source = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(source.contains("if let activity = batchService.activity {"))
        #expect(source.contains("MacBatchActivityStrip(activity: activity)"))
        // Routed through the app scene so there is exactly one Batch Queue
        // sheet, shared with ⌘⇧B, rather than a second local copy.
        #expect(
            source.contains(
                "NotificationCenter.default.post(name: .requestBatchQueue, object: nil)"))
    }

    @Test func appSceneListensForTheActivityStripsQueueButton() throws {
        let source = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            source.contains(
                "static let requestBatchQueue = Notification.Name(\"com.echo.requestBatchQueue\")"))
        #expect(
            source.contains(
                ".onReceive(NotificationCenter.default.publisher(for: .requestBatchQueue)) { _ in showBatchQueue = true }"
            ))
    }

    /// The in-flight row shows an indeterminate bar when the phase has no
    /// fraction, and a live elapsed clock either way, so something is always
    /// visibly moving.
    @Test func queueRowDistinguishesIndeterminatePhases() throws {
        let source = try MacSource.read("Views/MacBatchQueueView.swift")
        #expect(source.contains("if let activity, activity.fraction == nil {"))
        #expect(source.contains("TimelineView(.periodic(from: .now, by: 1))"))
        #expect(source.contains("activity.elapsedLabel(at: context.date)"))
    }

    // MARK: - 2. Is the EPUB aligned to the audio?

    @Test func readerHeaderCarriesTheAlignmentBadge() throws {
        let source = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(source.contains("MacAlignmentBadge(summary: alignmentSummary)"))
        #expect(
            source.contains("@State private var alignmentSummary: BookAlignmentSummary = .empty"))
    }

    /// A finished batch alignment changes the answer without touching
    /// `currentURL` or the ingestion trigger, so the badge needs its own
    /// refresh triggers or it keeps claiming "Estimated only" forever.
    @Test func badgeRefreshesWhenAnAlignmentFinishes() throws {
        let source = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(source.contains(".onChange(of: batchService.activity == nil) { _, isIdle in"))
        #expect(
            source.contains(
                ".onReceive(NotificationCenter.default.publisher(for: .timelineItemsIngested)) { note in"
            ))
    }

    /// `BookAlignmentSummary.load` is synchronous on purpose — a plain
    /// `nonisolated async` still runs on the main-actor caller under
    /// `SWIFT_APPROACHABLE_CONCURRENCY` — so the hop off main must be explicit.
    @Test func badgeQueriesRunOffTheMainActor() throws {
        let source = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(source.contains("await Task.detached(priority: .utility) {"))
        #expect(
            source.contains(
                "(try? BookAlignmentSummary.load(audiobookID: audiobookID, db: writer))"))
    }

    /// The badge is only worth having if it separates a real alignment from the
    /// importer's word-count guess, which look identical while reading.
    @Test func badgeNamesEveryStateDistinctly() throws {
        let source = try MacSource.read("Views/MacAlignmentBadge.swift")
        #expect(source.contains("case .aligned: return \"Aligned · \\(summary.coveragePercent)%\""))
        #expect(source.contains("case .estimated: return \"Estimated only\""))
        #expect(source.contains("case .unaligned: return \"Not aligned\""))
        // Nothing to say about alignment for a book with no reader text.
        #expect(source.contains("if summary.state != .noText {"))
    }

    // MARK: - 3. A hideable trailing pane

    /// `NavigationSplitViewVisibility` only governs the *leading* columns: in a
    /// three-column split view no value hides the detail column. ⌘T used to set
    /// `.detailOnly`, which hid the library and the reader and left the notes
    /// pane — the exact opposite of what was asked for. Two columns plus a real
    /// inspector is the layout where both sides hide independently.
    @Test func trailingPaneIsAnInspectorNotADetailColumn() throws {
        let source = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            source.contains(
                "NavigationSplitView(columnVisibility: $columnVisibility) { sidebarPane } detail: { centerPane }"
            ))
        #expect(source.contains(".inspector(isPresented: $showsNotesInspector)"))
        #expect(source.contains("MacNotesPane()"))
        #expect(source.contains(".inspectorColumnWidth(min: 220, ideal: 320, max: 520)"))
        // The old toggle, which hid the wrong panes.
        #expect(!source.contains("columnVisibility == .detailOnly"))
    }

    /// Two ways in — ⌘T and a toolbar button — and the choice survives relaunch.
    @Test func inspectorTogglesFromMenuAndToolbarAndPersists() throws {
        let source = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(source.contains("@AppStorage(\"mac.showsNotesInspector\")"))
        #expect(source.contains("withAnimation { showsNotesInspector.toggle() }"))
        #expect(source.contains("Label(\"Toggle Notes Pane\", systemImage: \"sidebar.trailing\")"))
    }

    /// The View menu names the pane it acts on. "Toggle Review Pane" described
    /// the split view's detail column, which was never hideable.
    @Test func viewMenuNamesTheNotesPane() throws {
        let source = try MacSource.read("Echo_macOSApp.swift")
        #expect(source.contains("Button(\"Hide or Show Notes\")"))
        #expect(!source.contains("Button(\"Toggle Review Pane\")"))
    }
}
