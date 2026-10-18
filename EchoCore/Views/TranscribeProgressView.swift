// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import SwiftUI

    /// Sheet shown while an audio-only book is transcribed on-device, then
    /// materialized into the reader. Mirrors `AutoAlignmentProgressView`'s shape.
    struct TranscribeProgressView: View {
        let progress: StandaloneProgressState
        let isFinalizing: Bool
        var onCancel: (() -> Void)?
        @Environment(\.dismiss) private var dismiss

        /// Fraction complete (0...1). Static + pure so it is unit-testable.
        static func fraction(for state: StandaloneProgressState) -> Double {
            guard state.chaptersTotal > 0 else { return 0.0 }
            return min(1.0, Double(state.chaptersComplete) / Double(state.chaptersTotal))
        }

        private var isDone: Bool {
            !progress.isRunning && !isFinalizing && progress.chaptersTotal > 0
                && progress.chaptersComplete >= progress.chaptersTotal
        }

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: progress.isRunning || isFinalizing)

                Text("Transcribing Audiobook")
                    .font(.title3.bold())

                ProgressView(value: Self.fraction(for: progress)) {
                    Text(
                        isFinalizing
                            ? String(localized: "Building reader…")
                            : String(
                                localized:
                                    "Chapter \(progress.chaptersComplete) of \(progress.chaptersTotal)"
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if isDone {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
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
    }
#endif
