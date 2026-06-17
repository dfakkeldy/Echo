// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacBatchQueueView.swift
//  Echo macOS
//
//  Queue-management window for the persistent macOS batch pipeline. Lists every
//  `batch_queue` item with its live status/progress and lets the user clear
//  finished entries. Reads the `MacBatchProcessingService` from the environment.
//

import SwiftUI

struct MacBatchQueueView: View {
    @Environment(MacBatchProcessingService.self) private var service

    var body: some View {
        VStack(spacing: 0) {
            if service.items.isEmpty {
                ContentUnavailableView(
                    "No Books Queued",
                    systemImage: "square.stack.3d.up",
                    description: Text("Add a folder to process books overnight."))
            } else {
                List(service.items) { item in MacBatchQueueRow(item: item) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear Completed") { service.clearCompleted() }
                    .disabled(!service.items.contains { $0.status == .completed })
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { service.refresh() }
    }
}

private struct MacBatchQueueRow: View {
    let item: BatchQueueRecord

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.headline)
                if let msg = item.statusMessage ?? item.errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                if item.status != .queued && item.status != .completed
                    && item.status != .failed
                {
                    ProgressView(value: item.progress)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: some View {
        Group {
            switch item.status {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .importing:
                Image(systemName: "square.and.arrow.down").foregroundStyle(.blue)
            case .transcribing: Image(systemName: "waveform").foregroundStyle(.blue)
            case .aligning: Image(systemName: "text.alignleft").foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 24)
    }
}
