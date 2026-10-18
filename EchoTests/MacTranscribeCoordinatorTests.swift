// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural drift-guard for the macOS transcription coordinator.
///
/// The `Echo macOS` target is not compiled into EchoTests, so this suite cannot
/// exercise `MacTranscribeCoordinator`'s *behavior* directly. It previously tried
/// to (gated `#if os(macOS)`), which meant it stripped to nothing on every scheme
/// and never ran. The coordinator is a near-verbatim clone of the iOS
/// `TranscribeBookCoordinator`, whose behavior IS covered in CI on the iOS scheme
/// by `TranscribeBookCoordinatorTests` (+ `TranscriptMaterializerTests`,
/// `StandaloneTranscriptionServiceTests`) — all the shared logic lives in EchoCore.
///
/// So instead of duplicating that behavioral coverage (which would need a new
/// macOS unit-test target + scheme wiring — fiddly `project.pbxproj` surgery), this
/// suite scans the macOS source with the repo's `MacSource` convention and locks
/// the hand-maintained macOS port to the same finalize / gating / provenance
/// contract, so it can't silently drift away from the proven iOS behavior. It runs
/// on the iOS scheme (no `#if` gate).
@Suite struct MacTranscribeCoordinatorTests {
    private func coordinatorSource() throws -> String {
        try MacSource.read("Services/MacTranscribeCoordinator.swift")
    }

    @Test func finalizeMaterializesAndStampsTranscriptProvenance() throws {
        let src = try coordinatorSource()
        #expect(
            src.contains(
                "TranscriptMaterializer.materialize(audiobookID: audiobookID, writer: writer)"))
        #expect(src.contains("book.textOrigin = \"transcript\""))
    }

    @Test func finalizeIsGatedOnFullUncancelledCompletion() throws {
        let src = try coordinatorSource()
        // Waits for the detached tail, then finalizes only on a complete, uncancelled run.
        #expect(src.contains("await service.waitUntilFinished()"))
        #expect(src.contains("!progress.isCancelled"))
        #expect(src.contains("progress.chaptersComplete >= progress.chaptersTotal"))
    }

    @Test func finalizeRequiresEveryChapterToHaveTranscriptRows() throws {
        let src = try coordinatorSource()
        #expect(
            src.contains(
                "hasTranscriptRows(audiobookID: audiobookID, chapterCount: chapters.count)"))
        #expect(src.contains("(0..<chapterCount).allSatisfy"))
    }

    @Test func clearDelegatesToTheTranscriptionService() throws {
        let src = try coordinatorSource()
        #expect(src.contains("func clearTranscript(audiobookID: String)"))
        #expect(src.contains("await service.clearTranscript(audiobookID: audiobookID)"))
    }
}
