// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ArticleInboxService: Sendable {
    static let productionDeletionQuarantineLimit = 128

    enum DeletionPoint: Equatable, Sendable {
        case beforeDatabaseCommit
        case beforeQuarantineCleanup
    }

    enum Error: Swift.Error, LocalizedError {
        case captureNotFound(String)
        case emptySelection
        case invalidCaptureID(String)
        case captureIsReferenced([String])
        case unsafePackagePath(URL)
        case unsafeOwnedDirectory(URL)
        case unsafeQuarantineResidue(URL)
        case tooManyQuarantineResidues(Int)
        case restoreFailed(original: String, restore: String)

        var errorDescription: String? {
            switch self {
            case .captureNotFound:
                return "This article is no longer in the Inbox."
            case .emptySelection:
                return "Select at least one article for the anthology."
            case .invalidCaptureID:
                return "This article has an invalid capture identifier."
            case .captureIsReferenced(let names):
                return "This article is used by: \(names.joined(separator: ", "))."
            case .unsafePackagePath:
                return "Echo refused to delete an article package outside its managed storage."
            case .unsafeOwnedDirectory:
                return
                    "Echo refused to delete an article package that is not a regular managed folder."
            case .unsafeQuarantineResidue(let url):
                return "Echo refused to reconcile an unsafe deletion residue at \(url.path)."
            case .tooManyQuarantineResidues(let limit):
                return
                    "Echo refused to reconcile more than \(limit) deletion residues in one pass."
            case .restoreFailed(let original, let restore):
                return
                    "Deletion failed (\(original)), and the article package could not be restored (\(restore))."
            }
        }
    }

    private let captureDAO: ArticleCaptureDAO
    private let anthologyDAO: AnthologyDAO
    private let fileStore: ArticleWorkshopFileStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let deletionQuarantineLimit: Int
    private let deletionHook: (@Sendable (DeletionPoint, URL) throws -> Void)?

    init(
        captureDAO: ArticleCaptureDAO,
        anthologyDAO: AnthologyDAO,
        fileStore: ArticleWorkshopFileStore,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        deletionQuarantineLimit: Int = ArticleInboxService.productionDeletionQuarantineLimit,
        deletionHook: (@Sendable (DeletionPoint, URL) throws -> Void)? = nil
    ) {
        self.captureDAO = captureDAO
        self.anthologyDAO = anthologyDAO
        self.fileStore = fileStore
        self.now = now
        self.makeID = makeID
        self.deletionQuarantineLimit = deletionQuarantineLimit
        self.deletionHook = deletionHook
    }

    func inboxItems() throws -> [ArticleInboxItem] {
        try reconcileDeletionQuarantine()
        let records = try captureDAO.captures()
        return
            records
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt > $1.capturedAt
                }
                return $0.id < $1.id
            }
            .map { record in
                item(for: record, among: records)
            }
    }

    func anthologies() throws -> [AnthologyRecord] {
        try anthologyDAO.all()
    }

    func createAnthologySeed(title: String, captureIDs: [String]) throws -> AnthologyRecord {
        guard captureIDs.isEmpty == false else { throw Error.emptySelection }

        let timestamp = now().ISO8601Format()
        let anthology = AnthologyRecord(
            id: makeID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "New Anthology" : title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: nil,
            creator: "Echo",
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        do {
            return try anthologyDAO.create(anthology, captureIDs: captureIDs)
        } catch AnthologyDAOError.captureNotFound(let captureID) {
            throw Error.captureNotFound(captureID)
        }
    }

    func deletionImpact(for id: String) throws -> ArticleDeletionImpact {
        guard try captureDAO.capture(id: id) != nil else {
            throw Error.captureNotFound(id)
        }
        let names = try anthologyDAO.referencingAnthologies(captureID: id)
            .map(\.title)
            .uniqued()
            .sorted()
        return names.isEmpty ? .unreferenced : .referenced(projectNames: names)
    }

    func delete(id: String) throws {
        let impact = try deletionImpact(for: id)
        if impact.isReferenced {
            throw Error.captureIsReferenced(impact.projectNames)
        }
        guard let record = try captureDAO.capture(id: id) else {
            throw Error.captureNotFound(id)
        }
        guard let captureID = UUID(uuidString: record.id) else {
            throw Error.invalidCaptureID(record.id)
        }

        let fileManager = FileManager.default
        let root = fileStore.root.standardizedFileURL
        let capturesRoot = root.appending(path: "Captures", directoryHint: .isDirectory)
            .standardizedFileURL
        let expected =
            capturesRoot
            .appending(path: captureID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        let claimed = URL(fileURLWithPath: record.packagePath, isDirectory: true)
            .standardizedFileURL

        guard claimed == expected,
            expected.deletingLastPathComponent() == capturesRoot,
            capturesRoot.deletingLastPathComponent() == root
        else {
            throw Error.unsafePackagePath(claimed)
        }
        guard try isRegularDirectory(root),
            try isRegularDirectory(capturesRoot),
            try isRegularDirectory(expected)
        else {
            throw Error.unsafeOwnedDirectory(expected)
        }

        let quarantineRoot = root.appending(
            path: ".DeletionQuarantine", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: quarantineRoot.path) {
            guard try isRegularDirectory(quarantineRoot) else {
                throw Error.unsafeOwnedDirectory(quarantineRoot)
            }
        } else {
            try fileManager.createDirectory(
                at: quarantineRoot,
                withIntermediateDirectories: false
            )
        }
        let quarantine = quarantineRoot.appending(
            path: "\(captureID.uuidString)-\(makeID().uuidString)",
            directoryHint: .isDirectory
        )
        guard fileManager.fileExists(atPath: quarantine.path) == false else {
            throw Error.unsafeOwnedDirectory(quarantine)
        }

        try fileManager.moveItem(at: expected, to: quarantine)
        do {
            try deletionHook?(.beforeDatabaseCommit, quarantine)
            switch try captureDAO.deleteCaptureIfUnreferenced(id: id) {
            case .deleted:
                break
            case .notFound:
                throw Error.captureNotFound(id)
            case .referenced(let projectNames):
                throw Error.captureIsReferenced(projectNames)
            }
        } catch {
            do {
                try fileManager.moveItem(at: quarantine, to: expected)
                removeEmptyDirectoryIfPresent(quarantineRoot)
            } catch let restoreError {
                throw Error.restoreFailed(
                    original: error.localizedDescription,
                    restore: restoreError.localizedDescription
                )
            }
            throw error
        }

        do {
            try deletionHook?(.beforeQuarantineCleanup, quarantine)
            try fileManager.removeItem(at: quarantine)
            removeEmptyDirectoryIfPresent(quarantineRoot)
        } catch {
            // The database deletion is the logical commit point. A safe,
            // recognized quarantine is retried during a later Inbox load.
        }
    }

    private func reconcileDeletionQuarantine() throws {
        let fileManager = FileManager.default
        let root = fileStore.root.standardizedFileURL
        let quarantineRoot = root.appending(
            path: ".DeletionQuarantine", directoryHint: .isDirectory
        ).standardizedFileURL
        guard fileManager.fileExists(atPath: quarantineRoot.path) else { return }
        guard try isRegularDirectory(root),
            quarantineRoot.deletingLastPathComponent() == root,
            try isRegularDirectory(quarantineRoot)
        else {
            throw Error.unsafeQuarantineResidue(quarantineRoot)
        }

        var enumerationFailureURL: URL?
        guard
            let enumerator = fileManager.enumerator(
                at: quarantineRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { url, _ in
                    enumerationFailureURL = url
                    return false
                }
            )
        else {
            throw Error.unsafeQuarantineResidue(quarantineRoot)
        }

        var entries: [URL] = []
        while let object = enumerator.nextObject() {
            guard let entry = object as? URL else {
                throw Error.unsafeQuarantineResidue(quarantineRoot)
            }
            entries.append(entry)
            if entries.count > deletionQuarantineLimit {
                throw Error.tooManyQuarantineResidues(deletionQuarantineLimit)
            }
        }
        if let enumerationFailureURL {
            throw Error.unsafeQuarantineResidue(enumerationFailureURL)
        }

        var validatedEntries: [URL] = []
        for entry in entries {
            guard entry.standardizedFileURL.deletingLastPathComponent() == quarantineRoot,
                try isRegularDirectory(entry),
                let captureID = captureID(inQuarantineEntry: entry),
                try captureDAO.capture(id: captureID.uuidString) == nil
            else {
                throw Error.unsafeQuarantineResidue(entry)
            }
            validatedEntries.append(entry)
        }

        for entry in validatedEntries {
            try fileManager.removeItem(at: entry)
        }
        removeEmptyDirectoryIfPresent(quarantineRoot)
    }

    private func captureID(inQuarantineEntry entry: URL) -> UUID? {
        let name = entry.lastPathComponent
        guard name.count == 73 else { return nil }
        let captureEnd = name.index(name.startIndex, offsetBy: 36)
        guard name[captureEnd] == "-" else { return nil }
        let captureIDString = String(name[..<captureEnd])
        let nonceString = String(name[name.index(after: captureEnd)...])
        guard let captureID = UUID(uuidString: captureIDString),
            let nonce = UUID(uuidString: nonceString),
            name == "\(captureID.uuidString)-\(nonce.uuidString)"
        else {
            return nil
        }
        return captureID
    }

    private func removeEmptyDirectoryIfPresent(_ directory: URL) {
        let fileManager = FileManager.default
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? fileManager.removeItem(at: directory)
        }
    }

    private func item(
        for record: ArticleCaptureRecord,
        among records: [ArticleCaptureRecord]
    ) -> ArticleInboxItem {
        var warnings: [String]
        var warningDecodeFailed = false
        do {
            warnings = try JSONDecoder().decode([String].self, from: Data(record.warningsJSON.utf8))
        } catch {
            warnings = ["Capture warnings could not be read."]
            warningDecodeFailed = true
        }

        let state: ArticleInboxPresentationState
        switch record.contentState {
        case ArticleContentState.ready.rawValue:
            state = warningDecodeFailed ? .reviewSuggested : .ready
        case ArticleContentState.reviewSuggested.rawValue:
            state = .reviewSuggested
        case ArticleContentState.captureFailed.rawValue:
            state = .captureFailed
        default:
            state = .captureFailed
            warnings.append("Unknown capture state: \(record.contentState)")
        }

        let isDuplicate = records.contains { candidate in
            guard candidate.id != record.id else { return false }
            let sameCanonicalURL =
                record.canonicalURL.flatMap { canonicalURL in
                    candidate.canonicalURL == canonicalURL ? true : nil
                } ?? false
            return candidate.sourceURL == record.sourceURL
                || sameCanonicalURL
                || (record.contentSHA256.isEmpty == false
                    && candidate.contentSHA256 == record.contentSHA256)
        }

        return ArticleInboxItem(
            id: record.id,
            title: record.title,
            author: record.author,
            siteName: record.siteName,
            sourceURL: record.sourceURL,
            canonicalURL: record.canonicalURL,
            capturedAt: record.capturedAt,
            state: state,
            warnings: warnings,
            isPossibleDuplicate: isDuplicate,
            keepBothAvailable: true
        )
    }

    private func isRegularDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

extension Sequence where Element: Hashable {
    fileprivate nonisolated func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
