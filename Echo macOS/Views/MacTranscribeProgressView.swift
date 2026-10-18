// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacTranscribeProgressView.swift
//  Echo macOS
//
//  macOS sheet shown while an audio-only book is transcribed on-device,
//  then materialized into the reader. Mirrors TranscribeProgressView with
//  macOS-native sizing and styling.
//

import SwiftUI

struct MacTranscribeProgressView: View {
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
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.accent)
                .symbolEffect(.pulse, isActive: progress.isRunning || isFinalizing)

            Text("Transcribing Audiobook")
                .font(.title3.bold())

            ProgressView(value: Self.fraction(for: progress)) {
                Text(
                    isFinalizing
                        ? "Building reader\u{2026}"
                        : "Chapter \(progress.chaptersComplete) of \(progress.chaptersTotal)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 300)

            if isDone {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Cancel") {
                    onCancel?()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(width: 400, height: 220)
    }
}
