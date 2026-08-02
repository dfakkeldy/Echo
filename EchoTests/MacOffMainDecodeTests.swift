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
    /// `MacVisualStageView`). Two independent, single-line checks (not one
    /// hardcoded multi-line signature): the attribute must sit on its own
    /// line — distinguishing the real annotation from the many mentions of
    /// "`@concurrent`" in surrounding doc-comment prose — and the
    /// declaration must still be `loadCGImage`. Neither check embeds the
    /// full parameter list, so a rename/rewrap of unrelated parameters can't
    /// break this for reasons unrelated to the annotation itself.
    @Test func macImageDecodeLoadCGImageStaysConcurrent() throws {
        let src = try MacSource.read("Services/MacImageDecode.swift")
        #expect(
            src.contains("\n    @concurrent\n"),
            "loadCGImage must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` runs ON the caller's (main) actor, not off it."
        )
        #expect(
            src.contains("func loadCGImage("),
            "The @concurrent attribute above must still be immediately followed by the loadCGImage declaration."
        )
        #expect(
            src.contains("debugLoadCGImageRanOnMainThread = Mutex<Bool?>(nil)"),
            "The executor-observation seam must stay in place for future manual/harness verification."
        )
    }

    /// Site B: `MacArtworkLoader.load`, the cover-art decode used by
    /// `MacPlayerModel.loadCoverArt(for:)`. Same two-independent-checks
    /// shape as Site A.
    @Test func macArtworkLoaderLoadStaysConcurrent() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("\n    @concurrent\n"),
            "MacArtworkLoader.load must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` runs ON the caller's (main) actor, not off it."
        )
        #expect(
            src.contains("func load("),
            "The @concurrent attribute above must still be immediately followed by MacArtworkLoader's load declaration."
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
    /// an unstructured `Task` inherits the enclosing actor. Same
    /// two-independent-checks shape as Site A.
    @Test func transcriptStoreReadIndexStaysConcurrent() throws {
        let src = try MacSource.read("Views/TranscriptStore.swift")
        #expect(
            src.contains("\n    @concurrent\n"),
            "readIndex must stay @concurrent — under this project's SWIFT_APPROACHABLE_CONCURRENCY build setting, plain `nonisolated async` called from an unstructured Task inside a @MainActor class runs ON the main thread, not off it."
        )
        #expect(
            src.contains("func readIndex("),
            "The @concurrent attribute above must still be immediately followed by the readIndex declaration."
        )
        #expect(
            src.contains("debugReadIndexRanOnMainThread = Mutex<Bool?>(nil)"),
            "The executor-observation seam must stay in place for future manual/harness verification."
        )
    }

    /// The stale claim this whole task exists to correct: the doc comment
    /// must no longer assert that plain `nonisolated async` alone is
    /// sufficient to leave the main actor. This is independent of
    /// `transcriptStoreReadIndexStaysConcurrent` above (which only checks
    /// the attribute's placement, not the comment's wording) — it fails on
    /// its own if either half regresses: the exact stale sentence
    /// reappearing, or the corrective sentence disappearing.
    @Test func transcriptStoreDocCommentNoLongerClaimsBareNonisolatedAsyncIsOffMain() throws {
        let src = try MacSource.read("Views/TranscriptStore.swift")
        #expect(
            !src.contains(
                "Pure directory scan + JSON decode + word-frequency compute, off-main."),
            "The stale doc comment claiming off-main-ness with no @concurrent backing it must not return."
        )
        #expect(
            src.contains("Do not drop `@concurrent` under the assumption that"),
            "The corrected doc comment must warn that plain `nonisolated async` does NOT suspend off-main under this project's SWIFT_APPROACHABLE_CONCURRENCY setting."
        )
    }
}
