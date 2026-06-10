import Combine
import SwiftUI
import UIKit

/// Sheet presented during auto-alignment showing progress, phase, results,
/// and a live diagnostic log.
///
/// Reads `AutoAlignmentState` (an `@Observable` type) directly — SwiftUI
/// automatically tracks which properties are accessed in `body` and re-renders
/// only when those specific properties change.
struct AutoAlignmentProgressView: View {
    let sharedState: AutoAlignmentState
    @Environment(\.dismiss) private var dismiss
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            // Header
            Image(systemName: phaseIcon)
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: sharedState.phase != .completed && sharedState.phase != .failed && sharedState.phase != .idle)

            Text(sharedState.phase != .completed && sharedState.phase != .failed && sharedState.phase != .idle
                 ? "Auto-Aligning Chapters" : "Auto-Alignment")
                .font(.title3.bold())

            // Progress bar
            ProgressView(value: sharedState.progress) {
                Text(sharedState.statusMessage)
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
                    Text("Log (\(sharedState.debugLog.count) entries)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !sharedState.debugLog.isEmpty {
                        Button("Copy") {
                            UIPasteboard.general.string = sharedState.debugLog.joined(separator: "\n")
                        }
                        .font(.caption2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                if sharedState.debugLog.isEmpty {
                    Text("Waiting for alignment to start…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(sharedState.debugLog.enumerated()), id: \.offset) { _, entry in
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
                        .onChange(of: sharedState.debugLog.count) { _, _ in
                            if let last = sharedState.debugLog.indices.last {
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
            if sharedState.phase == .completed {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else if sharedState.phase == .failed {
                VStack(spacing: 8) {
                    Text(sharedState.errorMessage ?? "An unknown error occurred.")
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
    }

    // MARK: - Helpers

    private var phaseIcon: String {
        switch sharedState.phase {
        case .idle, .loadingModel: return "arrow.down.circle"
        case .matchingTitles: return "text.badge.checkmark"
        case .mappingSilences: return "waveform"
        case .transcribingAudio: return "text.bubble"
        case .computingAlignment: return "link"
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
        if sharedState.phase == .completed {
            VStack(alignment: .leading, spacing: 4) {
                if sharedState.titleMatchedChapterCount > 0 {
                    Text("• \(sharedState.titleMatchedChapterCount) via title match (Tier 0)")
                }
                if sharedState.anchoredChapterCount > 0 {
                    Text("• \(sharedState.anchoredChapterCount) chapter\(sharedState.anchoredChapterCount == 1 ? "" : "s") anchored")
                }
                if !sharedState.driftedChapterIDs.isEmpty {
                    Text("• \(sharedState.driftedChapterIDs.count) chapter\(sharedState.driftedChapterIDs.count == 1 ? "" : "s") flagged for drift")
                }
                if sharedState.repairAnchorCount > 0 {
                    Text("• \(sharedState.repairAnchorCount) repair anchor\(sharedState.repairAnchorCount == 1 ? "" : "s") inserted")
                }
                if sharedState.anchoredChapterCount == 0 && sharedState.driftedChapterIDs.isEmpty {
                    Text("No chapters needed alignment.")
                }
            }
        } else if sharedState.phase != .idle && sharedState.phase != .failed && sharedState.phase != .completed {
            Text("Chapter \(sharedState.currentChapterIndex + 1) of \(sharedState.totalChapters)")
        }
    }
}
