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
    @State private var transcriptionManager = TranscriptionManager()
    @State private var transcriptStore = TranscriptStore()
    /// Shared database — falls back to in-memory if the App Group DB is unavailable.
    @State private var dbService: DatabaseService = {
        (try? DatabaseService()) ?? Self.makeInMemoryDB()
    }()
    @State private var lastOpenToken: UUID = UUID()

    var body: some Scene {
        WindowGroup("Echo AudioBooks") {
            MacTriPaneView()
                .environment(player)
                .environment(transcriptionManager)
                .environment(transcriptStore)
                .environment(dbService)
                .frame(minWidth: 900, minHeight: 560)
                .onChange(of: player.openFileRequestToken) { _, newValue in
                    if newValue != lastOpenToken {
                        lastOpenToken = newValue
                        showOpenPanel()
                    }
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

            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.hasMedia)

                Divider()

                Button("Skip Back 15s") {
                    player.skip(by: -15)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!player.hasMedia)

                Button("Skip Forward 15s") {
                    player.skip(by: 15)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!player.hasMedia)

                Divider()

                Button("Previous Chapter") {
                    player.previousTrack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!player.hasMultipleTracks)

                Button("Next Chapter") {
                    player.nextTrack()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!player.hasMultipleTracks)

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
            }
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

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Audiobook…")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = String(localized: "Select an audiobook file or folder containing audio files.")
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
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                player.loadFolder(url: url)
            } else {
                player.open(url: url)
            }
        }
    }

    // MARK: - Helpers

    /// In-memory database used as a safe fallback when the shared App Group
    /// database cannot be initialised (first launch, no entitlements, etc.).
    private static func makeInMemoryDB() -> DatabaseService {
        (try? DatabaseService(inMemory: ())) ?? (try! DatabaseService(inMemory: ()))
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
