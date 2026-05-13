//
//  Orbit_AudioBooksApp.swift
//  Orbit Audiobooks
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import SwiftUI

@main
struct Orbit_AudioBooksApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        MockMediaProvider.seedSampleAudiobookIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "orbitaudio", url.host == "play" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let timeQuery = components?.queryItems?.first(where: { $0.name == "time" }),
           let timeValue = Double(timeQuery.value ?? "") {
            NotificationCenter.default.post(
                name: NSNotification.Name("SeekToTimestamp"),
                object: timeValue
            )
        }
    }
}
