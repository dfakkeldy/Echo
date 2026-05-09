//
//  AuDioHDApp.swift
//  AuDioHD
//
//  Created by Dan Fakkeldy on 2026-04-19.
//

import SwiftUI

@main
struct AuDioHDApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        MockMediaProvider.seedSampleAudiobookIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
