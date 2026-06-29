// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_macOSApp.swift
//  Echo macOS
//
//  Native macOS entry point for the Echo AudioBooks Mac app.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct Echo_macOSApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var player: MacPlayerModel
    /// Shared user-preferences store. macOS had no SettingsManager instance
    /// before the Settings scene existed; this is the single source of truth
    /// injected into the main window, the Settings scene, and the batch service
    /// (which reads the narration-voice preference). Created in `init` so the
    /// same instance can be handed to `MacBatchProcessingService`.
    @State private var settings: SettingsManager
    @State private var transcriptionManager: TranscriptionManager
    @State private var transcriptStore: TranscriptStore
    /// Shared database — falls back to in-memory if the App Group DB is unavailable.
    @State private var dbService: DatabaseService
    @State private var lastOpenToken: UUID = UUID()

    // WS-12: Anki export state
    @State private var showAnkiExport = false
    @State private var showAudioExport = false

    /// Persistent batch pipeline (import → transcribe → align → word timings).
    /// Survives app restart; the queue lives in the shared database.
    @State private var batchService: MacBatchProcessingService
    @State private var showBatchQueue = false

    init() {
        // Resolve the shared database once, then hand the same instance to the
        // batch service so both the queue and the rest of the app write through
        // a single `DatabaseService`/writer.
        let player = MacPlayerModel()
        let transcriptionManager = TranscriptionManager()
        let transcriptStore = TranscriptStore()
        let db = Self.makeLaunchDatabase()
        let settings = SettingsManager()
        let batchService = MacBatchProcessingService(dbService: db, settings: settings)
        _player = State(initialValue: player)
        _transcriptionManager = State(initialValue: transcriptionManager)
        _transcriptStore = State(initialValue: transcriptStore)
        _dbService = State(initialValue: db)
        _settings = State(initialValue: settings)
        _batchService = State(initialValue: batchService)
        MetricKitDiagnosticsController.shared.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                MacAppDelegate.scheduleWindowActivationPasses()
            }
        }
    }

    var body: some Scene {
        Window("Echo AudioBooks", id: "main") {
            MacTriPaneView()
                .environment(player)
                .environment(transcriptionManager)
                .environment(transcriptStore)
                .environment(dbService)
                .environment(settings)
                .environment(batchService)
                .preferredColorScheme(Self.colorScheme(for: settings.appAppearance))
                .tint(Self.tintColor(for: settings.themeColor))
                .customFont(.body, appFont: settings.appFont)
                .frame(minWidth: 900, minHeight: 560)
                .background(MacMainWindowActivator())
                // Restore after the window exists so startup cannot block launch/quit handling.
                .task {
                    player.restoreLastFileAfterLaunch()
                    batchService.resumeOnLaunch()
                }
                .onChange(of: player.openFileRequestToken) { _, newValue in
                    if newValue != lastOpenToken {
                        lastOpenToken = newValue
                        showOpenPanel()
                    }
                }
                // The reader's idle-state "Narrate an EPUB" nudge routes here so
                // it reuses the same picker as the Batch ▸ "Narrate EPUB(s)…" command.
                .onReceive(NotificationCenter.default.publisher(for: .requestNarrateEPUBs)) { _ in
                    narrateEPUBs()
                }
                // WS-12 sheets
                .sheet(isPresented: $showBatchQueue) {
                    MacBatchQueueView()
                        .environment(batchService)
                        .environment(player)
                }
                .sheet(isPresented: $showAnkiExport) {
                    MacAnkiExportView()
                }
                .sheet(isPresented: $showAudioExport) {
                    if let id = player.audiobookID, let db = player.dbService?.writer {
                        MacAudioExportView(
                            audiobookID: id,
                            bookTitle: player.currentTitle,
                            databaseWriter: db)
                    }
                }
        }
        .defaultLaunchBehavior(.presented)
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

                Button("Export Audiobook (.m4b)…") {
                    showAudioExport = true
                }
                .disabled(player.audiobookID == nil)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find in Book") {
                    NotificationCenter.default.post(name: .requestFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!player.hasMedia)
            }

            CommandMenu("View") {
                Button("Toggle Review Pane") {
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

                Button("Narrate EPUB(s)…") {
                    narrateEPUBs()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
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
        _ = try? dao.insert(
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

    /// Presents an NSOpenPanel to select EPUB or text files and/or folders to
    /// narrate on-device. Returns the chosen URLs (empty if cancelled). Folders
    /// are scanned for EPUBs; individual `.epub`, `.md`, `.markdown`, `.txt`, or
    /// `.text` files are enqueued directly.
    private func chooseEPUBsToNarrate() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Narrate EPUB(s)")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            .plainText,
        ]
        panel.message = String(
            localized: "Choose EPUB files (or a folder of them) to narrate on-device overnight.")

        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Prompts for EPUB(s) to narrate, enqueues them, and — if anything was
    /// enqueued — opens the Batch Queue so the user gets immediate feedback
    /// (synthesis runs in the background, so without this there was no visible
    /// sign anything happened, success or failure).
    private func narrateEPUBs() {
        let urls = chooseEPUBsToNarrate()
        for url in urls { narrateSelection(url) }
        if !urls.isEmpty { showBatchQueue = true }
    }

    /// Enqueues a selected URL for narration: a folder is scanned for EPUBs, an
    /// `.epub`, `.md`, `.markdown`, `.txt`, or `.text` file is enqueued directly;
    /// anything else is ignored.
    private func narrateSelection(_ url: URL) {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            try? FolderAudioScanner.enqueueEPUBsForNarration(url, into: batchService)
        } else if ["epub", "md", "markdown", "txt", "text"].contains(url.pathExtension.lowercased())
        {
            try? batchService.enqueueNarration(epubURL: url)
        }
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

    static func tintColor(for themeColor: String) -> Color {
        ThemeColor(rawValue: themeColor)?.color ?? .accentColor
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

    private static func makeLaunchDatabase() -> DatabaseService {
        #if DEBUG
            return makeInMemoryDB()
        #else
            return (try? DatabaseService()) ?? makeInMemoryDB()
        #endif
    }
}

private struct MacMainWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowHostingView {
        MainWindowHostingView()
    }

    func updateNSView(_ nsView: MainWindowHostingView, context: Context) {
        nsView.activateAttachedWindow()
    }

    final class MainWindowHostingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            activateAttachedWindow()
        }

        @MainActor
        func activateAttachedWindow() {
            Task { @MainActor in
                await Task.yield()
                MacAppDelegate.orderMainWindowFront(preferred: window)
            }
        }
    }
}

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Self.scheduleWindowActivationPasses()
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if !flag {
            Self.orderMainWindowFront()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    @MainActor
    fileprivate static func scheduleWindowActivationPasses() {
        orderMainWindowFront()
        let delays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2)]
        for delay in delays {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                orderMainWindowFront()
            }
        }
    }

    @MainActor
    fileprivate static func orderMainWindowFront(preferred: NSWindow? = nil) {
        if let window = preferred, window.canBecomeMain {
            orderFront(window)
            return
        }

        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isVisible }) {
            orderFront(window)
            return
        }

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            orderFront(window)
        }
    }

    @MainActor
    private static func orderFront(_ window: NSWindow) {
        window.title = "Echo AudioBooks"
        window.setAccessibilityRole(.window)
        window.setAccessibilitySubrole(.standardWindow)
        window.setAccessibilityLabel("Echo AudioBooks")
        window.setAccessibilityIdentifier("main")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user presses the "New Note" menu command.
    static let requestNewNote = Notification.Name("com.echo.requestNewNote")
    /// Posted when the user presses "Find in Book".
    static let requestFocusSearch = Notification.Name("com.echo.requestFocusSearch")
    /// Posted when the user presses "Toggle Review Pane".
    static let requestToggleDetailPane = Notification.Name("com.echo.requestToggleDetailPane")
    /// Posted when the user presses "Export Transcript".
    static let requestExportTranscript = Notification.Name("com.echo.requestExportTranscript")
    /// Posted by the reader's idle "Narrate an EPUB" nudge to open the picker.
    static let requestNarrateEPUBs = Notification.Name("com.echo.requestNarrateEPUBs")
}
