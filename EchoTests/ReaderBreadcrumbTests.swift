import Testing
import Foundation
import GRDB
@testable import Echo

/// Tests for the reader's pinned-header breadcrumb (`headingStack`).
///
/// With a publisher-declared TOC persisted, the breadcrumb must reflect TOC
/// ancestry — "1. A Pragmatic Philosophy › Topic 3. Software Entropy ›
/// Challenges" — instead of the heading-level cascade that pinned the last
/// `<h1>` ("Foreword") as a permanent top-level ancestor.
@MainActor
struct ReaderBreadcrumbTests {

    private func makeBlock(
        id: String,
        spine: Int,
        seq: Int,
        kind: EPubBlockRecord.Kind,
        text: String
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book-1",
            spineHref: "s\(spine).xhtml",
            spineIndex: spine,
            blockIndex: seq,
            sequenceIndex: seq,
            blockKind: kind.rawValue,
            text: text,
            chapterIndex: 0,
            isHidden: false,
            wordCount: 5
        )
    }

    private func makeDatabase() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        return db
    }

    @Test func breadcrumbFollowsTOCAncestry() throws {
        let db = try makeDatabase()
        let blocks = [
            makeBlock(id: "b0", spine: 1, seq: 0, kind: .heading, text: "Chapter 1 A Pragmatic Philosophy"),
            makeBlock(id: "b1", spine: 1, seq: 1, kind: .paragraph, text: "This book is about you."),
            makeBlock(id: "b2", spine: 2, seq: 2, kind: .heading, text: "Topic 3 Software Entropy"),
            makeBlock(id: "b3", spine: 2, seq: 3, kind: .paragraph, text: "Entropy hits us hard."),
            makeBlock(id: "b4", spine: 2, seq: 4, kind: .heading, text: "Challenges"),
            makeBlock(id: "b5", spine: 2, seq: 5, kind: .paragraph, text: "How do you react?"),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
        try EPubTOCEntryDAO(db: db.writer).insertAll([
            EPubTOCEntryRecord(
                id: "t0", audiobookID: "book-1", parentID: nil, orderIndex: 0,
                depth: 0, title: "1. A Pragmatic Philosophy", blockID: "b0", spineIndex: 1
            ),
            EPubTOCEntryRecord(
                id: "t1", audiobookID: "book-1", parentID: "t0", orderIndex: 1,
                depth: 1, title: "Topic 3. Software Entropy", blockID: "b2", spineIndex: 2
            ),
        ])

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        // #require so a wrong section count fails the test instead of
        // trapping on the subscripts below.
        try #require(vm.sections.count == 3)
        #expect(vm.sections[0].headingStack == ["1. A Pragmatic Philosophy"])
        #expect(vm.sections[1].headingStack == ["1. A Pragmatic Philosophy", "Topic 3. Software Entropy"])
        #expect(vm.sections[2].headingStack == [
            "1. A Pragmatic Philosophy", "Topic 3. Software Entropy", "Challenges",
        ])
    }

    @Test func breadcrumbNeverInheritsEarlierSiblingChapterAsAncestor() throws {
        // The regression: "Foreword" (an h1) stayed at breadcrumb level 1
        // forever because "Chapter …" text forced later titles to level 2.
        let db = try makeDatabase()
        let blocks = [
            makeBlock(id: "b0", spine: 0, seq: 0, kind: .heading, text: "Foreword"),
            makeBlock(id: "b1", spine: 0, seq: 1, kind: .paragraph, text: "I remember the tweet."),
            makeBlock(id: "b2", spine: 1, seq: 2, kind: .heading, text: "Chapter 1 A Pragmatic Philosophy"),
            makeBlock(id: "b3", spine: 1, seq: 3, kind: .paragraph, text: "This book is about you."),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
        try EPubTOCEntryDAO(db: db.writer).insertAll([
            EPubTOCEntryRecord(
                id: "t0", audiobookID: "book-1", parentID: nil, orderIndex: 0,
                depth: 0, title: "Foreword", blockID: "b0", spineIndex: 0
            ),
            EPubTOCEntryRecord(
                id: "t1", audiobookID: "book-1", parentID: nil, orderIndex: 1,
                depth: 0, title: "1. A Pragmatic Philosophy", blockID: "b2", spineIndex: 1
            ),
        ])

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        let chapterSection = try #require(
            vm.sections.first { $0.items.contains { item in
                if case .block(let b) = item { return b.id == "b3" }
                return false
            }}
        )
        #expect(chapterSection.headingStack == ["1. A Pragmatic Philosophy"])
        #expect(!chapterSection.headingStack.contains("Foreword"))
    }

    @Test func withoutTOCEntriesSectionsStillBuild() throws {
        let db = try makeDatabase()
        try EPubBlockDAO(db: db.writer).insertAll([
            makeBlock(id: "b0", spine: 0, seq: 0, kind: .heading, text: "Chapter One"),
            makeBlock(id: "b1", spine: 0, seq: 1, kind: .paragraph, text: "Hello."),
        ])

        let vm = ReaderFeedViewModel(audiobookID: "book-1", db: db.writer)
        vm.reload()

        #expect(!vm.sections.isEmpty)
        #expect(vm.sections.first?.headingStack.contains("Chapter One") == true)
    }
}
