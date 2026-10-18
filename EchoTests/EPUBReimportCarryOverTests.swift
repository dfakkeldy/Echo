// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// `.replaceAll` used to be literally `deleteAll` + re-insert, which destroyed
/// far more than the parse: `alignment_anchor` died with the CASCADE (human
/// anchors included), `study_plan_item` pins were blanked by SET NULL, and seven
/// FK-less columns were left pointing at ids that no longer existed. These tests
/// drive the real write transaction through `DatabaseService(inMemory:)`.
@MainActor
struct EPUBReimportCarryOverTests {

    // MARK: - User-authored block state

    @Test func hiddenAndColouredBlocksSurviveReplaceAll() throws {
        var hidden = block("epub-bk-s0-b0", text: "one two three", sequenceIndex: 0)
        hidden.isHidden = true
        hidden.hiddenReason = "user"
        var coloured = block("epub-bk-s0-b1", text: "four five six", sequenceIndex: 1)
        coloured.cardColor = "#FF8800"
        coloured.chapterThemeColor = "#112233"
        coloured.narrationText = "four five six, spoken"
        let db = try makeDatabase(prior: [hidden, coloured])

        // A fresh parse never carries user state, so the incoming rows are clean.
        let incoming = [
            block("epub-bk-s0-b0", text: "one two three", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "four five six", sequenceIndex: 1),
        ]
        let outcome = try replace(db, with: incoming)

        let rebuilt = try EPubBlockDAO(db: db.writer).allBlocks(for: "bk")
        let byID = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.id, $0) })
        let first = try #require(byID["epub-bk-s0-b0"])
        #expect(first.isHidden)
        #expect(first.hiddenReason == "user")
        let second = try #require(byID["epub-bk-s0-b1"])
        #expect(second.cardColor == "#FF8800")
        #expect(second.chapterThemeColor == "#112233")
        // Byte-identical text, so the FM-refined narration is still valid.
        #expect(second.narrationText == "four five six, spoken")
        #expect(outcome.carryOver.matchedExactly == 2)
        #expect(outcome.carryOver.sourceStableBlocks == 2)

        // The importer returns what it PERSISTED, not the raw parse — otherwise
        // callers would be handed blocks that claim to be visible.
        let returned = outcome.blocks.first { $0.id == "epub-bk-s0-b0" }
        #expect(returned?.isHidden == true)
    }

    // MARK: - Block identity

    /// `EPUBBlockParser` emits BOTH `epub-<book>-s<i>-b<j>` and
    /// `epub-<book>-generic-s<i>-b<j>`, and both collapse to the same portable
    /// suffix. Rebuilding an id from a suffix would silently retarget every
    /// generic block's anchor onto the named block sharing its position.
    @Test func genericBlockAnchorRestoresToItsOwnBlock() throws {
        let prior = [
            block("epub-bk-s0-b0", text: "alpha", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "bravo", sequenceIndex: 1),
            block("epub-bk-generic-s0-b1", text: "charlie", sequenceIndex: 2),
        ]
        let db = try makeDatabase(prior: prior)
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(anchor(id: "a-named", blockID: "epub-bk-s0-b1", audioTime: 10))
        try anchorDAO.insert(
            anchor(id: "a-generic", blockID: "epub-bk-generic-s0-b1", audioTime: 20))

        _ = try replace(db, with: prior)

        // The two ids really are suffix-identical — the trap is live, not theoretical.
        #expect(AlignmentSidecar.portableSuffix(of: "epub-bk-generic-s0-b1") == "s0-b1")
        #expect(AlignmentSidecar.portableSuffix(of: "epub-bk-s0-b1") == "s0-b1")

        let restored = try anchorDAO.anchors(for: "bk")
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        let named = try #require(byID["a-named"])
        let generic = try #require(byID["a-generic"])
        #expect(named.epubBlockID == "epub-bk-s0-b1")
        #expect(generic.epubBlockID == "epub-bk-generic-s0-b1")
    }

    /// When two prior blocks share a portable suffix and neither survives by
    /// exact id, the suffix pass must refuse rather than pick one — and the
    /// content pass, which never looks at an id, then picks the right one.
    @Test func ambiguousPortableSuffixIsRefusedThenResolvedByContent() throws {
        let prior = [
            block("epub-bk-s0-b1", text: "bravo", sequenceIndex: 0),
            block("epub-bk-generic-s0-b1", text: "charlie", sequenceIndex: 1),
        ]
        let db = try makeDatabase(prior: prior)
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(
            anchor(id: "a-generic", blockID: "epub-bk-generic-s0-b1", audioTime: 20))

        let incoming = [block("epub-bk-stable-s0-b1", text: "charlie", sequenceIndex: 0)]
        let outcome = try replace(db, with: incoming)

        // Suffix `s0-b1` is ambiguous on the prior side, so the suffix pass
        // declines. "charlie" is unique on both sides, so the content pass does
        // not — and it lands on the block that actually says "charlie", never on
        // the one that merely shared its suffix.
        #expect(outcome.carryOver.matchedBySuffix == 0)
        #expect(outcome.carryOver.matchedByContent == 1)
        #expect(outcome.carryOver.unresolvedPriorBlocks == 1)
        #expect(outcome.carryOver.anchorsDroppedUnresolved == 0)
        let remaining = try anchorDAO.anchors(for: "bk")
        #expect(remaining.map(\.epubBlockID) == ["epub-bk-stable-s0-b1"])
    }

    /// The content pass runs the same 1:1 discipline as the suffix pass: two
    /// prior blocks with identical text in the same spine file are unresolvable,
    /// and a guess would attach one block's notes to the other's.
    @Test func ambiguousContentIsRefusedRatherThanGuessed() throws {
        let prior = [
            block("epub-bk-s0-b3", text: "* * *", sequenceIndex: 0),
            block("epub-bk-s0-b9", text: "* * *", sequenceIndex: 1),
        ]
        let db = try makeDatabase(prior: prior)
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(anchor(id: "a-first", blockID: "epub-bk-s0-b3", audioTime: 20))

        let incoming = [block("epub-bk-s0-b4", text: "* * *", sequenceIndex: 0)]
        let outcome = try replace(db, with: incoming)

        #expect(outcome.carryOver.matchedBySuffix == 0)
        #expect(outcome.carryOver.matchedByContent == 0)
        #expect(outcome.carryOver.unresolvedPriorBlocks == 2)
        #expect(try anchorDAO.anchors(for: "bk").isEmpty)
    }

    /// The realistic "the ids moved" case, and the reason a content pass exists
    /// at all: Echo's documented front/back-matter merge re-chapters an EPUB, so
    /// a chapter keeps its `spine_href` and its text but lands at a new spine
    /// index. Neither id pass can see through that — the exact ids differ, and
    /// `s5-b1` versus `s3-b1` is no help either. Before the content pass every one
    /// of those blocks was "unresolved" and its notes, memos and cards were
    /// swept.
    @Test func reChapteredEditionCarriesUserStateAcrossMovedSpineIndices() throws {
        let prior = [
            block("epub-bk-s0-b0", text: "cover", sequenceIndex: 0, spineHref: "front.xhtml"),
            block(
                "epub-bk-s5-b0", text: "chapter five opening", sequenceIndex: 1,
                spineIndex: 5, spineHref: "ch5.xhtml"),
            block(
                "epub-bk-s5-b1", text: "chapter five second", sequenceIndex: 2,
                spineIndex: 5, spineHref: "ch5.xhtml"),
        ]
        let db = try makeDatabase(prior: prior)
        try seedPointerRows(db, blockID: "epub-bk-s5-b1", suffix: "b1")
        try seedStudyPlanPin(db, blockID: "epub-bk-s5-b1")

        // Front matter merged: ch5.xhtml is now spine item 3. Same file, same
        // words, new index.
        let incoming = [
            block("epub-bk-s0-b0", text: "cover", sequenceIndex: 0, spineHref: "front.xhtml"),
            block(
                "epub-bk-s3-b0", text: "chapter five opening", sequenceIndex: 1,
                spineIndex: 3, spineHref: "ch5.xhtml"),
            block(
                "epub-bk-s3-b1", text: "chapter five second", sequenceIndex: 2,
                spineIndex: 3, spineHref: "ch5.xhtml"),
        ]
        let outcome = try replace(db, with: incoming)

        #expect(outcome.carryOver.matchedExactly == 1)  // the cover
        #expect(outcome.carryOver.matchedBySuffix == 0)  // s5-b1 is not s3-b1
        #expect(outcome.carryOver.matchedByContent == 2)
        #expect(outcome.carryOver.unresolvedPriorBlocks == 0)

        // The user's note, memo, card, QA issue and study pin followed the words
        // they were attached to.
        let pins = try blockPins(db)
        for table in [
            "note", "voice_memo", "flashcard", "narration_quality_issue", "study_plan_item",
        ] {
            #expect(pins[table] == "epub-bk-s3-b1", "\(table) did not follow its block")
        }
        let dangling = try danglingPointerCounts(db)
        #expect(dangling.values.allSatisfy { $0 == 0 }, "\(dangling)")
    }

    /// The counter-case, and the reason the content pass is a *fallback* rather
    /// than the primary rule: when a replacement edition inserts a paragraph, the
    /// positional ids still all exist, so the exact pass claims every prior block
    /// and a user's pins stay at the place in the book they marked. Only
    /// `is_hidden` refuses to follow a slot whose words changed — it is the one
    /// carried column that makes content vanish.
    @Test func insertedParagraphKeepsPinsInPlaceButNotTheHiddenFlag() throws {
        var hidden = block("epub-bk-s0-b1", text: "publisher advertisement", sequenceIndex: 1)
        hidden.isHidden = true
        hidden.hiddenReason = "user"
        let prior = [
            block("epub-bk-s0-b0", text: "chapter one", sequenceIndex: 0),
            hidden,
        ]
        let db = try makeDatabase(prior: prior)
        try seedPointerRows(db, blockID: "epub-bk-s0-b1", suffix: "b1")

        // The advertisement is gone and a real paragraph now occupies s0-b1.
        let incoming = [
            block("epub-bk-s0-b0", text: "chapter one", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "a real paragraph of the chapter", sequenceIndex: 1),
        ]
        let outcome = try replace(db, with: incoming)

        #expect(outcome.carryOver.matchedExactly == 2)
        #expect(outcome.carryOver.unresolvedPriorBlocks == 0)
        let pins = try blockPins(db)
        #expect(pins["note"] == "epub-bk-s0-b1")

        let rebuilt = try EPubBlockDAO(db: db.writer).allBlocks(for: "bk")
        let replaced = try #require(rebuilt.first { $0.id == "epub-bk-s0-b1" })
        // Carrying the flag here would have hidden a real paragraph from the
        // reader feed, from narration, and from the timeline — silently.
        #expect(!replaced.isHidden)
        #expect(replaced.hiddenReason == nil)
    }

    @Test func anchorWhoseBlockVanishedIsDroppedNotRemapped() throws {
        let prior = [
            block("epub-bk-s0-b0", text: "alpha", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "bravo", sequenceIndex: 1),
        ]
        let db = try makeDatabase(prior: prior)
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(anchor(id: "keep", blockID: "epub-bk-s0-b0", audioTime: 5))
        try anchorDAO.insert(anchor(id: "orphan", blockID: "epub-bk-s0-b1", audioTime: 50))

        let outcome = try replace(db, with: [prior[0]])

        let remaining = try anchorDAO.anchors(for: "bk")
        #expect(remaining.map(\.id) == ["keep"])
        #expect(remaining.allSatisfy { $0.epubBlockID == "epub-bk-s0-b0" })
        #expect(outcome.carryOver.anchorsCaptured == 2)
        #expect(outcome.carryOver.anchorsRestored == 1)
        #expect(outcome.carryOver.anchorsDroppedUnresolved == 1)
    }

    // MARK: - Every block-id-bearing table

    /// Eight columns across seven tables carry an `epub_block.id`; only two of
    /// them have a foreign key. When a rebuild changes the id shape while keeping
    /// the portable position, every one of them must follow.
    @Test func everyBlockIDBearingTableIsRepinnedWhenIDsChangeShape() throws {
        let prior = [
            block("epub-bk-generic-s0-b0", text: "alpha beta", sequenceIndex: 0),
            block("epub-bk-generic-s0-b1", text: "gamma delta", sequenceIndex: 1),
        ]
        let db = try makeDatabase(prior: prior)
        try seedPointerRows(db, blockID: "epub-bk-generic-s0-b0", suffix: "b0")
        try seedStudyPlanPin(db, blockID: "epub-bk-generic-s0-b0")
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(anchor(id: "human", blockID: "epub-bk-generic-s0-b0", audioTime: 7))

        // Same positions, same text — only the id scheme moved.
        let incoming = [
            block("epub-bk-s0-b0", text: "alpha beta", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "gamma delta", sequenceIndex: 1),
        ]
        let outcome = try replace(db, with: incoming)

        #expect(outcome.carryOver.matchedBySuffix == 2)
        #expect(outcome.carryOver.sourceStableBlocks == 2)

        let repinned = outcome.carryOver.repinnedRows
        for table in [
            "word_timing", "pdf_block_page", "timeline_item", "note", "voice_memo",
            "flashcard", "narration_quality_issue", "study_plan_item",
        ] {
            #expect((repinned[table] ?? 0) > 0, "\(table) was not re-pinned")
        }

        let dangling = try danglingPointerCounts(db)
        #expect(dangling.values.allSatisfy { $0 == 0 }, "\(dangling)")

        // The anchor followed its block instead of dying with the CASCADE.
        let anchors = try anchorDAO.anchors(for: "bk")
        #expect(anchors.map(\.epubBlockID) == ["epub-bk-s0-b0"])
        #expect(anchors.map(\.id) == ["human"])
    }

    /// A block id is a deterministic function of the document
    /// (`epub-<book>-s<i>-b<j>`), so a pointer at a block that vanished is not
    /// garbage — it is the address the row re-attaches to when the right document
    /// comes back. NULLing it would turn "I replaced the EPUB with the wrong
    /// edition" into permanent loss, so the sweep counts dangling user pointers
    /// and changes nothing.
    @Test func userPointersSurviveABlockVanishingAndHealOnReimport() throws {
        let prior = [
            block("epub-bk-s0-b0", text: "alpha beta", sequenceIndex: 0),
            block("epub-bk-s0-b1", text: "gamma delta", sequenceIndex: 1),
        ]
        let db = try makeDatabase(prior: prior)
        try seedPointerRows(db, blockID: "epub-bk-s0-b1", suffix: "b1")
        try seedStudyPlanPin(db, blockID: "epub-bk-s0-b1")

        // The wrong edition: `gamma delta` is not in it at all.
        let outcome = try replace(db, with: [prior[0]])

        let survivors = try rowCounts(
            db,
            tables: [
                "note", "voice_memo", "flashcard", "narration_quality_issue",
                "word_timing", "pdf_block_page", "timeline_item",
            ])
        // Irreplaceable user rows survive, pointer and all.
        #expect(survivors["note"] == 1)
        #expect(survivors["voice_memo"] == 1)
        #expect(survivors["flashcard"] == 1)
        #expect(survivors["narration_quality_issue"] == 1)
        // Regenerable rows with a NOT NULL block id cannot represent an orphan.
        #expect(survivors["word_timing"] == 0)
        #expect(survivors["pdf_block_page"] == 0)
        // The `epub_block`-sourced timeline row is re-materialized by
        // `recalculateTimeline`, so deleting it is lossless; the note-sourced row
        // belongs to another producer and is left alone.
        #expect(survivors["timeline_item"] == 1)
        #expect(outcome.carryOver.deletedRows["word_timing"] == 1)
        #expect(outcome.carryOver.danglingRows["note"] == 1)
        #expect(outcome.carryOver.danglingRows["voice_memo"] == 1)
        #expect(outcome.carryOver.danglingRows["flashcard"] == 1)
        #expect(outcome.carryOver.danglingRows["narration_quality_issue"] == 1)
        // `study_plan_item` is the one pointer that CANNOT be stranded, and the
        // reason is structural rather than chosen: `source_block_id` is a real
        // foreign key (Schema_V25, `ON DELETE SET NULL`). SQLite blanked it on
        // the delete, and writing the old id back is not merely undesirable — it
        // is rejected, and the rejection aborts the whole import transaction.
        // So the pin is lost, and it is counted as lost.
        #expect(outcome.carryOver.danglingRows["study_plan_item"] == 1)

        let stranded = try blockPins(db)
        for table in ["note", "voice_memo", "flashcard", "narration_quality_issue"] {
            #expect(stranded[table] == "epub-bk-s0-b1", "\(table) lost its address")
        }
        #expect(stranded["study_plan_item"] == nil, "an FK column cannot hold a dead id")

        // The whole point: re-importing the right document re-attaches every
        // pointer that was allowed to keep its address, with no user action.
        _ = try replace(db, with: prior)

        let healed = try danglingPointerCounts(db)
        #expect(healed.values.allSatisfy { $0 == 0 }, "\(healed)")
        let pins = try blockPins(db)
        for table in ["note", "voice_memo", "flashcard", "narration_quality_issue"] {
            #expect(pins[table] == "epub-bk-s0-b1", "\(table) did not re-attach")
        }
        // Nothing recorded where this one pointed, so nothing can bring it back.
        // A study-plan item whose block vanishes keeps its own content and loses
        // only its source link — the asymmetry the FK forces on us.
        #expect(pins["study_plan_item"] == nil, "an FK pin cannot self-heal")
    }

    // MARK: - Position-following vs content-following state

    /// A note is pinned to a *place* in the book; a machine anchor is a
    /// measurement of specific *words*. When the wording changes the note must
    /// stay and the measurement must go, or read-along starts asserting that a
    /// timestamp taken against text A describes text B.
    ///
    /// A hand-placed anchor is neither: nothing can recompute a person's claim
    /// about where they are in the book, so it is kept even though the wording
    /// moved under it. `AlignmentAnchorRecord.humanAnchorSources` is the same
    /// allow-list `DocumentImportFinalizer.replaceMachineAnchors` honours.
    @Test func changedSourceTextKeepsUserPinsAndHandPlacedAnchorsOnly() throws {
        var prior = block("epub-bk-s0-b0", text: "alpha beta", sequenceIndex: 0)
        prior.isHidden = true
        prior.cardColor = "#123456"
        prior.narrationText = "alpha beta, spoken"
        let db = try makeDatabase(prior: [prior])
        try seedPointerRows(db, blockID: "epub-bk-s0-b0", suffix: "b1")
        let anchorDAO = AlignmentAnchorDAO(db: db.writer)
        try anchorDAO.insert(anchor(id: "human", blockID: "epub-bk-s0-b0", audioTime: 7))
        var machine = anchor(id: "machine", blockID: "epub-bk-s0-b0", audioTime: 9)
        machine.source = AlignmentAnchorRecord.Source.autoAlignment.rawValue
        try anchorDAO.insert(machine)

        // Same id, same position, different wording.
        let incoming = [block("epub-bk-s0-b0", text: "alpha gamma", sequenceIndex: 0)]
        let outcome = try replace(db, with: incoming)

        #expect(outcome.carryOver.sourceStableBlocks == 0)
        #expect(outcome.carryOver.anchorsCaptured == 2)
        #expect(outcome.carryOver.anchorsDroppedSourceChanged == 1)
        #expect(outcome.carryOver.anchorsRestored == 1)
        #expect(outcome.carryOver.humanAnchorsKeptAcrossSourceChange == 1)
        let anchors = try anchorDAO.anchors(for: "bk")
        #expect(anchors.map(\.id) == ["human"])

        let rebuilt = try EPubBlockDAO(db: db.writer).allBlocks(for: "bk")
        let only = try #require(rebuilt.first)
        #expect(only.text == "alpha gamma")
        #expect(only.cardColor == "#123456")
        // `is_hidden` describes words, not a slot: carrying it here would have
        // suppressed the new wording everywhere, silently.
        #expect(!only.isHidden)
        // A refinement of the OLD wording is not valid narration for the new.
        #expect(only.narrationText == nil)

        let counts = try rowCounts(db, tables: ["word_timing", "note"])
        #expect(counts["word_timing"] == 0)
        #expect(counts["note"] == 1)
        let pins = try blockPins(db)
        #expect(pins["note"] == "epub-bk-s0-b0")
    }

    // MARK: - Stale-source recovery fuse

    /// Recovery costs a full extract + re-parse, so the guard has to make a
    /// repeat on unchanged inputs impossible — the caller records the fingerprint
    /// *before* attempting, so the second call always sees `attempt == lastAttempt`.
    @Test func staleSourceRecoveryFuseCannotLoop() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "EPUBReimportCarryOver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "book.epub")
        let sidecarURL = directory.appending(path: "book.alignment.json")
        try Data("epub".utf8).write(to: sourceURL)
        try Data("[]".utf8).write(to: sidecarURL)

        let attempt = try #require(
            StaleSourceRecoveryAttempt(sourceURL: sourceURL, sidecarURL: sidecarURL))

        // First look at a `.staleSource` book: try once.
        #expect(
            EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                status: .staleSource, attempt: attempt, lastAttempt: nil))
        // Every later open with the same two files: never again.
        #expect(
            !EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                status: .staleSource, attempt: attempt, lastAttempt: attempt))

        // No other status may spend a re-import.
        for status in [
            SidecarImportSummary.Status.applied, .foundButUnresolved, .notDownloaded,
            .decodeError, .noSidecar,
        ] {
            #expect(
                !EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                    status: status, attempt: attempt, lastAttempt: nil),
                "\(status) must not trigger recovery")
        }
        // No snapshot at all, and un-fingerprintable files, are both no-ops.
        #expect(
            !EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                status: nil, attempt: attempt, lastAttempt: nil))
        #expect(
            !EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                status: .staleSource, attempt: nil, lastAttempt: nil))

        // A re-exported alignment file is a new revision and earns exactly one
        // more attempt.
        try Data("[{\"blockId\":\"s0-b0\"}]".utf8).write(to: sidecarURL)
        let refreshed = try #require(
            StaleSourceRecoveryAttempt(sourceURL: sourceURL, sidecarURL: sidecarURL))
        #expect(refreshed != attempt)
        #expect(
            EPUBAutoImportScanner.shouldAttemptStaleSourceRecovery(
                status: .staleSource, attempt: refreshed, lastAttempt: attempt))
    }

    /// Recovery force-re-imports a book's blocks on the strength of one claim:
    /// "this alignment file describes this document". A legacy sidecar carries no
    /// `sourceBlockIdentity` at all, so its blocks compare `.legacyCodeRequiresIdentity`
    /// against *any* document — it can never prove a match, only fail to disprove
    /// one. Acting on that would rebuild a book's blocks because of a file that
    /// might belong to a different book entirely.
    @Test func staleSourceRecoveryRefusesASidecarThatProvesNothing() throws {
        let legacy = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 0, confidence: nil),
            AlignmentSidecar.Anchor(blockId: "s0-b1", timestamp: 5, confidence: nil),
        ]
        #expect(!EPUBAutoImportScanner.sidecarProvesDocumentIdentity(legacy))

        #expect(!EPUBAutoImportScanner.sidecarProvesDocumentIdentity([]))

        // One identity-bearing anchor is enough to make the comparison meaningful;
        // the per-block verdicts then decide the rest.
        let mixed =
            legacy + [
                AlignmentSidecar.Anchor(
                    blockId: "s0-b2", timestamp: 9, confidence: nil,
                    sourceBlockIdentity: "abc123")
            ]
        #expect(EPUBAutoImportScanner.sidecarProvesDocumentIdentity(mixed))
    }

    @Test func recoveryFuseRoundTripsThroughBookPreferences() throws {
        let store = try #require(UserDefaults(suiteName: "stale-recovery-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "EPUBReimportCarryOver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "book.epub")
        let sidecarURL = directory.appending(path: "book.alignment.json")
        try Data("epub".utf8).write(to: sourceURL)
        try Data("[]".utf8).write(to: sidecarURL)
        let attempt = try #require(
            StaleSourceRecoveryAttempt(sourceURL: sourceURL, sidecarURL: sidecarURL))

        #expect(
            BookPreferencesService.loadStaleSourceRecoveryAttempt(for: "bk", store: store) == nil)
        BookPreferencesService.saveStaleSourceRecoveryAttempt(attempt, for: "bk", store: store)
        #expect(
            BookPreferencesService.loadStaleSourceRecoveryAttempt(for: "bk", store: store)
                == attempt)
        BookPreferencesService.saveStaleSourceRecoveryAttempt(nil, for: "bk", store: store)
        #expect(
            BookPreferencesService.loadStaleSourceRecoveryAttempt(for: "bk", store: store) == nil)
    }

    // MARK: - Helpers

    private func makeDatabase(prior: [EPubBlockRecord]) throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100.0)")
        }
        try EPubBlockDAO(db: db.writer).insertAll(prior)
        return db
    }

    @discardableResult
    private func replace(
        _ db: DatabaseService,
        with incoming: [EPubBlockRecord],
        audiobookID: String = "bk"
    ) throws -> EPUBBlockReplaceOutcome {
        try db.write { database in
            try EPUBImportService.replaceAllPreservingUserState(
                audiobookID: audiobookID,
                incomingBlocks: incoming,
                tocEntries: [],
                in: database)
        }
    }

    private func block(
        _ id: String,
        text: String,
        sequenceIndex: Int,
        spineIndex: Int = 0,
        spineHref: String = "chapter.xhtml"
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "bk",
            spineHref: spineHref,
            spineIndex: spineIndex,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            chapterIndex: 0,
            isHidden: false)
    }

    private func anchor(
        id: String,
        blockID: String,
        audioTime: TimeInterval
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id,
            audiobookID: "bk",
            epubBlockID: blockID,
            audioTime: audioTime,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.moveToNow.rawValue,
            note: nil,
            createdAt: nil,
            modifiedAt: nil)
    }

    /// One row in every table that stores a block id, all pointing at `blockID`.
    private func seedPointerRows(
        _ db: DatabaseService, blockID: String, suffix: String
    ) throws {
        try db.write { database in
            try database.execute(
                sql: """
                    INSERT INTO word_timing
                      (audiobook_id, epub_block_id, word_index, word,
                       audio_start_time, audio_end_time)
                    VALUES ('bk', ?, 0, 'alpha', 0.0, 1.0)
                    """,
                arguments: [blockID])
            try database.execute(
                sql: """
                    INSERT INTO pdf_block_page (audiobook_id, epub_block_id, page_index)
                    VALUES ('bk', ?, 3)
                    """,
                arguments: [blockID])
            try database.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time,
                       source_table, epub_block_id)
                    VALUES (?, 'bk', 'epub_block', 'Block', 0.0, 'epub_block', ?)
                    """,
                arguments: ["tl-epub-\(suffix)", blockID])
            try database.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time,
                       source_table, epub_block_id)
                    VALUES (?, 'bk', 'note', 'Note', 0.0, 'note', ?)
                    """,
                arguments: ["tl-note-\(suffix)", blockID])
            try database.execute(
                sql: """
                    INSERT INTO note (id, audiobook_id, text, media_timestamp, epub_block_id)
                    VALUES (?, 'bk', 'a note', 12.0, ?)
                    """,
                arguments: ["note-\(suffix)", blockID])
            try database.execute(
                sql: """
                    INSERT INTO voice_memo
                      (id, audiobook_id, epub_block_id, media_timestamp, file_path)
                    VALUES (?, 'bk', ?, 12.0, '/tmp/memo.m4a')
                    """,
                arguments: ["memo-\(suffix)", blockID])
            try database.execute(
                sql: """
                    INSERT INTO flashcard
                      (id, audiobook_id, front_text, back_text, media_timestamp, source_block_id)
                    VALUES (?, 'bk', 'Q', 'A', 12.0, ?)
                    """,
                arguments: ["card-\(suffix)", blockID])
            try database.execute(
                sql: """
                    INSERT INTO narration_quality_issue
                      (id, audiobook_id, source_block_id, audio_start_time, audio_end_time,
                       expected_text, heard_text, issue_type, confidence, status, created_at)
                    VALUES (?, 'bk', ?, 0.0, 1.0, 'expected', 'heard', 'omission', 0.9,
                            'open', '2026-08-16T00:00:00Z')
                    """,
                arguments: ["qa-\(suffix)", blockID])
        }
    }

    /// `study_plan_item` has no `audiobook_id`; it is reached through its plan,
    /// and SQLite blanks its pin via ON DELETE SET NULL before any sweep can see it.
    private func seedStudyPlanPin(_ db: DatabaseService, blockID: String) throws {
        try db.write { database in
            try database.execute(
                sql: """
                    INSERT INTO study_plan (id, audiobook_id, start_date, created_at, modified_at)
                    VALUES ('plan-1', 'bk', '2026-08-16', '2026-08-16', '2026-08-16')
                    """)
            try database.execute(
                sql: """
                    INSERT INTO study_plan_item
                      (id, plan_id, kind, source_block_id, ordinal, created_at, modified_at)
                    VALUES ('item-1', 'plan-1', 'block', ?, 0, '2026-08-16', '2026-08-16')
                    """,
                arguments: [blockID])
        }
    }

    /// Rows whose block-id column points at a block that no longer exists.
    private func danglingPointerCounts(_ db: DatabaseService) throws -> [String: Int] {
        let columns: [(table: String, column: String)] = [
            ("word_timing", "epub_block_id"),
            ("pdf_block_page", "epub_block_id"),
            ("timeline_item", "epub_block_id"),
            ("note", "epub_block_id"),
            ("voice_memo", "epub_block_id"),
            ("flashcard", "source_block_id"),
            ("narration_quality_issue", "source_block_id"),
            ("study_plan_item", "source_block_id"),
        ]
        return try db.read { database in
            var counts: [String: Int] = [:]
            for (table, column) in columns {
                let sql = """
                    SELECT COUNT(*) FROM \(table)
                    WHERE \(column) IS NOT NULL
                      AND NOT EXISTS (
                        SELECT 1 FROM epub_block b WHERE b.id = \(table).\(column)
                      )
                    """
                counts[table] = try Int.fetchOne(database, sql: sql) ?? 0
            }
            return counts
        }
    }

    /// Where each seeded user row currently points, keyed by table. `suffix` is
    /// the one handed to `seedPointerRows`.
    private func blockPins(
        _ db: DatabaseService, suffix: String = "b1"
    ) throws -> [String: String] {
        let columns: [(table: String, column: String, id: String)] = [
            ("note", "epub_block_id", "note-\(suffix)"),
            ("voice_memo", "epub_block_id", "memo-\(suffix)"),
            ("flashcard", "source_block_id", "card-\(suffix)"),
            ("narration_quality_issue", "source_block_id", "qa-\(suffix)"),
            ("study_plan_item", "source_block_id", "item-1"),
        ]
        return try db.read { database in
            var pins: [String: String] = [:]
            for (table, column, id) in columns {
                pins[table] = try String.fetchOne(
                    database,
                    sql: "SELECT \(column) FROM \(table) WHERE id = ?",
                    arguments: [id])
            }
            return pins
        }
    }

    private func rowCounts(_ db: DatabaseService, tables: [String]) throws -> [String: Int] {
        try db.read { database in
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table] =
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }
}
