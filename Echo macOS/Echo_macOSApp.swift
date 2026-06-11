//
//  Echo_macOSApp.swift
//  Echo macOS
//
//  Native macOS entry point for the Echo AudioBooks Mac app.
//

import SwiftUI

@main
struct Echo_macOSApp: App {
    @State private var player = MacPlayerModel()

    var body: some Scene {
        WindowGroup("Echo AudioBooks") {
            MacContentView()
                .environment(player)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audiobook…") {
                    player.requestOpenFile()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("Playback") {
                Button(player.isPlaying ? String(localized: "Pause") : String(localized: "Play")) {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.hasMedia)

                Button("Skip Backward 30s") {
                    player.skip(by: -30)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!player.hasMedia)

                Button("Skip Forward 30s") {
                    player.skip(by: 30)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!player.hasMedia)

                Divider()

                Button("Add Bookmark") {
                    player.addBookmarkAtCurrentTime()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(!player.hasMedia)
            }
        }
    }
}
