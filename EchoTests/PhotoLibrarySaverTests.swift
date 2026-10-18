// SPDX-License-Identifier: GPL-3.0-or-later
import Photos
import Testing
import UIKit

@testable import Echo

@MainActor
struct PhotoLibrarySaverTests {
    private let image = UIImage()

    @Test func authorizedRequestSaves() async {
        var didSave = false
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .authorized },
            performSave: { _ in didSave = true })
        #expect(await saver.save(image) == .saved)
        #expect(didSave)
    }

    @Test func limitedAccessStillSaves() async {
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .limited },
            performSave: { _ in })
        #expect(await saver.save(image) == .saved)
    }

    @Test func deniedNeverAttemptsSave() async {
        var didSave = false
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .denied },
            performSave: { _ in didSave = true })
        #expect(await saver.save(image) == .denied)
        #expect(!didSave)
    }

    @Test func saveErrorReportsFailure() async {
        struct Boom: Error {}
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .authorized },
            performSave: { _ in throw Boom() })
        #expect(await saver.save(image) == .failed)
    }
}
