// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAReviewModelTests {
    private actor CallCounter {
        private var value = 0

        func increment() { value += 1 }
        func count() -> Int { value }
    }

    private struct MarkerClassifier: DivergenceClassifier {
        func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
            DivergenceClassification(
                issueType: .pronunciation,
                suggestedSpokenForm: "marker",
                suggestedIPA: "mˈɑɹkɚ",
                confidence: 0.99)
        }
    }

    private func seed(_ db: DatabaseService, book: String) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [book, "Test", 3600.0])
        }
        try NarrationQualityIssueDAO(db: db.writer).insert([
            NarrationQualityIssueRecord(
                id: "i1", audiobookID: book, sourceBlockID: "blk1", sourceWordStart: 0,
                sourceWordEnd: 1, audioStartTime: 0, audioEndTime: 1, expectedText: "colonel",
                heardText: "kernel", issueType: NarrationQAIssueType.substitution.rawValue,
                confidence: 0.8, suggestedFixJSON: nil,
                status: NarrationQAIssueStatus.open.rawValue, createdAt: "t", resolvedAt: nil)
        ])
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func pronunciationIssue(
        evidence: PronunciationAdvisoryIssueEvidence,
        selectedIPA: String? = "kˈɑntɛnt",
        spokenForm: String = "Content"
    ) throws -> NarrationQualityIssueRecord {
        NarrationQualityIssueRecord(
            id: "pronunciation-issue", audiobookID: "b1", sourceBlockID: "blk1",
            sourceWordStart: 2, sourceWordEnd: 2, audioStartTime: 4, audioEndTime: 5,
            expectedText: "Content", heardText: "",
            issueType: NarrationQAIssueType.pronunciation.rawValue, confidence: 1,
            suggestedFixJSON: try selectedIPA.map {
                try json(SuggestedFix(spokenForm: spokenForm, ipa: $0))
            },
            origin: NarrationQualityIssueOrigin.pronunciationPreflight.rawValue,
            evidenceJSON: try json(evidence), status: NarrationQAIssueStatus.open.rawValue,
            createdAt: "2026-08-04T00:00:00Z", resolvedAt: nil)
    }

    @Test func loadShowsOpenIssues() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        #expect(model.issues.count == 1)
    }

    @Test func loadFailurePreservesTheVisibleQueueAndSurfacesAnError() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        let visibleIssues = model.issues
        try db.writer.write { database in
            try database.execute(sql: "DROP TABLE narration_quality_issue")
        }

        model.load()

        #expect(model.issues == visibleIssues)
        #expect(model.lastError != nil)
    }

    @Test func pronunciationPresentationUsesOnlyPersistedAdvisoryEvidence() throws {
        let db = try DatabaseService(inMemory: ())
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "current.lexicon",
            alternatives: [
                .init(
                    candidateID: "alternative.eligible", ipa: "kˈɒntɛnt",
                    source: "neural-oov", authority: .qualified, validation: .eligible,
                    policyVersion: "policy-v1"),
                .init(
                    candidateID: "alternative.shadow", ipa: "kəntˈɛnt",
                    source: "shadow-model", authority: .uncertain, validation: .shadow,
                    policyVersion: "policy-v1"),
            ],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let issue = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory,
                occurrenceCount: 3,
                selectedCandidate: .init(
                    candidateID: "current.lexicon",
                    ipa: "kˈɑntɛnt",
                    source: .supplementalLexicon,
                    authority: .trusted,
                    validation: .eligible)),
            selectedIPA: "kˈɑntɛnt")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")

        let presentation = try #require(model.pronunciationPresentation(for: issue))

        #expect(presentation.id == issue.id)
        #expect(presentation.category == .lexical)
        #expect(presentation.selectedCandidate?.ipa == "kˈɑntɛnt")
        #expect(presentation.selectedCandidate?.candidateID == "current.lexicon")
        #expect(presentation.selectedCandidate?.source == .supplementalLexicon)
        #expect(presentation.selectedCandidate?.authority == .trusted)
        #expect(presentation.selectedCandidate?.validation == .eligible)
        #expect(presentation.selectionReason == .trustedLexicon)
        #expect(presentation.alternatives == advisory.alternatives)
        #expect(presentation.occurrenceCount == 3)
        #expect(presentation.chosenCandidateID == "current.lexicon")
    }

    @Test func evidenceOnlyPresentationKeepsCategoryReasonCountAndNonActionableAlternatives() throws {
        let db = try DatabaseService(inMemory: ())
        let alternatives = [
            PronunciationAdvisoryEvidence.Alternative(
                candidateID: "alternative.shadow", ipa: "kəntˈɛnt", source: "model",
                authority: .uncertain, validation: .shadow, policyVersion: "policy-v1"),
            PronunciationAdvisoryEvidence.Alternative(
                candidateID: "alternative.rejected", ipa: "kˈɒntɛnt", source: "model",
                authority: .uncertain, validation: .rejected, policyVersion: "policy-v1"),
        ]
        let advisory = PronunciationAdvisoryEvidence(
            category: .acoustic,
            selectedAuthority: .uncertain,
            selectedCandidateID: nil,
            alternatives: alternatives,
            selectionReason: .acousticRetryRejected,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        var issue = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory,
                occurrenceCount: 4,
                selectedCandidate: nil),
            selectedIPA: nil)
        issue.origin = NarrationQualityIssueOrigin.acoustic.rawValue
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")

        let presentation = try #require(model.pronunciationPresentation(for: issue))

        #expect(presentation.category == .acoustic)
        #expect(presentation.selectionReason == .acousticRetryRejected)
        #expect(presentation.occurrenceCount == 4)
        #expect(presentation.selectedCandidate == nil)
        #expect(presentation.chosenCandidateID == nil)
        #expect(presentation.alternatives == advisory.alternatives)
    }

    @Test func pronunciationPresentationFailsClosedWithoutTruthfulEnvelopeMetadata() throws {
        let db = try DatabaseService(inMemory: ())
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical, selectedAuthority: .trusted,
            selectedCandidateID: "current.lexicon", alternatives: [],
            selectionReason: .trustedLexicon, overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")

        var legacy = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory, occurrenceCount: 1))
        let olderPresentation = try #require(model.pronunciationPresentation(for: legacy))
        #expect(olderPresentation.selectedCandidate == nil)
        #expect(olderPresentation.chosenCandidateID == "current.lexicon")
        #expect(!model.canAcceptCurrentCandidate(for: legacy))

        legacy.evidenceJSON = try json(advisory)
        #expect(model.pronunciationPresentation(for: legacy) == nil)

        var nonPositiveCount = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory, occurrenceCount: 0))
        #expect(model.pronunciationPresentation(for: nonPositiveCount) == nil)

        nonPositiveCount.evidenceJSON = "{malformed"
        #expect(model.pronunciationPresentation(for: nonPositiveCount) == nil)
    }

    @Test func eligibleAlternativeWithoutStoredFixChangesOnlyTheTemporarySuggestedFix() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "b1"
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [bookID, "Test", 3600.0])
        }
        let block = EPubBlockRecord(
            id: "blk1", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Content.", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            narrationText: nil, sourceChapterKey: nil, createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)

        let alternative = PronunciationAdvisoryEvidence.Alternative(
            candidateID: "alternative.eligible", ipa: "kəntˈɛnt",
            source: "neural-oov", authority: .qualified, validation: .eligible,
            policyVersion: "policy-v1")
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical, selectedAuthority: .uncertain,
            selectedCandidateID: nil, alternatives: [alternative],
            selectionReason: .sourceDisagreement, overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let issue = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory, occurrenceCount: 1,
                selectedCandidate: nil),
            selectedIPA: nil)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let voice = VoiceID("af_heart")
        let service = NarrationService(
            db: db.writer, audiobookID: bookID, tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let plan = NarrationChapterRenderPlan(
            chapterIndex: 0, displayNumber: 1, sourceChapterKey: nil,
            title: "Chapter", blocks: [block], voice: voice)
        var acceptedIssue: NarrationQualityIssueRecord?
        var acceptedScope: FixScope?
        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationVoice: { voice }, narrationPlan: { _, _ in [plan] },
            applyRepair: { candidateIssue, scope, _, _, _ in
                acceptedIssue = candidateIssue
                acceptedScope = scope
            },
            narrationServiceFactory: { _, _ in service })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: bookID, dependencies: dependencies)

        await model.acceptCandidate(
            alternative.candidateID, for: issue, scope: .global)

        var acceptedIssueWithoutCandidateFix = try #require(acceptedIssue)
        let acceptedFixData = try #require(
            acceptedIssueWithoutCandidateFix.suggestedFixJSON?.data(using: .utf8))
        let acceptedFix = try JSONDecoder().decode(SuggestedFix.self, from: acceptedFixData)
        acceptedIssueWithoutCandidateFix.suggestedFixJSON = nil

        #expect(acceptedIssueWithoutCandidateFix == issue)
        #expect(acceptedFix == SuggestedFix(spokenForm: "Content", ipa: alternative.ipa))
        #expect(acceptedScope == .global)
        #expect(issue.suggestedFixJSON == nil)
    }

    @Test func acceptCandidateRejectsShadowAndRejectedAlternatives() async throws {
        let db = try DatabaseService(inMemory: ())
        let alternatives = [
            PronunciationAdvisoryEvidence.Alternative(
                candidateID: "alternative.shadow", ipa: "kəntˈɛnt", source: "model",
                authority: .uncertain, validation: .shadow, policyVersion: "policy-v1"),
            PronunciationAdvisoryEvidence.Alternative(
                candidateID: "alternative.rejected", ipa: "kˈɒntɛnt", source: "model",
                authority: .uncertain, validation: .rejected, policyVersion: "policy-v1"),
        ]
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical, selectedAuthority: .uncertain,
            selectedCandidateID: nil, alternatives: alternatives,
            selectionReason: .sourceDisagreement, overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let issue = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory, occurrenceCount: 1,
                selectedCandidate: nil),
            selectedIPA: nil)
        let planCalls = CallCounter()
        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationPlan: { _, _ in
                await planCalls.increment()
                return []
            })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: "b1", dependencies: dependencies)

        await model.acceptCandidate(alternatives[0].candidateID, for: issue, scope: .global)
        await model.acceptCandidate(alternatives[1].candidateID, for: issue, scope: .global)

        let planCallCount = await planCalls.count()
        #expect(planCallCount == 0)
        #expect(model.pronunciationPresentation(for: issue)?.alternatives == advisory.alternatives)
    }

    @Test func currentCandidateActionRejectsFixMismatchAndNonEligibleMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "current.lexicon",
            alternatives: [],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let eligibleEvidence = PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: advisory,
            occurrenceCount: 1,
            selectedCandidate: .init(
                candidateID: "current.lexicon",
                ipa: "kˈɑntɛnt",
                source: .supplementalLexicon,
                authority: .trusted,
                validation: .eligible))
        let shadowEvidence = PronunciationAdvisoryIssueEvidence(
            advisoryEvidence: advisory,
            occurrenceCount: 1,
            selectedCandidate: .init(
                candidateID: "current.lexicon",
                ipa: "kˈɑntɛnt",
                source: .supplementalLexicon,
                authority: .trusted,
                validation: .shadow))
        let wrongIPA = try pronunciationIssue(
            evidence: eligibleEvidence,
            selectedIPA: "kəntˈɛnt")
        let wrongWord = try pronunciationIssue(
            evidence: eligibleEvidence,
            selectedIPA: "kˈɑntɛnt",
            spokenForm: "Different")
        let punctuatedWord = try pronunciationIssue(
            evidence: eligibleEvidence,
            selectedIPA: "kˈɑntɛnt",
            spokenForm: "Content!")
        let nonEligible = try pronunciationIssue(
            evidence: shadowEvidence,
            selectedIPA: "kˈɑntɛnt")
        let planCalls = CallCounter()
        let model = NarrationQAReviewModel(
            db: db.writer,
            audiobookID: "b1",
            dependencies: .init(narrationPlan: { _, _ in
                await planCalls.increment()
                return []
            }))

        for issue in [wrongIPA, wrongWord, punctuatedWord, nonEligible] {
            #expect(!model.canAcceptCurrentCandidate(for: issue))
            await model.acceptCurrentCandidate(for: issue, scope: .global)
        }

        #expect(await planCalls.count() == 0)
    }

    @Test func currentCandidateActionPreservesTheIssueAndRequestedScope() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "b1"
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [bookID, "Test", 3600.0])
        }
        let block = EPubBlockRecord(
            id: "blk1", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Content.", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            narrationText: nil, sourceChapterKey: nil, createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)

        let advisory = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "current.lexicon",
            alternatives: [],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let issue = try pronunciationIssue(
            evidence: PronunciationAdvisoryIssueEvidence(
                advisoryEvidence: advisory,
                occurrenceCount: 1,
                selectedCandidate: .init(
                    candidateID: "current.lexicon",
                    ipa: "kˈɑntɛnt",
                    source: .supplementalLexicon,
                    authority: .trusted,
                    validation: .eligible)))
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let voice = VoiceID("af_heart")
        let service = NarrationService(
            db: db.writer, audiobookID: bookID, tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let plan = NarrationChapterRenderPlan(
            chapterIndex: 0, displayNumber: 1, sourceChapterKey: nil,
            title: "Chapter", blocks: [block], voice: voice)
        var acceptedIssue: NarrationQualityIssueRecord?
        var acceptedScope: FixScope?
        let model = NarrationQAReviewModel(
            db: db.writer,
            audiobookID: bookID,
            dependencies: .init(
                narrationVoice: { voice },
                narrationPlan: { _, _ in [plan] },
                applyRepair: { repairIssue, scope, _, _, _ in
                    acceptedIssue = repairIssue
                    acceptedScope = scope
                },
                narrationServiceFactory: { _, _ in service }))

        #expect(model.canAcceptCurrentCandidate(for: issue))
        await model.acceptCurrentCandidate(for: issue, scope: .book(bookID))

        #expect(acceptedIssue == issue)
        #expect(acceptedScope == .book(bookID))
    }

    @Test func ignoreRemovesFromOpenList() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.ignore(model.issues[0])
        #expect(model.issues.isEmpty)
        // Persisted as ignored.
        let ignored = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.ignored.rawValue)
        #expect(ignored.count == 1)
    }

    @Test func markResolvedPersistsResolvedAt() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        model.markResolved(model.issues[0])
        let resolved = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.resolved.rawValue)
        #expect(resolved.count == 1)
        #expect(resolved[0].resolvedAt != nil)
    }

    @Test func runFullQAWithNoRenderedAudioSurfacesError() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        // Nothing rendered → must not silently show an empty queue.
        await model.runFullQA(chapters: []) { _, _ in }
        #expect(model.lastError != nil)
    }

    @Test func runFullQASurfacesRunFailure() async throws {
        struct Boom: Error {}
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.load()
        let visibleIssues = model.issues
        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, _ in throw Boom() }
        #expect(model.lastError != nil)
        #expect(model.issues == visibleIssues)
    }

    @Test func runFullQASuccessReloadsAndClearsError() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let model = NarrationQAReviewModel(db: db.writer, audiobookID: "b1")
        model.lastError = "stale"
        var ran = false
        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, _ in ran = true }
        #expect(ran)
        #expect(model.lastError == nil)
        // Reload surfaced the seeded open issue.
        #expect(model.issues.count == 1)
    }

    @Test func runFullQAUsesConfiguredClassifierFactory() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        var capturedPreference: String?
        var capturedAvailability: Bool?
        var classifierWasInjected = false
        let dependencies = NarrationQAReviewModel.Dependencies(
            classifierPreference: { "auto" },
            foundationModelsAvailable: { true },
            classifierFactory: { preference, availability in
                capturedPreference = preference
                capturedAvailability = availability
                return MarkerClassifier()
            })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: "b1", dependencies: dependencies)

        await model.runFullQA(
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])]
        ) { _, classifier in
            classifierWasInjected = classifier is MarkerClassifier
        }

        #expect(capturedPreference == "auto")
        #expect(capturedAvailability == true)
        #expect(classifierWasInjected)
        #expect(model.lastError == nil)
    }

    @Test func renderedChaptersForQAUsesContentSignedChapterCacheFile() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "b1"
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [bookID, "Test", 3600.0])
        }
        let block = EPubBlockRecord(
            id: "blk1",
            audiobookID: bookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Deploying Kubernetes carefully.",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 2,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let voice = VoiceID("af_heart")
        let service = NarrationService(
            db: db.writer,
            audiobookID: bookID,
            tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(),
            cacheDirectory: tmp,
            state: NarrationState(),
            fmEnabled: { false })
        let signedURL = await service.chapterCacheURL(
            chapterIndex: 2,
            blocks: [block],
            voice: voice)
        _ = FileManager.default.createFile(atPath: signedURL.path, contents: Data())
        let unsignedURL = tmp.appendingPathComponent(
            NarrationFileNaming.chapterFileName(
                audiobookID: bookID,
                chapterIndex: 2,
                voice: voice))
        _ = FileManager.default.createFile(atPath: unsignedURL.path, contents: Data())

        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationPlan: { _, _ in
                [
                    NarrationChapterRenderPlan(
                        chapterIndex: 2, displayNumber: 1, sourceChapterKey: nil,
                        title: "Chapter 1", blocks: [block], voice: voice)
                ]
            },
            narrationServiceFactory: { _, _ in service })
        let model = NarrationQAReviewModel(
            db: db.writer,
            audiobookID: bookID,
            dependencies: dependencies)

        let chapters = try await model.renderedChaptersForQA(
            plans: try await dependencies.narrationPlan(bookID, voice))

        #expect(chapters.map(\.chapterIndex) == [2])
        #expect(chapters.map(\.fileURL) == [signedURL])
        #expect(chapters.first?.spokenBlockIDs == ["blk1"])
    }

    @Test func renderedChaptersForQAUsesEffectiveAnthologyVoiceAndStableKey() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "anthology"
        let sourceChapterKey = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [bookID, "Anthology", 3600.0])
        }
        let block = EPubBlockRecord(
            id: "blk-anthology", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "A chapter with an explicit voice.", htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: 4,
            isHidden: false, hiddenReason: nil, isFrontMatter: false, wordCount: nil,
            markers: nil, textFormats: nil, narrationText: nil,
            sourceChapterKey: sourceChapterKey, createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let effectiveVoice = VoiceID("bf_emma")
        let service = NarrationService(
            db: db.writer, audiobookID: bookID, tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let plan = NarrationChapterRenderPlan(
            chapterIndex: 4, displayNumber: 1, sourceChapterKey: sourceChapterKey,
            title: "Chapter 1", blocks: [block], voice: effectiveVoice)
        let signedURL = await service.chapterCacheURL(
            chapterIndex: 4, sourceChapterKey: sourceChapterKey,
            blocks: [block], voice: effectiveVoice)
        _ = FileManager.default.createFile(atPath: signedURL.path, contents: Data())

        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationPlan: { _, preferredVoice in
                #expect(preferredVoice == VoiceID("af_heart"))
                return [plan]
            },
            narrationServiceFactory: { _, _ in service })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: bookID, dependencies: dependencies)

        let chapters = try await model.renderedChaptersForQA(
            plans: try await dependencies.narrationPlan(bookID, VoiceID("af_heart")))

        #expect(chapters.map(\.chapterIndex) == [4])
        #expect(chapters.map(\.fileURL) == [signedURL])
    }

    @Test func renderedChaptersForQARequiresCompleteOrderedSegmentInventory() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "segment-only-qa"
        let sourceChapterKey = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try seed(db, book: bookID)
        let blocks = [
            EPubBlockRecord(
                id: "seg-block-0", audiobookID: bookID, spineHref: "chapter.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
                text: String(repeating: "A", count: 120), htmlContent: nil, cardColor: nil,
                chapterThemeColor: nil, imagePath: nil, chapterIndex: 2, isHidden: false,
                hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
                textFormats: nil, narrationText: nil, sourceChapterKey: sourceChapterKey,
                createdAt: nil, modifiedAt: nil),
            EPubBlockRecord(
                id: "seg-block-1", audiobookID: bookID, spineHref: "chapter.xhtml",
                spineIndex: 0, blockIndex: 1, sequenceIndex: 1, blockKind: "paragraph",
                text: "Second segment.", htmlContent: nil, cardColor: nil,
                chapterThemeColor: nil, imagePath: nil, chapterIndex: 2, isHidden: false,
                hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
                textFormats: nil, narrationText: nil, sourceChapterKey: sourceChapterKey,
                createdAt: nil, modifiedAt: nil),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let voice = VoiceID("bf_emma")
        let service = NarrationService(
            db: db.writer, audiobookID: bookID, tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let plan = NarrationChapterRenderPlan(
            chapterIndex: 2, displayNumber: 1, sourceChapterKey: sourceChapterKey,
            title: "Segmented", blocks: blocks, voice: voice)
        let segments = NarrationSegmentPlanner.segments(for: plan, isFirstChapterOfBook: true)
        var segmentURLs: [URL] = []
        for segment in segments {
            segmentURLs.append(
                await service.segmentCacheURL(
                    chapterIndex: segment.chapterIndex,
                    sourceChapterKey: segment.sourceChapterKey,
                    segmentIndex: segment.segmentIndex,
                    blocks: segment.blocks,
                    voice: segment.voice))
        }
        for url in segmentURLs {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
        }
        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationPlan: { _, _ in [plan] },
            narrationServiceFactory: { _, _ in service })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: bookID, dependencies: dependencies)

        let chapters = try await model.renderedChaptersForQA(plans: [plan])

        #expect(chapters.map(\.fileURL) == segmentURLs)
        #expect(chapters.map(\.spokenBlockIDs) == segments.map { $0.blocks.map(\.id) })

        try FileManager.default.removeItem(at: segmentURLs[1])
        let partialChapters = try await model.renderedChaptersForQA(plans: [plan])
        #expect(partialChapters.isEmpty)

        let issue = try #require(
            NarrationQualityIssueDAO(db: db.writer)
                .issues(for: bookID, status: NarrationQAIssueStatus.open.rawValue).first)
        let liveDependencies = NarrationQAReviewModel.Dependencies.live(db: db.writer)
        await #expect(throws: NarrationRepairError.sourceChapterUnavailable) {
            try await liveDependencies.applyRepair(
                issue, .book(bookID), plan, service, MarkerClassifier())
        }
        #expect(FileManager.default.fileExists(atPath: segmentURLs[0].path))
    }

    @Test func livePlanProjectsHiddenBlocksExactlyLikePlayback() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "hidden-block-qa"
        let anthologyID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let entryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try await db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [bookID, "Hidden Block Anthology", 3600.0])
        }
        let visible = EPubBlockRecord(
            id: "visible-block", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
            text: String(repeating: "Visible source. ", count: 10), htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
            isHidden: false, hiddenReason: nil, isFrontMatter: false, wordCount: nil,
            markers: nil, textFormats: nil, narrationText: nil,
            sourceChapterKey: entryID.uuidString, createdAt: nil, modifiedAt: nil)
        let hidden = EPubBlockRecord(
            id: "hidden-block", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 1, sequenceIndex: 1, blockKind: "paragraph",
            text: String(repeating: "Excluded source. ", count: 10), htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
            isHidden: true, hiddenReason: "Excluded from narration", isFrontMatter: false,
            wordCount: nil, markers: nil, textFormats: nil, narrationText: nil,
            sourceChapterKey: entryID.uuidString, createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insertAll([visible, hidden])
        let articleBlocks = [
            ArticleBlock(
                id: "article-visible", stableOrdinal: 0, kind: .paragraph,
                text: visible.text ?? "", sourceURL: nil, imageCandidateURL: nil,
                caption: nil, codeLanguage: nil),
            ArticleBlock(
                id: "article-hidden", stableOrdinal: 1, kind: .paragraph,
                text: hidden.text ?? "", sourceURL: nil, imageCandidateURL: nil,
                caption: nil, codeLanguage: nil),
        ]
        let manifest = try seedAnthologyBuild(
            db: db, audiobookID: bookID, anthologyID: anthologyID,
            entryID: entryID, articleBlocks: articleBlocks, voiceID: "bf_emma")
        let allBlocks = try EPubBlockDAO(db: db.writer).allBlocks(for: bookID)
        let visibleBlocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
        let playback = try await NarrationPlaybackPlanPreparation.prepare(
            chapters: NarrationChapterPlanner.plan(from: visibleBlocks),
            allChapters: NarrationChapterPlanner.plan(from: allBlocks),
            preferredVoice: VoiceID("af_heart"),
            resolveManifest: { manifest },
            existingDurableFileNames: [],
            expectedFileName: { segment in
                segment.blocks.map(\.id).joined(separator: "-") + "-\(segment.segmentIndex)"
            },
            cleanup: { _ in })
        let liveDependencies = NarrationQAReviewModel.Dependencies.live(db: db.writer)

        let qaPlans = try await liveDependencies.narrationPlan(
            bookID, VoiceID("af_heart"))

        #expect(qaPlans.map { $0.blocks.map(\.id) } == [["visible-block"]])
        #expect(qaPlans.map(\.voice) == [VoiceID("bf_emma")])
        #expect(
            qaPlans.map { $0.blocks.map(\.id) }
                == playback.chapters.map { $0.blocks.map(\.id) })
        #expect(
            NarrationSegmentPlanner.plan(qaPlans).map { $0.blocks.map(\.id) }
                == playback.segments.map { $0.blocks.map(\.id) })
    }

    @Test func fullQAAndAcceptFixUseIssueChaptersEffectiveVoice() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "anthology-qa"
        let sourceChapterKey = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try seed(db, book: bookID)
        let block = EPubBlockRecord(
            id: "blk1", audiobookID: bookID, spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Colonel.", htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: 6,
            isHidden: false, hiddenReason: nil, isFrontMatter: false, wordCount: nil,
            markers: nil, textFormats: nil, narrationText: nil,
            sourceChapterKey: sourceChapterKey, createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let preferredVoice = VoiceID("af_heart")
        let effectiveVoice = VoiceID("bf_emma")
        let service = NarrationService(
            db: db.writer, audiobookID: bookID, tts: MockTTSEngine(),
            audioWriter: MockAudioWriter(), cacheDirectory: tmp,
            state: NarrationState(), fmEnabled: { false })
        let plan = NarrationChapterRenderPlan(
            chapterIndex: 6, displayNumber: 1, sourceChapterKey: sourceChapterKey,
            title: "Chapter 1", blocks: [block], voice: effectiveVoice)
        let signedURL = await service.chapterCacheURL(
            chapterIndex: 6, sourceChapterKey: sourceChapterKey,
            blocks: [block], voice: effectiveVoice)
        _ = FileManager.default.createFile(atPath: signedURL.path, contents: Data())

        var qaFileURL: URL?
        var repairVoice: VoiceID?
        var repairSourceChapterKey: String?
        let dependencies = NarrationQAReviewModel.Dependencies(
            narrationVoice: { preferredVoice },
            narrationPlan: { _, voice in
                #expect(voice == preferredVoice)
                return [plan]
            },
            runQA: { _, chapters, _ in
                qaFileURL = chapters.first?.fileURL
            },
            applyRepair: { _, _, target, _, _ in
                repairVoice = target.voice
                repairSourceChapterKey = target.sourceChapterKey
            },
            narrationServiceFactory: { _, _ in service })
        let model = NarrationQAReviewModel(
            db: db.writer, audiobookID: bookID, dependencies: dependencies)

        await model.runFullQA()
        let issue = try #require(model.issues.first)
        await model.acceptFix(issue: issue, scope: .book(bookID))

        #expect(qaFileURL == signedURL)
        #expect(qaFileURL?.lastPathComponent.contains("-bf_emma-") == true)
        #expect(repairVoice == effectiveVoice)
        #expect(repairSourceChapterKey == sourceChapterKey)
    }

    private func seedAnthologyBuild(
        db: DatabaseService,
        audiobookID: String,
        anthologyID: UUID,
        entryID: UUID,
        articleBlocks: [ArticleBlock],
        voiceID: String?
    ) throws -> AnthologyBuildManifest {
        try AnthologyDAO(db: db.writer).save(
            AnthologyRecord(
                id: anthologyID.uuidString, title: "Hidden Block Anthology", subtitle: nil,
                creator: nil, coverPath: nil, nextStableSlot: 1, latestBuildRevision: 0,
                createdAt: "2026-08-02T12:00:00Z", modifiedAt: "2026-08-02T12:00:00Z"))
        let chapter = AnthologyChapterManifest(
            entryID: entryID,
            captureID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            articleRevisionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            stableSlot: 0, order: 0, title: "Chapter 1", author: nil, siteName: nil,
            sourceURL: URL(string: "https://example.test/hidden")!,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000), voiceID: voiceID,
            blocks: articleBlocks,
            readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: articleBlocks))
        let manifest = AnthologyBuildManifest(
            schemaVersion: 1, anthologyID: anthologyID, revision: 1,
            epubIdentifier: "urn:uuid:\(anthologyID.uuidString)", title: "Hidden Block Anthology",
            subtitle: nil, creator: "Various Authors", language: "en", coverPath: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_775_000_000), chapters: [chapter])
        let data = try JSONEncoder.articleWorkshop.encode(manifest)
        var build = AnthologyBuildRecord(
            id: UUID().uuidString, anthologyID: anthologyID.uuidString, revision: 1,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: data, as: UTF8.self),
            manifestSHA256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined(),
            epubPath: nil, epubSHA256: String(repeating: "a", count: 64),
            audiobookID: audiobookID, status: "succeeded", errorCode: nil,
            createdAt: "2026-08-02T12:00:00Z")
        try db.writer.write { database in try build.insert(database) }
        return manifest
    }
}
