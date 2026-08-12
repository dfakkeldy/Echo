// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct EditionMatcherTests {
    @Test func normalizedKeyIgnoresPunctuationCaseAndLeadingArticles() {
        #expect(
            EditionMatcher.normalizedKey(title: "The High-Conflict Couple!")
                == "high conflict couple")
        #expect(
            EditionMatcher.normalizedKey(title: "A  Tale_of Two Cities") == "tale of two cities")
    }

    @Test func groupsOnlyMatchingTitleAndAuthorPairs() {
        let groups = EditionMatcher.groups(for: [
            .init(id: "audio", title: "The High-Conflict Couple", author: "Alan Fruzzetti"),
            .init(id: "text", title: "High Conflict Couple", author: "Alan Fruzzetti"),
            .init(id: "other-author", title: "High Conflict Couple", author: "Other Author"),
            .init(id: "single", title: "Dune", author: "Frank Herbert"),
        ])

        #expect(groups["audio"] == groups["text"])
        #expect(groups["other-author"] == nil)
        #expect(groups["single"] == nil)
    }

    @Test func authorlessEditionJoinsSingleAuthoredGroup() {
        // A separately imported epub row (author nil) must pair with the tagged
        // audio edition when the title bucket has exactly one author.
        let groups = EditionMatcher.groups(for: [
            .init(id: "audio", title: "Dune", author: "Frank Herbert"),
            .init(id: "text", title: "The Dune", author: nil),
        ])

        #expect(groups["audio"] != nil)
        #expect(groups["audio"] == groups["text"])
    }

    @Test func authorlessEditionStaysUngroupedAmongCompetingAuthors() {
        // Two distinct authors share the title: per-author pairs still group,
        // but the author-less row is ambiguous and must never be guessed in.
        let groups = EditionMatcher.groups(for: [
            .init(id: "frost-audio", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "frost-text", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "plath", title: "Collected Poems", author: "Sylvia Plath"),
            .init(id: "orphan", title: "Collected Poems", author: nil),
        ])

        #expect(groups["frost-audio"] != nil)
        #expect(groups["frost-audio"] == groups["frost-text"])
        #expect(groups["plath"] == nil)
        #expect(groups["orphan"] == nil)
    }

    @Test func twoAuthorlessEditionsWithSameTitleGroup() {
        let groups = EditionMatcher.groups(for: [
            .init(id: "x", title: "The Dune", author: nil),
            .init(id: "y", title: "Dune", author: ""),
        ])

        #expect(groups["x"] != nil)
        #expect(groups["x"] == groups["y"])
    }

    @Test func singleBooksByDifferentAuthorsWithSameTitleStayUngrouped() {
        // One book per author on a shared title: no bucket has two members, so
        // author tolerance must not merge across authors.
        let groups = EditionMatcher.groups(for: [
            .init(id: "frost", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "plath", title: "Collected Poems", author: "Sylvia Plath"),
        ])

        #expect(groups.isEmpty)
    }

    // MARK: - Path identity

    @Test func sameFolderURLsWithDifferentTitlesGroup() {
        // The scanner titles a row from audio tags while a direct open titles it
        // from the folder name — the ids point at the same folder, so the title
        // mismatch must not keep the rows apart.
        let groups = EditionMatcher.groups(for: [
            .init(id: "file:///Books/AI%20-%20Unexplainable/", title: "AI", author: "Roman"),
            .init(
                id: "file:///Books/AI%20-%20Unexplainable",
                title: "AI - Unexplainable", author: nil),
        ])

        #expect(groups["file:///Books/AI%20-%20Unexplainable/"] != nil)
        #expect(
            groups["file:///Books/AI%20-%20Unexplainable/"]
                == groups["file:///Books/AI%20-%20Unexplainable"])
    }

    @Test func privatePrefixedPickerURLGroupsWithStandardizedScannerURL() throws {
        // Reproduces the real duplicate: the scanner stores the standardized
        // folder URL ("/tmp/…") while the document picker hands the loader the
        // "/private/tmp/…" form. Foundation only strips "/private" for paths
        // that exist, so this needs a real directory.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("echo-edition-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("Book", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let scannerID = folder.standardizedFileURL.absoluteString
        let pickerID = "file:///private\(folder.path)/"

        let groups = EditionMatcher.groups(for: [
            .init(id: scannerID, title: "Book", author: "Someone"),
            .init(id: pickerID, title: "Book Folder Name", author: nil),
        ])

        #expect(groups[scannerID] != nil)
        #expect(groups[scannerID] == groups[pickerID])
    }

    @Test func loneM4BFileRowJoinsItsSingleFileFolderRow() {
        // A directly opened m4b persists under its file URL; the scanner keys
        // the same book by its folder. They merge only because the folder row
        // claims exactly one audio file.
        let groups = EditionMatcher.groups(for: [
            .init(id: "file:///Books/Dune/", title: "Dune", author: "Frank", fileCount: 1),
            .init(id: "file:///Books/Dune/dune.m4b", title: "dune", author: nil),
        ])

        #expect(groups["file:///Books/Dune/"] != nil)
        #expect(groups["file:///Books/Dune/"] == groups["file:///Books/Dune/dune.m4b"])
    }

    @Test func fileRowsStaySeparateFromMultiBookFolderRow() {
        // A downloads-style folder holding several standalone m4bs: each file
        // is its own book, so nothing may collapse into the folder row.
        let groups = EditionMatcher.groups(for: [
            .init(id: "file:///Books/", title: "Books", author: nil, fileCount: 3),
            .init(id: "file:///Books/alpha.m4b", title: "Alpha", author: nil),
            .init(id: "file:///Books/beta.m4b", title: "Beta", author: nil),
        ])

        #expect(groups.isEmpty)
    }

    @Test func duplicateFileRowsGroupWithoutAFolderRow() {
        // The same m4b opened via both URL forms, no scanner row at all.
        let groups = EditionMatcher.groups(for: [
            .init(id: "file:///Books/dune.m4b", title: "Dune", author: nil),
            .init(id: "file:///Books/dune.m4b/", title: "dune", author: nil),
        ])

        #expect(groups["file:///Books/dune.m4b"] != nil)
        #expect(groups["file:///Books/dune.m4b"] == groups["file:///Books/dune.m4b/"])
    }

    @Test func pathClusterAbsorbsTitleGroupedTextEdition() {
        // An epub text row already title-paired with the audio folder row must
        // follow it into the path cluster, keeping all three on one card.
        let groups = EditionMatcher.groups(for: [
            .init(id: "file:///Books/Dune/", title: "Dune", author: "Frank", fileCount: 1),
            .init(id: "file:///Books/Dune/dune.m4b", title: "dune folder", author: nil),
            .init(id: "epub-import-id", title: "Dune", author: "Frank"),
        ])

        #expect(groups["file:///Books/Dune/"] != nil)
        #expect(groups["file:///Books/Dune/"] == groups["file:///Books/Dune/dune.m4b"])
        #expect(groups["file:///Books/Dune/"] == groups["epub-import-id"])
    }

    @Test func nonFileIDsNeverPathGroup() {
        // ABS/server rows use opaque ids; only real file URLs may path-cluster.
        let groups = EditionMatcher.groups(for: [
            .init(id: "abs-item-1", title: "Distinct One", author: nil),
            .init(id: "abs-item-2", title: "Distinct Two", author: nil),
        ])

        #expect(groups.isEmpty)
    }
}
