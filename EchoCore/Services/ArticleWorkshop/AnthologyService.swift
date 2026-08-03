// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct AnthologyService: Sendable {
    enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case anthologyNotFound
        case emptyAnthology
        case invalidSelection
        case invalidStoredData
        case invalidProjectEdit
        case invalidVoice
        case revisionConflict

        var errorDescription: String? {
            switch self {
            case .anthologyNotFound:
                return "This anthology is no longer available."
            case .emptyAnthology:
                return "Add at least one article before building."
            case .invalidSelection:
                return "One or more selected articles are no longer available."
            case .invalidStoredData:
                return "This anthology contains saved data that could not be read safely."
            case .invalidProjectEdit:
                return "That anthology change could not be saved safely."
            case .invalidVoice:
                return "That narration voice is not available."
            case .revisionConflict:
                return "An article changed while the anthology was being prepared. Try again."
            }
        }
    }

    private let captureDAO: ArticleCaptureDAO
    private let anthologyDAO: AnthologyDAO
    private let fileStore: ArticleWorkshopFileStore
    private let coverStore: AnthologyCoverStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    init(
        captureDAO: ArticleCaptureDAO,
        anthologyDAO: AnthologyDAO,
        fileStore: ArticleWorkshopFileStore = ArticleWorkshopFileStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.captureDAO = captureDAO
        self.anthologyDAO = anthologyDAO
        self.fileStore = fileStore
        self.coverStore = AnthologyCoverStore(root: fileStore.root)
        self.now = now
        self.makeID = makeID
    }

    init(
        db: DatabaseService,
        fileStore: ArticleWorkshopFileStore = ArticleWorkshopFileStore()
    ) {
        self.init(
            captureDAO: ArticleCaptureDAO(db: db.writer),
            anthologyDAO: AnthologyDAO(db: db.writer),
            fileStore: fileStore)
    }

    func projects() throws -> [AnthologyRecord] {
        try anthologyDAO.all()
    }

    func availableCaptures(anthologyID: String) throws -> [ArticleCaptureRecord] {
        guard let snapshot = try databaseSnapshot(id: anthologyID) else {
            throw Error.anthologyNotFound
        }
        let existing = Set(snapshot.entries.map(\.capture.id))
        return try captureDAO.captures()
            .filter {
                existing.contains($0.id) == false
                    && Self.buildEligibleContentState($0.contentState)
                    && (try? validateCaptureMaterial($0)) != nil
            }
    }

    func createProject(
        title: String,
        subtitle: String? = nil,
        creator: String? = nil,
        captureIDs: [String]
    ) throws -> AnthologyProject {
        guard captureIDs.isEmpty == false, Set(captureIDs).count == captureIDs.count else {
            throw Error.invalidSelection
        }
        do {
            try prevalidateSelection(captureIDs)
        } catch {
            throw Error.invalidSelection
        }
        let date = now()
        let timestamp = Self.timestamp(date)
        let record = AnthologyRecord(
            id: makeID().uuidString,
            title: Self.requiredTitle(title),
            subtitle: Self.optionalText(subtitle),
            creator: Self.optionalText(creator),
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: timestamp,
            modifiedAt: timestamp)
        do {
            _ = try anthologyDAO.create(
                record,
                captureIDs: captureIDs,
                makeEntryID: makeID)
            return try loadProject(id: record.id)
        } catch is AnthologyDAOError {
            throw Error.invalidSelection
        }
    }

    func loadProject(id: String) throws -> AnthologyProject {
        guard let snapshot = try databaseSnapshot(id: id) else {
            throw Error.anthologyNotFound
        }
        return try materialize(snapshot)
    }

    func updateProject(
        anthologyID: String,
        title: String,
        subtitle: String?,
        creator: String?,
        coverPath: String?
    ) throws -> AnthologyProject {
        var project = try loadProject(id: anthologyID)
        project.anthology.title = title
        project.anthology.subtitle = subtitle
        project.anthology.creator = creator
        project.anthology.coverPath = coverPath
        return try saveDraft(project)
    }

    func updateEntry(
        anthologyID: String,
        entryID: String,
        chapterTitleOverride: String?,
        narrationVoiceID: String?
    ) throws -> AnthologyProject {
        let project = try loadProject(id: anthologyID)
        guard project.entries.contains(where: { $0.entry.id == entryID }) else {
            throw Error.invalidProjectEdit
        }
        return try saveDraft(
            project.updatingEntry(
                id: entryID,
                chapterTitleOverride: chapterTitleOverride,
                narrationVoiceID: narrationVoiceID))
    }

    func reorder(anthologyID: String, entryIDs: [String]) throws -> AnthologyProject {
        let project = try loadProject(id: anthologyID)
        guard entryIDs.count == project.entries.count,
            Set(entryIDs) == Set(project.entries.map(\.entry.id))
        else {
            throw Error.invalidProjectEdit
        }
        return try saveDraft(project.reordering(entryIDs: entryIDs))
    }

    func removeEntry(anthologyID: String, entryID: String) throws -> AnthologyProject {
        let project = try loadProject(id: anthologyID)
        guard project.entries.contains(where: { $0.entry.id == entryID }) else {
            throw Error.invalidProjectEdit
        }
        return try saveDraft(project.removing(entryID: entryID))
    }

    func addCaptures(_ captureIDs: [String], to anthologyID: String) throws
        -> AnthologyProject
    {
        guard captureIDs.isEmpty == false, Set(captureIDs).count == captureIDs.count else {
            throw Error.invalidSelection
        }
        do {
            try prevalidateSelection(captureIDs)
        } catch {
            throw Error.invalidProjectEdit
        }
        do {
            _ = try anthologyDAO.addCaptures(
                captureIDs,
                to: anthologyID,
                modifiedAt: Self.timestamp(now()),
                makeEntryID: makeID)
        } catch {
            throw Self.mapDAOError(error)
        }
        return try loadProject(id: anthologyID)
    }

    func saveDraft(_ project: AnthologyProject) throws -> AnthologyProject {
        guard UUID(uuidString: project.anthology.id) != nil,
            project.entries.map(\.entry.sortOrder) == Array(0..<project.entries.count),
            Set(project.entries.map(\.entry.id)).count == project.entries.count,
            project.entries.allSatisfy({
                $0.entry.anthologyID == project.anthology.id
                    && $0.entry.captureID == $0.capture.id
            })
        else {
            throw Error.invalidProjectEdit
        }
        let requestedCover = try Self.coverPath(project.anthology.coverPath)
        let storedCover: String?
        do {
            guard let stored = try anthologyDAO.anthology(id: project.anthology.id) else {
                throw Error.anthologyNotFound
            }
            storedCover = stored.coverPath
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidProjectEdit
        }
        let normalizedCover =
            requestedCover == storedCover
            ? requestedCover
            : try managedCoverPath(
                requestedCover,
                anthologyID: project.anthology.id)
        var anthology = project.anthology
        anthology.title = Self.requiredTitle(anthology.title)
        anthology.subtitle = Self.optionalText(anthology.subtitle)
        anthology.creator = Self.optionalText(anthology.creator)
        anthology.coverPath = normalizedCover
        anthology.modifiedAt = Self.timestamp(now())

        var entries = project.entries
        for index in entries.indices {
            let voice = Self.optionalText(entries[index].entry.narrationVoiceID)
            if let voice, VoiceCatalog.voice(for: VoiceID(voice)) == nil {
                throw Error.invalidVoice
            }
            entries[index].entry.sortOrder = index
            entries[index].entry.chapterTitleOverride = Self.optionalText(
                entries[index].entry.chapterTitleOverride)
            entries[index].entry.narrationVoiceID = voice
        }
        do {
            try anthologyDAO.saveDraft(
                anthology: anthology,
                entries: entries.map(\.entry),
                expectedEntryIDs: project.persistedEntryIDs,
                modifiedAt: anthology.modifiedAt)
        } catch {
            throw Self.mapDAOError(error)
        }

        var saved = AnthologyProject(
            anthology: anthology,
            entries: entries,
            persistedEntryIDs: Set(entries.map(\.entry.id)),
            latestSuccessfulBuild: project.latestSuccessfulBuild,
            changesAvailable: project.latestSuccessfulBuild != nil)
        if let prior = try frozenManifest(from: project.latestSuccessfulBuild),
            entries.allSatisfy({ $0.revision != nil && $0.cleanArticle != nil })
        {
            let current = try manifest(for: saved, revision: prior.revision)
            saved.changesAvailable = Self.differs(current, from: prior)
        }
        return saved
    }

    func prepareManifest(anthologyID: String) throws -> AnthologyBuildManifest {
        guard var snapshot = try databaseSnapshot(id: anthologyID) else {
            throw Error.anthologyNotFound
        }
        guard snapshot.entries.isEmpty == false else {
            throw Error.emptyAnthology
        }
        try validate(snapshot)

        if snapshot.entries.contains(where: { $0.revision == nil }) {
            for entry in snapshot.entries where entry.revision == nil {
                try publishBaselineIfNeeded(entry)
            }
            guard let reloaded = try databaseSnapshot(id: anthologyID) else {
                throw Error.anthologyNotFound
            }
            snapshot = reloaded
            try validate(snapshot)
            guard snapshot.entries.allSatisfy({ $0.revision != nil }) else {
                throw Error.revisionConflict
            }
        }

        let project = try materialize(snapshot)
        return try manifest(for: project)
    }

    func changesAvailable(anthologyID: String) throws -> Bool {
        try loadProject(id: anthologyID).changesAvailable
    }

    private func publishBaselineIfNeeded(_ entry: AnthologyDatabaseEntrySnapshot) throws {
        let source: ArticleSnapshot
        do {
            source = try fileStore.loadSnapshot(for: entry.capture)
        } catch {
            throw Error.invalidStoredData
        }
        guard source.contentState != .captureFailed else {
            throw Error.invalidStoredData
        }
        let recipe = ArticleEditRecipe()
        let clean = try ArticleRevisionService().apply(snapshot: source, recipe: recipe)
        let revision = ArticleRevisionRecord(
            id: makeID().uuidString,
            captureID: entry.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: try Self.canonicalJSONString(recipe.metadataOverrides),
            recipeJSON: try Self.canonicalJSONString(recipe),
            readableContentSHA256: clean.readableContentSHA256,
            createdAt: Self.timestamp(now()),
            deviceName: nil)
        switch try captureDAO.publishRevision(
            revision,
            expectedCurrentRevisionID: nil)
        {
        case .published, .conflict:
            return
        }
    }

    private func materialize(_ snapshot: AnthologyDatabaseSnapshot) throws -> AnthologyProject {
        try validate(snapshot)
        let entries = try snapshot.entries.map { value -> AnthologyProjectEntry in
            let source: ArticleSnapshot
            do {
                source = try fileStore.loadSnapshot(for: value.capture)
            } catch {
                throw Error.invalidStoredData
            }
            guard source.contentState != .captureFailed else {
                throw Error.invalidStoredData
            }
            let clean: CleanArticle?
            if let revision = value.revision {
                do {
                    clean = try ArticleRevisionMaterializer().materialize(
                        capture: value.capture,
                        revision: revision,
                        source: source)
                } catch {
                    throw Error.invalidStoredData
                }
            } else {
                clean = nil
            }
            return AnthologyProjectEntry(
                entry: value.entry,
                capture: value.capture,
                revision: value.revision,
                cleanArticle: clean)
        }
        let priorManifest = try frozenManifest(from: snapshot.latestSuccessfulBuild)
        var project = AnthologyProject(
            anthology: snapshot.anthology,
            entries: entries,
            persistedEntryIDs: Set(entries.map(\.entry.id)),
            latestSuccessfulBuild: snapshot.latestSuccessfulBuild,
            changesAvailable: false)
        if let priorManifest {
            if entries.allSatisfy({ $0.revision != nil && $0.cleanArticle != nil }) {
                let current = try manifest(for: project, revision: priorManifest.revision)
                project.changesAvailable = Self.differs(current, from: priorManifest)
            } else {
                project.changesAvailable = true
            }
        }
        return project
    }

    private func manifest(
        for project: AnthologyProject,
        revision forcedRevision: Int? = nil
    ) throws -> AnthologyBuildManifest {
        guard project.entries.isEmpty == false else {
            throw Error.emptyAnthology
        }
        guard let anthologyID = UUID(uuidString: project.anthology.id),
            let modifiedAt = Self.date(project.anthology.modifiedAt)
        else {
            throw Error.invalidStoredData
        }
        var chapters: [AnthologyChapterManifest] = []
        var imageAssets: [ArticleImageAssetDescriptor] = []
        var imageFailures: [ArticleImageFailureDescriptor] = []
        for (order, value) in project.entries.enumerated() {
            guard let entryID = UUID(uuidString: value.entry.id),
                let captureID = UUID(uuidString: value.capture.id),
                let revision = value.revision,
                let revisionID = UUID(uuidString: revision.id),
                let clean = value.cleanArticle,
                let sourceURL = Self.httpURL(value.capture.sourceURL),
                let capturedAt = Self.date(value.capture.capturedAt)
            else {
                throw Error.invalidStoredData
            }
            let captureAssets = try fileStore.loadImageAssetManifest(captureID: captureID)
            let published = Self.publishedContent(
                clean.blocks,
                assets: captureAssets?.assets ?? [],
                failures: captureAssets?.failures ?? [])
            imageAssets.append(contentsOf: published.assets)
            imageFailures.append(contentsOf: published.failures)
            chapters.append(
                AnthologyChapterManifest(
                    entryID: entryID,
                    captureID: captureID,
                    articleRevisionID: revisionID,
                    stableSlot: value.entry.stableSlot,
                    order: order,
                    title: Self.optionalText(value.entry.chapterTitleOverride)
                        ?? Self.requiredTitle(clean.metadata.title),
                    author: Self.optionalText(clean.metadata.author),
                    siteName: Self.optionalText(clean.metadata.siteName),
                    sourceURL: sourceURL,
                    capturedAt: capturedAt,
                    voiceID: Self.optionalText(value.entry.narrationVoiceID),
                    blocks: published.blocks,
                    readableContentSHA256: ArticleWorkshopDigest.readableContent(
                        blocks: published.blocks)))
        }
        let languages = project.entries.map {
            Self.optionalText($0.cleanArticle?.metadata.language)
        }
        let language: String
        if languages.allSatisfy({ $0 != nil }),
            Set(languages.compactMap { $0 }).count == 1
        {
            language = languages[0]!
        } else {
            language = "und"
        }
        let publishedRevision =
            forcedRevision
            ?? ((project.latestSuccessfulBuild?.revision ?? 0) + 1)
        return AnthologyBuildManifest(
            schemaVersion: imageAssets.isEmpty && imageFailures.isEmpty ? 1 : 2,
            anthologyID: anthologyID,
            revision: publishedRevision,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
            title: Self.requiredTitle(project.anthology.title),
            subtitle: Self.optionalText(project.anthology.subtitle),
            creator: Self.optionalText(project.anthology.creator) ?? "Various Authors",
            language: Self.validLanguage(language) ? language : "und",
            coverPath: try managedCoverPath(
                project.anthology.coverPath,
                anthologyID: project.anthology.id,
                storedData: true),
            modifiedAt: modifiedAt,
            chapters: chapters,
            imageAssets: imageAssets.isEmpty && imageFailures.isEmpty ? nil : imageAssets,
            imageFailures: imageAssets.isEmpty && imageFailures.isEmpty ? nil : imageFailures)
    }

    private static func publishedContent(
        _ blocks: [ArticleBlock],
        assets: [ArticleImageAssetDescriptor],
        failures: [ArticleImageFailureDescriptor]
    ) -> (
        blocks: [ArticleBlock],
        assets: [ArticleImageAssetDescriptor],
        failures: [ArticleImageFailureDescriptor]
    ) {
        let assetsByBlock = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.owningBlockID, $0) })
        let failuresByBlock = Dictionary(
            uniqueKeysWithValues: failures.map { ($0.owningBlockID, $0) })
        var publishedAssets: [ArticleImageAssetDescriptor] = []
        var publishedFailures: [ArticleImageFailureDescriptor] = []
        let publishedBlocks = blocks.compactMap { block in
            if block.kind == .image {
                if let asset = assetsByBlock[block.id],
                    asset.sourceURL == block.imageCandidateURL
                {
                    publishedAssets.append(
                        ArticleImageAssetDescriptor(
                            owningBlockID: block.id,
                            managedPath: asset.managedPath,
                            archivePath: asset.archivePath,
                            mediaType: asset.mediaType,
                            sha256: asset.sha256,
                            byteCount: asset.byteCount,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            sourceURL: asset.sourceURL,
                            altText: optionalText(block.altText),
                            caption: optionalText(block.caption)))
                    return block
                }
                if let failure = failuresByBlock[block.id] {
                    publishedFailures.append(failure)
                }
                guard let caption = optionalText(block.caption) else { return nil }
                return ArticleBlock(
                    id: block.id,
                    stableOrdinal: block.stableOrdinal,
                    kind: .paragraph,
                    text: caption,
                    sourceURL: nil,
                    imageCandidateURL: nil,
                    caption: nil,
                    codeLanguage: nil)
            }
            if block.kind != .separator, optionalText(block.text) == nil {
                return nil
            }
            return block
        }
        return (publishedBlocks, publishedAssets, publishedFailures)
    }

    private func validate(_ snapshot: AnthologyDatabaseSnapshot) throws {
        guard UUID(uuidString: snapshot.anthology.id) != nil,
            Self.date(snapshot.anthology.createdAt) != nil,
            Self.date(snapshot.anthology.modifiedAt) != nil,
            snapshot.anthology.nextStableSlot >= 0,
            snapshot.anthology.latestBuildRevision >= 0
        else {
            throw Error.invalidStoredData
        }
        let orders = snapshot.entries.map(\.entry.sortOrder)
        let slots = snapshot.entries.map(\.entry.stableSlot)
        guard orders == Array(0..<orders.count),
            Set(slots).count == slots.count,
            slots.allSatisfy({ $0 >= 0 && $0 < snapshot.anthology.nextStableSlot }),
            snapshot.entries.allSatisfy({
                $0.entry.anthologyID == snapshot.anthology.id
                    && $0.entry.captureID == $0.capture.id
                    && UUID(uuidString: $0.entry.id) != nil
                    && UUID(uuidString: $0.capture.id) != nil
                    && Self.httpURL($0.capture.sourceURL) != nil
                    && Self.date($0.capture.capturedAt) != nil
                    && Self.date($0.capture.createdAt) != nil
                    && Self.date($0.capture.modifiedAt) != nil
                    && Self.buildEligibleContentState($0.capture.contentState)
                    && ($0.entry.narrationVoiceID.flatMap(Self.optionalText).map {
                        VoiceCatalog.voice(for: VoiceID($0)) != nil
                    } ?? true)
                    && ($0.capture.currentRevisionID == nil
                        ? $0.revision == nil
                        : $0.revision?.id == $0.capture.currentRevisionID)
            })
        else {
            throw Error.invalidStoredData
        }
        for value in snapshot.entries {
            if let revision = value.revision {
                guard UUID(uuidString: revision.id) != nil,
                    revision.captureID == value.capture.id,
                    Self.date(revision.createdAt) != nil
                else {
                    throw Error.invalidStoredData
                }
            }
        }
    }

    private func frozenManifest(from build: AnthologyBuildRecord?) throws
        -> AnthologyBuildManifest?
    {
        guard let build else { return nil }
        do {
            return try AnthologyBuildManifestValidator.validate(build)
        } catch {
            throw Error.invalidStoredData
        }
    }

    private static func differs(
        _ current: AnthologyBuildManifest,
        from prior: AnthologyBuildManifest
    ) -> Bool {
        current.schemaVersion != prior.schemaVersion
            || current.anthologyID != prior.anthologyID
            || current.epubIdentifier != prior.epubIdentifier
            || current.title != prior.title
            || current.subtitle != prior.subtitle
            || current.creator != prior.creator
            || current.language != prior.language
            || current.coverPath != prior.coverPath
            || current.chapters != prior.chapters
    }

    private static func requiredTitle(_ value: String) -> String {
        optionalText(value) ?? "New Anthology"
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func coverPath(_ value: String?) throws -> String? {
        guard let path = optionalText(value) else { return nil }
        guard path == URL(fileURLWithPath: path).lastPathComponent,
            path != ".",
            path != ".."
        else {
            throw Error.invalidProjectEdit
        }
        return path
    }

    private func managedCoverPath(
        _ value: String?,
        anthologyID: String,
        storedData: Bool = false
    ) throws -> String? {
        guard let path = try Self.coverPath(value) else { return nil }
        guard let id = UUID(uuidString: anthologyID) else {
            throw storedData ? Error.invalidStoredData : Error.invalidProjectEdit
        }
        do {
            return try coverStore.validateManagedCover(named: path, anthologyID: id)
        } catch {
            throw storedData ? Error.invalidStoredData : Error.invalidProjectEdit
        }
    }

    private static func validLanguage(_ value: String) -> Bool {
        value == "und"
            || value.range(
                of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#,
                options: .regularExpression) != nil
    }

    private static func buildEligibleContentState(_ value: String) -> Bool {
        value == ArticleContentState.ready.rawValue
            || value == ArticleContentState.reviewSuggested.rawValue
    }

    private func databaseSnapshot(id: String) throws -> AnthologyDatabaseSnapshot? {
        do {
            return try anthologyDAO.projectSnapshot(id: id)
        } catch {
            throw Error.invalidStoredData
        }
    }

    private func prevalidateSelection(_ captureIDs: [String]) throws {
        for captureID in captureIDs {
            guard let capture = try captureDAO.capture(id: captureID) else {
                throw Error.invalidSelection
            }
            try validateCaptureMaterial(capture)
        }
    }

    private func validateCaptureMaterial(_ capture: ArticleCaptureRecord) throws {
        guard UUID(uuidString: capture.id) != nil,
            Self.httpURL(capture.sourceURL) != nil,
            Self.date(capture.capturedAt) != nil,
            Self.date(capture.createdAt) != nil,
            Self.date(capture.modifiedAt) != nil,
            Self.buildEligibleContentState(capture.contentState)
        else {
            throw Error.invalidStoredData
        }
        let source: ArticleSnapshot
        do {
            source = try fileStore.loadSnapshot(for: capture)
        } catch {
            throw Error.invalidStoredData
        }
        guard source.contentState != .captureFailed else {
            throw Error.invalidStoredData
        }
        if let revisionID = capture.currentRevisionID {
            guard let revision = try captureDAO.currentRevision(captureID: capture.id),
                revision.id == revisionID,
                revision.captureID == capture.id
            else {
                throw Error.invalidStoredData
            }
            do {
                _ = try ArticleRevisionMaterializer().materialize(
                    capture: capture,
                    revision: revision,
                    source: source)
            } catch {
                throw Error.invalidStoredData
            }
        }
    }

    private static func httpURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil
        else {
            return nil
        }
        return url
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func mapDAOError(_ error: any Swift.Error) -> Error {
        switch error as? AnthologyDAOError {
        case .anthologyNotFound:
            return .anthologyNotFound
        case .revisionConflict:
            return .revisionConflict
        case .captureNotFound, .invalidEntryOrder, .entryNotFound:
            return .invalidProjectEdit
        case nil:
            return .invalidProjectEdit
        }
    }
}
