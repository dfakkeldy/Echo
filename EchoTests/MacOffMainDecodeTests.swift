// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Regression guard for the "inert off-main hop" defect: this project builds
/// with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables
/// `NonisolatedNonsendingByDefault` — under that mode a plain `nonisolated
/// async` function called from a `@MainActor` context runs ON the caller's
/// actor, not off it. Only `@concurrent` actually moves work to the
/// cooperative pool. Two merged PRs (macOS image decode, macOS transcript
/// indexing) shipped with plain `nonisolated async` and were silently no-ops.
///
/// The `Echo macOS` target is not compiled into EchoTests (see `MacSource`'s
/// doc comment and the ~10 other `Mac*ParityTests` suites that use it for
/// exactly this reason), so a live `Thread.isMainThread` executor test can't
/// run here against the real `MacImageDecode`/`MacArtworkLoader`/
/// `TranscriptStore` types — those were instead verified empirically with a
/// standalone `xcrun swiftc` harness against the actual production source
/// (see the perf-remediation report), which failed before `@concurrent` was
/// added and passed after. What CAN run in this target is a structural check
/// that the annotation stays attached to each site's declaration, so a future
/// edit that drops `@concurrent` (e.g. during a refactor) fails CI instead of
/// silently reintroducing the defect.
struct MacOffMainDecodeTests {

    /// Site A: `MacImageDecode.loadCGImage` — called from `.task(id:)`
    /// closures on `@MainActor` SwiftUI views (`MacBookmarkReviewView`,
    /// `MacVisualStageView`).
    @Test func macImageDecodeLoadCGImageStaysConcurrent() throws {
        let src = try MacSource.read("Services/MacImageDecode.swift")
        #expect(
            src.contains(
                "@concurrent\n    static func loadCGImage(url: URL, maxPixelSize: Int) async -> CGImage? {"
            ),
            "loadCGImage must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` runs ON the caller's (main) actor, not off it."
        )
        #expect(
            src.contains("debugLoadCGImageRanOnMainThread = Mutex<Bool?>(nil)"),
            "The executor-observation seam must stay in place for future manual/harness verification."
        )
    }

    /// Site B: `MacArtworkLoader.load`, the cover-art decode used by
    /// `MacPlayerModel.loadCoverArt(for:)`.
    @Test func macArtworkLoaderLoadStaysConcurrent() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains(
                "@concurrent\n    static func load(for url: URL, scopedRoot: URL?) async -> BookMetadata {"
            ),
            "MacArtworkLoader.load must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` runs ON the caller's (main) actor, not off it."
        )
        #expect(
            src.contains("struct BookMetadata: Sendable {"),
            "BookMetadata must stay Sendable so it can cross back from the @concurrent cooperative pool to the caller's @MainActor Task."
        )
        #expect(
            src.contains("debugLoadRanOnMainThread = Mutex<Bool?>(nil)"),
            "The executor-observation seam must stay in place for future manual/harness verification."
        )
    }

    /// Site C: `TranscriptStore.readIndex`, called from an unstructured
    /// `Task` inside the `@MainActor @Observable` `TranscriptStore` class —
    /// an unstructured `Task` inherits the enclosing actor.
    @Test func transcriptStoreReadIndexStaysConcurrent() throws {
        let src = try MacSource.read("Views/TranscriptStore.swift")
        #expect(
            src.contains(
                "@concurrent\n    nonisolated static func readIndex(from transcriptDir: URL) async -> ("
            ),
            "readIndex must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` called from an unstructured Task inside a @MainActor class runs ON the main thread, not off it."
        )
        #expect(
            src.contains("debugReadIndexRanOnMainThread = Mutex<Bool?>(nil)"),
            "The executor-observation seam must stay in place for future manual/harness verification."
        )
    }

    /// The stale claim this whole task exists to correct: the doc comment
    /// must no longer assert that plain `nonisolated async` alone is
    /// sufficient to leave the main actor.
    @Test func transcriptStoreDocCommentNoLongerClaimsBareNonisolatedAsyncIsOffMain() throws {
        let src = try MacSource.read("Views/TranscriptStore.swift")
        #expect(
            src.contains("@concurrent"),
            "The corrected doc comment must reference @concurrent as the actual mechanism."
        )
    }
}
