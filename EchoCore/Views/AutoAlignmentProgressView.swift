import Combine
import SwiftUI
import UIKit

/// Sheet presented during auto-alignment showing progress, phase, results,
/// and a live diagnostic log.
///
/// Uses a polling timer to copy state from the shared `AutoAlignmentState`
/// into local `@State` properties, avoiding SwiftUI observation edge cases
/// in sheets.
struct AutoAlignmentProgressView: View {
    let sharedState: AutoAlignmentState
    @Environment(\.dismiss) private var dismiss
    var onCancel: (() -> Void)?

    // Local copies refreshed by the polling timer.
    @State private var phase = AutoAlignmentState.Phase.idle
    @State private var progress: Double = 0
    @State private var statusMessage = ""
    @State private var currentChapter = 0
    @State private var totalChapters = 0
    @State private var anchoredChapters = 0
    @State private var driftedIDs: [Int] = []
    @State private var repairCount = 0
    @State private var errorMessage: String?
    @State private var logEntries: [String] = []

    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            // Header
            Image(systemName: phaseIcon)
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: phase != .completed && phase != .failed && phase != .idle)

            Text(phase != .completed && phase != .failed && phase != .idle
                 ? "Auto-Aligning Chapters" : "Auto-Alignment")
                .font(.title3.bold())

            // Progress bar
            ProgressView(value: progress) {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            // Phase detail
            detailView
                .font(.caption2)
                .foregroundStyle(.secondary)

            // ── Debug log ──
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Log (\(logEntries.count) entries)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !logEntries.isEmpty {
                        Button("Copy") {
                            UIPasteboard.general.string = logEntries.joined(separator: "\n")
                        }
                        .font(.caption2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                if logEntries.isEmpty {
                    Text("Waiting for alignment to start…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(logEntries.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(logColor(entry))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: logEntries.count) { _, _ in
                            if let last = logEntries.indices.last {
                                withAnimation {
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Actions
            if phase == .completed {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else if phase == .failed {
                VStack(spacing: 8) {
                    Text(errorMessage ?? "An unknown error occurred.")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(.bordered)
                }
            } else {
                Button("Cancel") {
                    onCancel?()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(minWidth: 360, idealWidth: 400)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Polling

    private func startPolling() {
        // Immediate first refresh.
        refresh()
        // Then poll every 0.3 seconds.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        phase = sharedState.phase
        progress = sharedState.progress
        statusMessage = sharedState.statusMessage
        currentChapter = sharedState.currentChapterIndex
        totalChapters = sharedState.totalChapters
        anchoredChapters = sharedState.anchoredChapterCount
        driftedIDs = sharedState.driftedChapterIDs
        repairCount = sharedState.repairAnchorCount
        errorMessage = sharedState.errorMessage
        logEntries = sharedState.debugLog
    }

    // MARK: - Helpers

    private var phaseIcon: String {
        switch phase {
        case .idle, .loadingModel: return "arrow.down.circle"
        case .tier1_ChapterSnap: return "text.book.closed"
        case .tier2_DriftDetection: return "magnifyingglass"
        case .tier3_DriftRepair: return "wrench.adjustable"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func logColor(_ entry: String) -> Color {
        if entry.contains("✓") { return .green }
        if entry.contains("✗") || entry.contains("FAIL") { return .red }
        if entry.contains("→") || entry.contains("skip") { return .orange }
        return .secondary
    }

    @ViewBuilder
    private var detailView: some View {
        if phase == .completed {
            VStack(alignment: .leading, spacing: 4) {
                if anchoredChapters > 0 {
                    Text("• \(anchoredChapters) chapter\(anchoredChapters == 1 ? "" : "s") anchored")
                }
                if !driftedIDs.isEmpty {
                    Text("• \(driftedIDs.count) chapter\(driftedIDs.count == 1 ? "" : "s") flagged for drift")
                }
                if repairCount > 0 {
                    Text("• \(repairCount) repair anchor\(repairCount == 1 ? "" : "s") inserted")
                }
                if anchoredChapters == 0 && driftedIDs.isEmpty {
                    Text("No chapters needed alignment.")
                }
            }
        } else if phase != .idle && phase != .failed && phase != .completed {
            Text("Chapter \(currentChapter + 1) of \(totalChapters)")
        }
    }
}
