// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

#if canImport(FoundationModels)
    import FoundationModels
#endif

private struct NarrationCurrentRenderUnit {
    let segmentIndex: Int?
    let blocks: [EPubBlockRecord]
    let fileURL: URL
}

@MainActor
private func currentNarrationRenderUnits(
    for plan: NarrationChapterRenderPlan,
    isFirstChapterOfBook: Bool,
    narration: NarrationService
) async -> [NarrationCurrentRenderUnit] {
    let fullURL = await narration.chapterCacheURL(
        chapterIndex: plan.chapterIndex,
        sourceChapterKey: plan.sourceChapterKey,
        blocks: plan.blocks,
        voice: plan.voice)
    if FileManager.default.fileExists(atPath: fullURL.path) {
        return [NarrationCurrentRenderUnit(segmentIndex: nil, blocks: plan.blocks, fileURL: fullURL)]
    }

    let segments = NarrationSegmentPlanner.segments(
        for: plan, isFirstChapterOfBook: isFirstChapterOfBook)
    guard !segments.isEmpty else { return [] }

    var units: [NarrationCurrentRenderUnit] = []
    units.reserveCapacity(segments.count)
    for segment in segments {
        let fileURL = await narration.segmentCacheURL(
            chapterIndex: segment.chapterIndex,
            sourceChapterKey: segment.sourceChapterKey,
            segmentIndex: segment.segmentIndex,
            blocks: segment.blocks,
            voice: segment.voice)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        units.append(
            NarrationCurrentRenderUnit(
                segmentIndex: segment.segmentIndex,
                blocks: segment.blocks,
                fileURL: fileURL))
    }
    return units
}

/// Drives the per-book narration-QA review screen: loads open issues and applies
/// ignore/resolve status changes (override + regenerate actions land in M4). Pure
/// Foundation (no UIKit), so it bundles into every target without exclusion.
@MainActor
@Observable
final class NarrationQAReviewModel {
    struct PronunciationReviewPresentation: Identifiable, Equatable {
        let id: String
        let category: PronunciationAdvisoryEvidence.Category
        let selectedCandidate: PronunciationAdvisoryIssueEvidence.SelectedCandidate?
        let selectionReason: PronunciationAdvisoryEvidence.SelectionReason
        let alternatives: [PronunciationAdvisoryEvidence.Alternative]
        let occurrenceCount: Int
        let chosenCandidateID: String?
    }

