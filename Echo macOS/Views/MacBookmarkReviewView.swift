// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MacBookmarkReviewView: View {
    @Environment(MacPlayerModel.self) private var player
    @State private var filter: BookmarkReviewFilter = .all
    @State private var previewPlayer: SnippetPlayer?
    @State private var previewingMemoBookmarkID: UUID?
    @State private var didPauseMainPlayerForPreview = false
    @State private var editingBookmark: Bookmark?
    @State private var imagePreview: BookmarkImagePreview?

    private var items: [BookmarkReviewItem] {
        BookmarkReviewItem.items(from: player.bookmarkStore.bookmarks, filter: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            BookmarkReviewHeader(filter: $filter, bookmarkCount: player.bookmarkStore.bookmarks.count)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: filter.systemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    MacBookmarkReviewRow(
                        item: item,
                        folderURL: player.folderURL,
                        isPreviewingMemo: previewingMemoBookmarkID == item.id,
                        onJump: { jump(to: item.bookmark) },
                        onPreviewMemo: { toggleMemoPreview(for: item.bookmark) },
                        onPreviewImage: { previewImage(for: item) },
                        onEdit: { editingBookmark = item.bookmark },
                        onDelete: { player.deleteBookmark(item.bookmark) }
                    )
                }
                .listStyle(.plain)
            }
        }
        .onDisappear { stopMemoPreview(resumePlayback: false) }
        .sheet(item: $editingBookmark) { bookmark in
            MacBookmarkEditSheet(bookmark: bookmark) { updatedBookmark in
                player.updateBookmark(updatedBookmark)
            }
        }
        .sheet(item: $imagePreview) { preview in
            BookmarkImagePreviewSheet(preview: preview)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "No Bookmarks"
        case .pictures: "No Picture Bookmarks"
        case .voiceMemos: "No Voice Memos"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all: "Bookmarks from your iPhone appear here after sync."
        case .pictures: "Photo bookmarks from listening sessions appear here."
        case .voiceMemos: "Voice memo bookmarks from listening sessions appear here."
        }
    }

    private func jump(to bookmark: Bookmark) {
        player.jumpTo(bookmark)
        if !player.isPlaying {
            player.play()
        }
    }

    private func previewImage(for item: BookmarkReviewItem) {
        guard let url = item.bookmark.bookmarkImageURL(in: player.folderURL) else { return }
        imagePreview = BookmarkImagePreview(title: item.title, url: url)
    }

    private func toggleMemoPreview(for bookmark: Bookmark) {
        if previewingMemoBookmarkID == bookmark.id {
            stopMemoPreview(resumePlayback: true)
            return
        }

        guard let url = bookmark.voiceMemoURL(in: player.folderURL) else { return }
        stopMemoPreview(resumePlayback: false)

        if player.isPlaying {
            player.pause()
            didPauseMainPlayerForPreview = true
        } else {
            didPauseMainPlayerForPreview = false
        }

        previewingMemoBookmarkID = bookmark.id
        let snippetPlayer = SnippetPlayer()
        previewPlayer = snippetPlayer
        snippetPlayer.play(url: url, volume: voiceMemoGain(for: url)) {
            stopMemoPreview(resumePlayback: true)
        }
    }

    private func stopMemoPreview(resumePlayback: Bool) {
        previewPlayer?.stop()
        previewPlayer = nil
        previewingMemoBookmarkID = nil

        if resumePlayback, didPauseMainPlayerForPreview {
            didPauseMainPlayerForPreview = false
            player.play()
        } else if !resumePlayback {
            didPauseMainPlayerForPreview = false
        }
    }
}

private struct BookmarkReviewHeader: View {
    @Binding var filter: BookmarkReviewFilter
    let bookmarkCount: Int

    var body: some View {
        HStack {
            Text("Review")
                .font(.headline)
            Spacer()
            Text(bookmarkCount, format: .number)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Bookmark filter", selection: $filter) {
                ForEach(BookmarkReviewFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct MacBookmarkReviewRow: View {
    let item: BookmarkReviewItem
    let folderURL: URL?
    let isPreviewingMemo: Bool
    let onJump: () -> Void
    let onPreviewMemo: () -> Void
    let onPreviewImage: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onJump) {
                HStack(alignment: .top, spacing: 10) {
                    BookmarkThumbnail(bookmark: item.bookmark, folderURL: folderURL)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatHMS(item.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if let note = item.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        BookmarkMediaBadges(item: item)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Jump to bookmark")

            HStack(spacing: 6) {
                if item.imageFileName != nil {
                    Button("Preview Image", systemImage: "photo", action: onPreviewImage)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Preview picture")
                }

                if item.voiceMemoFileName != nil {
                    Button(
                        isPreviewingMemo ? "Stop Voice Memo" : "Preview Voice Memo",
                        systemImage: isPreviewingMemo ? "stop.circle.fill" : "play.circle.fill",
                        action: onPreviewMemo
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(isPreviewingMemo ? "Stop voice memo" : "Preview voice memo")
                }

                Button("Edit Bookmark", systemImage: "pencil", action: onEdit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Edit bookmark")

                Button("Delete Bookmark", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete bookmark")
            }
        }
        .padding(.vertical, 6)
    }
}

private struct BookmarkThumbnail: View {
    let bookmark: Bookmark
    let folderURL: URL?

    var body: some View {
        Group {
            if let url = bookmark.bookmarkImageURL(in: folderURL),
                let image = NSImage(contentsOf: url)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: bookmark.voiceMemoFileName == nil ? "bookmark.fill" : "waveform")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(.rect(cornerRadius: 6))
    }
}

private struct BookmarkMediaBadges: View {
    let item: BookmarkReviewItem

    var body: some View {
        HStack(spacing: 8) {
            if item.imageFileName != nil {
                Label("Picture", systemImage: "photo")
            }
            if item.voiceMemoFileName != nil {
                Label("Voice memo", systemImage: "waveform")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private struct MacBookmarkEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    let onSave: (Bookmark) -> Void
    @State private var title: String
    @State private var note: String
    @State private var timestamp: TimeInterval
    @State private var isEnabled: Bool

    init(bookmark: Bookmark, onSave: @escaping (Bookmark) -> Void) {
        self.bookmark = bookmark
        self.onSave = onSave
        _title = State(initialValue: bookmark.title)
        _note = State(initialValue: bookmark.note ?? "")
        _timestamp = State(initialValue: bookmark.timestamp)
        _isEnabled = State(initialValue: bookmark.isEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bookmark") {
                    TextField("Title", text: $title)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Time") {
                    HStack {
                        Text("Position")
                        Spacer()
                        Text(formatHMS(timestamp))
                            .foregroundStyle(.secondary)
                    }
                    Stepper("Adjust by 1 second", value: $timestamp, in: 0...(.greatestFiniteMagnitude), step: 1)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .bold()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func save() {
        var updated = bookmark
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = trimmedTitle.isEmpty ? "Bookmark" : trimmedTitle
        updated.note = trimmedNote.isEmpty ? nil : trimmedNote
        updated.timestamp = timestamp
        updated.isEnabled = isEnabled
        onSave(updated)
        dismiss()
    }
}

private struct BookmarkImagePreview: Identifiable {
    let title: String
    let url: URL

    var id: URL { url }
}

private struct BookmarkImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: BookmarkImagePreview

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(contentsOf: preview.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ContentUnavailableView("Picture Unavailable", systemImage: "photo")
            }

            Divider()

            HStack {
                Text(preview.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([preview.url])
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
