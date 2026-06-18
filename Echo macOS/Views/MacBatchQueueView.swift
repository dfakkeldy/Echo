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
    @Environment(MacPlayerModel.self) private var player
    // A macOS sheet has no titlebar toolbar, so the `.toolbar` modifier's
    // controls would never render — the user could be stranded in the modal
    // (opened via ⌘⇧B). Drive an explicit Done button from `dismiss` instead.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                if service.items.isEmpty {
                    ContentUnavailableView(
                        "No Books Queued",
                        systemImage: "square.stack.3d.up",
                        description: Text("Add a folder to process books overnight."))
                } else {
                    List(service.items) { item in
                        MacBatchQueueRow(
                            item: item,
                            // A narration book can be opened straight into the player
                            // (its tracks come from the DB, since rendered files live
                            // outside any scanned folder) once it has reached a
                            // terminal state AND produced at least one chapter — so a
                            // `.failed` book that stopped mid-way (e.g. a vocoder
                            // failure) is still playable up to where it got.
                            onOpen: (item.kind == .narrate
                                && (item.status == .completed || item.status == .failed)
                                && service.hasRenderedTracks(for: item.audiobookID))
                                ? {
                                    player.loadNarratedBook(audiobookID: item.audiobookID)
                                    dismiss()
                                }
                                : nil)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { service.refresh() }
    }

    /// Inline header bar standing in for the absent sheet titlebar: title,
    /// "Clear Completed", and a cancel-role "Done" (also fired by Escape).
    private var header: some View {
        HStack {
            Text("Batch Queue")
                .font(.headline)
            Spacer()
            Button("Clear Completed") { service.clearCompleted() }
                .disabled(!service.items.contains { $0.status == .completed })
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct MacBatchQueueRow: View {
    let item: BatchQueueRecord
    /// Non-nil for a completed narrated book: opens it in the player.
    var onOpen: (() -> Void)? = nil

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
            if let onOpen {
                Spacer()
                Button("Open", action: onOpen)
                    .buttonStyle(.borderless)
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