    struct Dependencies {
        typealias ClassifierFactory =
            @MainActor (_ preference: String, _ availabilityIsAvailable: Bool)
            -> DivergenceClassifier
        typealias NarrationPlan =
            @Sendable (_ audiobookID: String, _ preferredVoice: VoiceID)
            async throws -> [NarrationChapterRenderPlan]
        typealias QARunner =
            @MainActor (
                _ audiobookID: String,
                _ chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])],
                _ classifier: DivergenceClassifier
            ) async throws -> Void
        typealias RepairRunner =
            @MainActor (
                _ issue: NarrationQualityIssueRecord,
                _ scope: FixScope,
                _ target: NarrationChapterRenderPlan,
                _ narration: NarrationService,
                _ classifier: DivergenceClassifier
            ) async throws -> Void

        var classifierPreference: @MainActor () -> String
        var foundationModelsAvailable: @MainActor () -> Bool
        var classifierFactory: ClassifierFactory
        var narrationVoice: @MainActor () -> VoiceID
        let narrationPlan: NarrationPlan
        let runQA: QARunner
        let applyRepair: RepairRunner

        #if os(iOS) || os(macOS)
            typealias NarrationServiceFactory =
                @MainActor (_ db: DatabaseWriter, _ audiobookID: String) async
                -> NarrationService

            var narrationServiceFactory: NarrationServiceFactory
        #endif

        #if os(iOS) || os(macOS)
            init(
                classifierPreference: @escaping @MainActor () -> String =
                    Self.liveClassifierPreference,
                foundationModelsAvailable: @escaping @MainActor () -> Bool =
                    Self.liveFoundationModelsAvailable,
                classifierFactory: @escaping ClassifierFactory = DivergenceClassifierFactory.make,
                narrationVoice: @escaping @MainActor () -> VoiceID = Self.liveNarrationVoice,
                narrationPlan: @escaping NarrationPlan = Self.unconfiguredNarrationPlan,
                runQA: @escaping QARunner = Self.unconfiguredQA,
                applyRepair: @escaping RepairRunner = Self.unconfiguredRepair,
                narrationServiceFactory: @escaping NarrationServiceFactory =
                    Self.liveNarrationService
            ) {
                self.classifierPreference = classifierPreference
                self.foundationModelsAvailable = foundationModelsAvailable
                self.classifierFactory = classifierFactory
                self.narrationVoice = narrationVoice
                self.narrationPlan = narrationPlan
                self.runQA = runQA
                self.applyRepair = applyRepair
                self.narrationServiceFactory = narrationServiceFactory
            }
        #else
            init(
                classifierPreference: @escaping @MainActor () -> String =
                    Self.liveClassifierPreference,
                foundationModelsAvailable: @escaping @MainActor () -> Bool =
                    Self.liveFoundationModelsAvailable,
                classifierFactory: @escaping ClassifierFactory = DivergenceClassifierFactory.make,
                narrationVoice: @escaping @MainActor () -> VoiceID = Self.liveNarrationVoice,
                narrationPlan: @escaping NarrationPlan = Self.unconfiguredNarrationPlan,
                runQA: @escaping QARunner = Self.unconfiguredQA,
                applyRepair: @escaping RepairRunner = Self.unconfiguredRepair
            ) {
                self.classifierPreference = classifierPreference
                self.foundationModelsAvailable = foundationModelsAvailable
                self.classifierFactory = classifierFactory
                self.narrationVoice = narrationVoice
                self.narrationPlan = narrationPlan
                self.runQA = runQA
                self.applyRepair = applyRepair
            }
        #endif

        private static func liveClassifierPreference() -> String {
            UserDefaults.standard.string(forKey: "narrationQAClassifier")
                ?? SettingsManager.Defaults.narrationQAClassifier
        }

        private static func liveFoundationModelsAvailable() -> Bool {
            #if canImport(FoundationModels) && (os(iOS) || os(macOS))
                if #available(iOS 26, macOS 26, *) {
                    if case .available = SystemLanguageModel.default.availability {
                        return true
                    }
                }
            #endif
            return false
        }

        private static func liveNarrationVoice() -> VoiceID {
            if let rawValue = UserDefaults.standard.string(forKey: "narrationVoiceID") {
                return VoiceCatalog.voice(for: VoiceID(rawValue))?.id ?? VoiceCatalog.default.id
            }
            return VoiceCatalog.default.id
        }

        private static func unconfiguredNarrationPlan(
            audiobookID: String,
            preferredVoice: VoiceID
        ) async throws -> [NarrationChapterRenderPlan] {
            throw NarrationRepairError.sourceChapterUnavailable
        }

        private static func unconfiguredQA(
            audiobookID: String,
            chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])],
            classifier: DivergenceClassifier
        ) async throws {
            throw NarrationRepairError.sourceChapterUnavailable
        }

        private static func unconfiguredRepair(
            issue: NarrationQualityIssueRecord,
            scope: FixScope,
            target: NarrationChapterRenderPlan,
            narration: NarrationService,
            classifier: DivergenceClassifier
        ) async throws {
            throw NarrationRepairError.sourceChapterUnavailable
        }

        static func live(db: DatabaseWriter) -> Self {
            Self(
                narrationPlan: { audiobookID, preferredVoice in
                    let blockDAO = EPubBlockDAO(db: db)
                    let allBlocks = try blockDAO.allBlocks(for: audiobookID)
                    let visibleBlocks = try blockDAO.visibleBlocks(for: audiobookID)
                    let allChapters = await NarrationChapterPlanner.plan(from: allBlocks)
                    let visibleChapters = await NarrationChapterPlanner.plan(from: visibleBlocks)
                    let audiobookURL = URL(string: audiobookID)
                    let epubURL = audiobookURL.flatMap {
                        $0.isFileURL
                            && $0.pathExtension.localizedCaseInsensitiveCompare("epub") == .orderedSame
                            ? $0.standardizedFileURL : nil
                    }
                    let manifest = try AnthologyNarrationManifestResolver(db: db).resolve(
                        audiobookID: audiobookID,
                        epubURL: epubURL)
                    let allRenderPlans = try NarrationChapterRenderPlanner.plan(
                        chapters: allChapters,
                        preferredVoice: preferredVoice,
                        manifest: manifest)
                    let allPlansByIndex = Dictionary(
                        uniqueKeysWithValues: allRenderPlans.map { ($0.chapterIndex, $0) })
                    return try visibleChapters.map { visible in
                        guard let trusted = allPlansByIndex[visible.index] else {
                            throw NarrationRepairError.sourceChapterUnavailable
                        }
                        return NarrationChapterRenderPlan(
                            chapterIndex: visible.index,
                            displayNumber: visible.displayNumber,
                            sourceChapterKey: trusted.sourceChapterKey,
                            title: visible.title,
                            blocks: visible.blocks,
                            voice: trusted.voice)
                    }
                },
                runQA: { audiobookID, chapters, classifier in
                    try await NarrationQAService(db: db, classifier: classifier).runQA(
                        audiobookID: audiobookID,
                        chapters: chapters)
                },
                applyRepair: { issue, scope, target, narration, classifier in
                    let qa = NarrationQAService(db: db, classifier: classifier)
                    let units = await currentNarrationRenderUnits(
                        for: target,
                        isFirstChapterOfBook: target.displayNumber == 1,
                        narration: narration)
                    guard !units.isEmpty else {
                        throw NarrationRepairError.sourceChapterUnavailable
                    }
                    let repair = PronunciationRepairService(
                        store: PronunciationOverrideStore.shared,
                        issueDAO: NarrationQualityIssueDAO(db: db),
                        db: db,
                        cacheDirectory: NarrationCache.directory(),
                        voice: target.voice,
                        sourceChapterKey: target.sourceChapterKey,
                        renderChapter: { chapterIndex in
                            guard chapterIndex == target.chapterIndex else {
                                throw NarrationRepairError.sourceChapterUnavailable
                            }
                            for unit in units {
                                if let segmentIndex = unit.segmentIndex {
                                    try await narration.renderSegment(
                                        chapterIndex: chapterIndex,
                                        sourceChapterKey: target.sourceChapterKey,
                                        chapterDisplayNumber: target.displayNumber,
                                        segmentIndex: segmentIndex,
                                        blocks: unit.blocks,
                                        voice: target.voice,
                                        chapterTitle: target.title)
                                } else {
                                    try await narration.renderChapter(
                                        chapterIndex: chapterIndex,
                                        sourceChapterKey: target.sourceChapterKey,
                                        chapterNumber: target.displayNumber,
                                        blocks: unit.blocks,
                                        voice: target.voice,
                                        chapterTitle: target.title)
                                }
                            }
                        },
                        reRunQA: { chapterIndex in
                            guard chapterIndex == target.chapterIndex else {
                                throw NarrationRepairError.sourceChapterUnavailable
                            }
                            var qaUnits: [
                                (chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])
                            ] = []
                            for unit in units {
                                let fileURL: URL
                                if let segmentIndex = unit.segmentIndex {
                                    fileURL = await narration.segmentCacheURL(
                                        chapterIndex: chapterIndex,
                                        sourceChapterKey: target.sourceChapterKey,
                                        segmentIndex: segmentIndex,
                                        blocks: unit.blocks,
                                        voice: target.voice)
                                } else {
                                    fileURL = await narration.chapterCacheURL(
                                        chapterIndex: chapterIndex,
                                        sourceChapterKey: target.sourceChapterKey,
                                        blocks: unit.blocks,
                                        voice: target.voice)
                                }
                                qaUnits.append(
                                    (
                                        chapterIndex: chapterIndex,
                                        fileURL: fileURL,
                                        spokenBlockIDs: unit.blocks.filter { !$0.isHidden }.map(\.id)
                                    ))
                            }
                            try await qa.runQA(
                                audiobookID: issue.audiobookID,
                                chapters: qaUnits)
                        })
                    try await repair.applyFix(issue: issue, scope: scope)
                })
        }

        #if os(iOS) || os(macOS)
            private static func liveNarrationService(
                db: DatabaseWriter, audiobookID: String
            ) async -> NarrationService {
                let pronunciationPack = await EnglishPronunciationPack.bundledOrEmpty()
                let pronunciationAuditPack = await EnglishPronunciationAuditPack.bundledOrEmpty()
                return NarrationService(
                    db: db, audiobookID: audiobookID,
                    tts: NarrationEngineFactory.make(),
                    audioWriter: AVFoundationAudioWriter(),
                    cacheDirectory: NarrationCache.directory(),
                    state: NarrationState(),
                    pronunciationOverrides: { [audiobookID] in
                        PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
                    },
                    pronunciationOccurrenceOverrides: { [audiobookID] in
                        PronunciationOverrideStore.shared.occurrenceOverrides(
                            forBookID: audiobookID)
                    },
                    pronunciationPack: pronunciationPack,
                    pronunciationAuditPack: pronunciationAuditPack,
                    neuralEvaluator: { word in
                        try await MiniBARTG2PEngine.shared.evaluate(word: word)
                    })
            }
        #endif
    }

    var issues: [NarrationQualityIssueRecord] = []
    /// User-facing message for the most recent failure (transcription error,
    /// no rendered audio, repair failure). `nil` when the last action succeeded.
    var lastError: String?

    var hasPronunciationReviewIssues: Bool {
        issues.contains { issue in
            issue.issueType == NarrationQAIssueType.pronunciation.rawValue
                && (issue.origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue
                    || issue.origin == NarrationQualityIssueOrigin.acoustic.rawValue)
        }
    }

    private let db: DatabaseWriter
    private let audiobookID: String
    @ObservationIgnored private let dependencies: Dependencies
    private let logger = Logger(category: "NarrationQAReview")
    private static let iso = ISO8601DateFormatter()

    #if os(iOS) || os(macOS)
        @ObservationIgnored private var cachedNarrationService: NarrationService?
    #endif

    init(
        db: DatabaseWriter,
        audiobookID: String,
        dependencies: Dependencies? = nil
    ) {
        self.db = db
        self.audiobookID = audiobookID
        self.dependencies = dependencies ?? Dependencies.live(db: db)
    }

    func load() {
        do {
            issues = try NarrationQualityIssueDAO(db: db)
                .issues(for: audiobookID, status: NarrationQAIssueStatus.open.rawValue)
            lastError = nil
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
            lastError = "Couldn't refresh narration QA: \(error.localizedDescription)"
        }
    }

    /// Projects only complete, builder-authored advisory envelopes into shared
    /// review state. Legacy direct evidence remains visible as a normal QA row,
    /// but cannot truthfully expose an occurrence count and therefore fails
    /// closed without candidate controls.
    func pronunciationPresentation(
        for issue: NarrationQualityIssueRecord
    ) -> PronunciationReviewPresentation? {
        guard issue.issueType == NarrationQAIssueType.pronunciation.rawValue,
            let evidenceJSON = issue.evidenceJSON,
            let evidenceData = evidenceJSON.data(using: .utf8)
        else { return nil }

        do {
            let issueEvidence = try JSONDecoder().decode(
                PronunciationAdvisoryIssueEvidence.self, from: evidenceData)
            let advisory = issueEvidence.advisoryEvidence
            guard issueEvidence.isValid(),
                originMatchesCategory(issue.origin, category: advisory.category)
            else { return nil }

            return PronunciationReviewPresentation(
                id: issue.id,
                category: advisory.category,
                selectedCandidate: issueEvidence.selectedCandidate,
                selectionReason: advisory.selectionReason,
                alternatives: advisory.alternatives,
                occurrenceCount: issueEvidence.occurrenceCount,
                chosenCandidateID: advisory.selectedCandidateID)
        } catch {
            logger.debug("pronunciation evidence unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Revalidates the persisted accepted candidate and fix payload. Views use
    /// this both to decide whether to offer the action and again when applying it.
    func canAcceptCurrentCandidate(
        for issue: NarrationQualityIssueRecord
    ) -> Bool {
        guard let presentation = pronunciationPresentation(for: issue),
            let selected = presentation.selectedCandidate,
            selected.validation == .eligible,
            let fixJSON = issue.suggestedFixJSON,
            let fixData = fixJSON.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: fixData),
            let fixIPA = fix.ipa,
            let spokenForm = fix.spokenForm
        else {
            return false
        }

        let expectedWord = issue.expectedText.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedWord = spokenForm.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !expectedWord.isEmpty
            && persistedWord == expectedWord
            && PronunciationAdvisoryIssueEvidence.normalizedIPA(fixIPA)
                == PronunciationAdvisoryIssueEvidence.normalizedIPA(selected.ipa)
    }

    func acceptCurrentCandidate(
        for issue: NarrationQualityIssueRecord,
        scope: FixScope
    ) async {
        guard canAcceptCurrentCandidate(for: issue) else {
            lastError = "This pronunciation decision isn't eligible to apply."
            return
        }
        await acceptFix(issue: issue, scope: scope)
    }

    private func originMatchesCategory(
        _ origin: String,
        category: PronunciationAdvisoryEvidence.Category
    ) -> Bool {
        switch category {
        case .lexical, .contextual:
            origin == NarrationQualityIssueOrigin.pronunciationPreflight.rawValue
        case .acoustic:
            origin == NarrationQualityIssueOrigin.acoustic.rawValue
        }
    }

    /// Accepts only policy-eligible alternatives from a valid advisory
    /// presentation. The temporary issue changes one field and then follows the
    /// existing acceptFix path, preserving its scope and regeneration semantics.
    func acceptCandidate(
        _ candidateID: String,
        for issue: NarrationQualityIssueRecord,
        scope: FixScope
    ) async {
        guard let presentation = pronunciationPresentation(for: issue),
            let alternative = presentation.alternatives.first(where: {
                $0.candidateID == candidateID && $0.validation == .eligible
            }),
            !issue.expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            lastError = "This pronunciation candidate isn't eligible to apply."
            return
        }

        do {
            let candidateFix = SuggestedFix(
                spokenForm: issue.expectedText,
                ipa: alternative.ipa)
            let candidateFixData = try JSONEncoder().encode(candidateFix)
            var candidateIssue = issue
            candidateIssue.suggestedFixJSON = String(
                decoding: candidateFixData, as: UTF8.self)
            await acceptFix(issue: candidateIssue, scope: scope)
        } catch {
            logger.error("acceptCandidate failed: \(error.localizedDescription)")
            lastError = "This pronunciation candidate couldn't be applied."
        }
    }

    /// Testable core of the initial "Run QA" pass: runs the injected QA work over
    /// the pre-resolved rendered chapters, then reloads the open queue. Surfaces a
    /// message via `lastError` when there is nothing rendered to check or the pass
    /// throws — so the user never sees an empty queue that silently did nothing.
    func runFullQA(
        chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])],
        run: (
            _ chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])],
            _ classifier: DivergenceClassifier
        )
            async throws -> Void
    ) async {
        guard !chapters.isEmpty else {
            lastError =
                "No narrated audio found to check. Generate narration for this book first."
            return
        }
        do {
            try await run(chapters, makeConfiguredClassifier())
            lastError = nil
            load()
        } catch {
            logger.error("runFullQA failed: \(error.localizedDescription)")
            lastError = "Narration QA couldn't finish: \(error.localizedDescription)"
        }
    }

    func ignore(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .ignored, resolvedAt: nil)
    }

    func markResolved(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .resolved, resolvedAt: Self.iso.string(from: Date()))
    }

    private func update(
        _ issue: NarrationQualityIssueRecord, status: NarrationQAIssueStatus, resolvedAt: String?
    ) {
        do {
            try NarrationQualityIssueDAO(db: db)
                .updateStatus(id: issue.id, status: status.rawValue, resolvedAt: resolvedAt)
            issues.removeAll { $0.id == issue.id }
        } catch {
            logger.error("update status failed: \(error.localizedDescription)")
        }
    }

    private func makeConfiguredClassifier() -> DivergenceClassifier {
        dependencies.classifierFactory(
            dependencies.classifierPreference(),
            dependencies.foundationModelsAvailable())
    }

    #if os(iOS) || os(macOS)
        /// Production "Run QA / Listen Back" entry point: discover every chapter that
        /// has rendered narration audio, run the configured QA pass over them, and
        /// reload the queue. The book must already be narrated; otherwise `lastError`
        /// explains there is nothing to check (instead of a silent empty queue).
        @MainActor
        func runFullQA() async {
            let voice = dependencies.narrationVoice()
            let chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]
            do {
                let plans = try await dependencies.narrationPlan(audiobookID, voice)
                chapters = try await renderedChaptersForQA(plans: plans)
            } catch {
                logger.error("runFullQA chapter scan failed: \(error.localizedDescription)")
                lastError = "Couldn't read this book's chapters: \(error.localizedDescription)"
                return
            }
            await runFullQA(chapters: chapters) { [audiobookID] chapters, classifier in
                try await dependencies.runQA(audiobookID, chapters, classifier)
            }
        }

        private func narrationService() async -> NarrationService {
            if let cachedNarrationService { return cachedNarrationService }
            let service = await dependencies.narrationServiceFactory(db, audiobookID)
            cachedNarrationService = service
            return service
        }

        func renderedChaptersForQA(
            plans: [NarrationChapterRenderPlan]
        ) async throws -> [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])] {
            let narration = await narrationService()
            var chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])] = []
            for (planIndex, plan) in plans.enumerated() {
                let units = await currentNarrationRenderUnits(
                    for: plan,
                    isFirstChapterOfBook: planIndex == 0,
                    narration: narration)
                chapters.append(contentsOf: units.compactMap { unit in
                    let spokenBlockIDs = unit.blocks.filter { !$0.isHidden }.map(\.id)
                    guard !spokenBlockIDs.isEmpty else { return nil }
                    return (plan.chapterIndex, unit.fileURL, spokenBlockIDs)
                })
            }
            return chapters
        }
    #endif

    /// User accepted a pronunciation fix from the review queue. Writes the override
    /// in the chosen scope, regenerates the affected chapter with the new
    /// pronunciation, re-runs QA over it, and resolves the issue. Errors surface
    /// through the model's existing error state (no crash). Only meaningful on
    /// iOS/macOS where narration services are available.
    @MainActor
    func acceptFix(issue: NarrationQualityIssueRecord, scope: FixScope) async {
        #if os(iOS) || os(macOS)
            let voice = dependencies.narrationVoice()

            let target: NarrationChapterRenderPlan
            do {
                let plan = try await dependencies.narrationPlan(audiobookID, voice)
                guard let blockID = issue.sourceBlockID,
                    let chapterIndex = try PronunciationRepairService.chapterIndex(
                        forBlockID: blockID, audiobookID: issue.audiobookID, db: db),
                    let resolved = plan.first(where: { $0.chapterIndex == chapterIndex })
                else {
                    throw NarrationRepairError.sourceChapterUnavailable
                }
                if plan.contains(where: { $0.sourceChapterKey != nil }),
                    resolved.sourceChapterKey == nil
                {
                    throw NarrationRepairError.sourceChapterUnavailable
                }
                target = resolved
            } catch {
                logger.error("acceptFix plan failed: \(error.localizedDescription)")
                lastError = "Couldn't apply the fix: \(error.localizedDescription)"
                return
            }

            let narration = await narrationService()
            do {
                try await dependencies.applyRepair(
                    issue, scope, target, narration, makeConfiguredClassifier())
                lastError = nil
                load()
            } catch NarrationRepairError.noUsableFix {
                lastError =
                    "This issue has no pronunciation fix to apply. Add an IPA spelling first."
            } catch NarrationRepairError.sourceOccurrenceUnavailable {
                lastError =
                    "This issue has no source word position. Use This Book or All Books instead."
            } catch {
                logger.error("acceptFix failed: \(error.localizedDescription)")
                lastError = "Couldn't apply the fix: \(error.localizedDescription)"
            }
        #else
            logger.error("acceptFix is not available on this platform")
        #endif
    }
}
