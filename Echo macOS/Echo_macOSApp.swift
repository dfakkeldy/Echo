// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_macOSApp.swift
//  Echo macOS
//
//  Native macOS entry point for the Echo AudioBooks Mac app.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct Echo_macOSApp: App {
    @State private var player = MacPlayerModel()
    /// Shared user-preferences store. macOS had no SettingsManager instance
    /// before the Settings scene existed; this is the single source of truth
    /// injected into both the main window and the Settings scene.
    @State private var settings = SettingsManager()
    @State private var transcriptionManager = TranscriptionManager()
    @State private var transcriptStore = TranscriptStore()
    /// Shared database — falls back to in-memory if the App Group DB is unavailable.
    @State private var dbService: DatabaseService
    @State private var lastOpenToken: UUID = UUID()

    // WS-12: Anki export state
    @State private var showAnkiExport = false

    /// Persistent batch pipeline (import → transcribe → align → word timings).
    /// Survives app restart; the queue lives in the shared database.
    @State private var batchService: MacBatchProcessingService
    @State private var showBatchQueue = false

    init() {
        // Resolve the shared database once, then hand the same instance to the
        // batch service so both the queue and the rest of the app write through
        // a single `DatabaseService`/writer.
        let db = (try? DatabaseService()) ?? Self.makeInMemoryDB()
        _dbService = State(initialValue: db)
        _batchService = State(initialValue: MacBatchProcessingService(dbService: db))
    }

    var body: some Scene {
        WindowGroup("Echo AudioBooks") {
            MacTriPaneView()
                .environment(player)
                .environment(transcriptionManager)
                .environment(transcriptStore)
                .environment(dbService)
                .environment(settings)
                .environment(batchService)
                .preferredColorScheme(Self.colorScheme(for: settings.appAppearance))
                .frame(minWidth: 900, minHeight: 560)
                // Reset any items interrupted by a previous quit, then resume.
                .task { batchService.resumeOnLaunch() }
                .onChange(of: player.openFileRequestToken) { _, newValue in
                    if newValue != lastOpenToken {
                        lastOpenToken = newValue
                        showOpenPanel()
                    }
                }
                // WS-12 sheets
                .sheet(isPresented: $showBatchQueue) {
                    MacBatchQueueView()
                        .environment(batchService)
                }
                .sheet(isPresented: $showAnkiExport) {
                    MacAnkiExportView()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audiobook…") {
                    player.requestOpenFile()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Export Transcript…") {
                    NotificationCenter.default.post(name: .requestExportTranscript, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find in Book") {
                    NotificationCenter.default.post(name: .requestFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!player.hasMedia)
            }

            CommandMenu("View") {
                Button("Toggle Notes Pane") {
                    NotificationCenter.default.post(name: .requestToggleDetailPane, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
            }

            CommandMenu("Batch") {
                Button("Open Batch Queue") {
                    showBatchQueue = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Add Folder to Queue…") {
                    if let folder = chooseBatchFolder() {
                        try? FolderAudioScanner.enqueueFolder(folder, into: batchService)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }

            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.hasMedia)

                Divider()

                Button("Skip Back") {
                    player.skip(by: -Double(player.skipInterval))
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!player.hasMedia)

                Button("Skip Forward") {
                    player.skip(by: Double(player.skipInterval))
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!player.hasMedia)

                Divider()

                Button("Previous Chapter") {
                    player.previousChapter()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(player.chapters.count < 2 || player.currentChapterIndex <= 0)

                Button("Next Chapter") {
                    player.nextChapter()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(
                    player.chapters.count < 2
                        || player.currentChapterIndex >= player.chapters.count - 1)

                Divider()

                Button("Skip Back 30s") {
                    player.skip(by: -30)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!player.hasMedia)

                Button("Skip Forward 30s") {
                    player.skip(by: 30)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!player.hasMedia)
            }

            CommandMenu("Study") {
                Button("Bookmark") {
                    player.addBookmarkAtCurrentTime()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(!player.hasMedia)

                Button("Mark Passage") {
                    markPassage()
                }
                .keyboardShortcut("m", modifiers: [.command])
                .disabled(!player.hasMedia)

                Button("New Note") {
                    NotificationCenter.default.post(name: .requestNewNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!player.hasMedia)

                Divider()

                Button("Export for Anki…") {
                    showAnkiExport = true
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(player)
                .environment(dbService)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - Actions

    /// Marks the current playback position as a passage for later flashcard
    /// conversion, via the shared database's MarkedPassageDAO.
    private func markPassage() {
        guard let audiobookID = player.audiobookID, player.hasMedia else { return }
        let dao = MarkedPassageDAO(db: dbService.writer)
        try? dao.insert(
            audiobookID: audiobookID,
            mediaTimestamp: player.currentTime,
            endTimestamp: nil,
            transcriptSnippet: nil,
            note: nil
        )
    }

    // MARK: - Open Panel

    /// Presents an NSOpenPanel to select a folder of audiobooks to add to the
    /// persistent batch queue. Returns the chosen folder, or `nil` if cancelled.
    /// Enqueuing (and processing) is handled by `MacBatchProcessingService`.
    private func chooseBatchFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Audiobook Folder to Batch Queue")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(
            localized:
                "Choose a folder containing audiobooks (M4B/MP3/M4A) with companion EPUB files."
        )

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Audiobook…")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = String(
            localized: "Select an audiobook file or folder containing audio files.")
        let audioTypes: [UTType] = [
            .audio, .mp3, .mpeg4Audio,
            UTType(filenameExtension: "aiff") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
            UTType(filenameExtension: "ogg") ?? .audio,
            UTType(filenameExtension: "opus") ?? .audio,
            UTType(filenameExtension: "wma") ?? .audio,
            UTType(filenameExtension: "flac") ?? .audio,
        ]
        panel.allowedContentTypes = audioTypes
        if panel.runModal() == .OK, let url = panel.url {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                player.loadFolder(url: url)
            } else {
                player.open(url: url)
            }
        }
    }

    // MARK: - Helpers

    /// Maps the stored `appAppearance` string ("System"/"Light"/"Dark") to a
    /// SwiftUI `ColorScheme?` — `nil` means follow the OS. Mirrors the iOS
    /// helper in `SettingsView.colorScheme(for:)` so both platforms agree.
    static func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    /// In-memory database used as a safe fallback when the shared App Group
    /// database cannot be initialised (first launch, no entitlements, etc.).
    ///
    /// A single attempt — the previous `(try? …) ?? (try! …)` form repeated the
    /// identical initializer, so the `try!` could only ever crash with the same
    /// failure the `try?` had just swallowed: a redundant trap with a useless
    /// diagnostic (CODE_AUDIT §5.3). If even an in-memory SQLite store cannot
    /// open, the process has no database to run on at all, so fail loudly with a
    /// clear message rather than a bare `try!` re-trap.
    private static func makeInMemoryDB() -> DatabaseService {
        do {
            return try DatabaseService(inMemory: ())
        } catch {
            fatalError(
                "Echo could not open even an in-memory database — SQLite is unavailable: \(error)")
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user presses the "New Note" menu command.
    static let requestNewNote = Notification.Name("com.echo.requestNewNote")
    /// Posted when the user presses "Find in Book".
    static let requestFocusSearch = Notification.Name("com.echo.requestFocusSearch")
    /// Posted when the user presses "Toggle Notes Pane".
    static let requestToggleDetailPane = Notification.Name("com.echo.requestToggleDetailPane")
    /// Posted when the user presses "Export Transcript".
    static let requestExportTranscript = Notification.Name("com.echo.requestExportTranscript")
}
