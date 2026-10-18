// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacBatchActivityStrip.swift
//  Echo macOS
//
//  Persistent "something is happening" bar for the main window.
//

import SwiftUI

/// A thin status bar showing what the batch queue is doing right now.
///
/// Batch work runs for hours and, until this existed, was only visible inside
/// the Batch Queue sheet (⌘⇧B). Close the sheet and the app looked idle while
/// it was transcribing an audiobook. The strip appears only while a book is in
/// flight and clicking it reopens the queue.
struct MacBatchActivityStrip: View {
    let activity: MacBatchProcessingService.Activity
    let onOpenQueue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !activity.message.isEmpty {
                    Text(activity.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            // Indeterminate phases get the barber pole rather than a bar parked
            // at a constant, which is what "stuck" looks like.
            if let fraction = activity.fraction {
                ProgressView(value: fraction)
                    .frame(width: 110)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            }

            // Re-evaluates once a second purely so the clock ticks; the work
            // itself pushes updates through `activity`.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(activity.elapsedLabel(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Time elapsed"))

            Button("Queue", action: onOpenQueue)
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Open the batch queue")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Batch processing"))
        .accessibilityValue(Text("\(activity.displayName). \(activity.message)"))
    }
}
