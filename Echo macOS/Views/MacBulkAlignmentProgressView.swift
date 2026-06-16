// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacBulkAlignmentProgressView.swift
//  Echo macOS
//
//  WS-12: Progress sheet for MacBulkAlignmentService.
//  Shows progress bar, current book, ETA, and controls.
//

import SwiftUI

struct MacBulkAlignmentProgressView: View {
    @Bindable var service: MacBulkAlignmentService
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Bulk Alignment").font(.title)

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(
                    value: Double(service.progress.completedBooks),
                    total: Double(max(service.progress.totalBooks, 1))
                )
                .frame(maxWidth: 400)

                HStack {
                    Text("Book \(service.progress.completedBooks) of \(service.progress.totalBooks)")
                        .font(.headline)

                    Spacer()

                    if service.progress.isRunning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    }
                }

                Text(service.progress.currentBookName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let eta = service.progress.estimatedTimeRemaining {
                    Text(etaString(eta))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 400)

            Divider()

            HStack {
                Toggle("Sleep when done", isOn: $service.progress.sleepWhenDone)
                    .toggleStyle(.checkbox)

                Spacer()

                if service.progress.isRunning {
                    Button("Stop") { service.stop() }
                        .keyboardShortcut(.cancelAction)
                }

                Button("Run in Background") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!service.progress.isRunning)
            }
        }
        .padding()
        .frame(width: 480, height: 280)
    }

    // MARK: - Helpers

    private func etaString(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        if totalMinutes < 1 {
            return "Less than a minute remaining"
        } else if totalMinutes < 60 {
            return "~\(totalMinutes) minutes remaining"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return "~\(hours)h \(mins)m remaining"
        }
    }
}
