// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    @Suite(.serialized) struct MiniBARTG2PEngineTests {
        private enum DecodeFixture: Sendable {
            case cat
            case empty
            case unsupported
            case malformed
            case noEOS
            case lexicalTie
            case beamWidth
            case cancelAfterFirstStep
            case nanLogits
            case infiniteLogits
        }

        @Test func cachesOneSessionPairAcrossWordsAndReloadsAfterUnload() async throws {
            let engine = engine(fixture: .cat)

            _ = try await engine.evaluate(word: "cat")
            _ = try await engine.evaluate(word: "dog")
            #expect(await engine.sessionLoadCountForTesting == 1)

            await engine.unload()
            #expect(await engine.isLoadedForTesting == false)

            _ = try await engine.evaluate(word: "cat")
            #expect(await engine.sessionLoadCountForTesting == 2)
        }

        @Test func unloadDuringLoadCannotResurrectTheStaleSession() async throws {
            let delayed = DelayedSessionFactory(session: Self.session(fixture: .cat))
            let engine = MiniBARTG2PEngine(
                resourceProvider: { Self.lockedResources() },
                sessionFactory: { resources in try await delayed.make(resources: resources) })

            let evaluation = Task { try await engine.evaluate(word: "cat") }
            await delayed.waitUntilEntered()
            await engine.unload()
            await delayed.release()

            #expect(
                try await evaluation.value
                    == NeuralG2PShadowResult.rejected(NeuralG2PFailure.cancelled))
            #expect(await engine.isLoadedForTesting == false)

            #expect(try await engine.evaluate(word: "cat") == Self.catCandidate())
            #expect(await engine.sessionLoadCountForTesting == 1)
        }

        @Test func cancellationBeforeAndBetweenDecodeStepsIsCategorized() async throws {
            let before = engine(fixture: .cat)
            let cancelledBefore = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await before.evaluate(word: "cat")
            }
            #expect(try await cancelledBefore.value == .rejected(.cancelled))

            let between = engine(fixture: .cancelAfterFirstStep)
            let cancelledBetween = Task { try await between.evaluate(word: "cat") }
            #expect(try await cancelledBetween.value == .rejected(.cancelled))
        }

        @Test func unavailableAndCorruptResourcesFailClosed() async throws {
            let unavailable = MiniBARTG2PEngine(
                resourceProvider: { nil },
                sessionFactory: { _ in Self.session(fixture: .cat) })
            #expect(try await unavailable.evaluate(word: "cat") == .rejected(.unavailable))

            var corrupt = try #require(Self.lockedResources())
            corrupt.encoderModelURL = corrupt.configURL
            let corruptResources = corrupt
            let integrity = MiniBARTG2PEngine(
                resourceProvider: { corruptResources },
                sessionFactory: { _ in Self.session(fixture: .cat) })
            #expect(try await integrity.evaluate(word: "cat") == .rejected(.integrity))
        }

        @Test func verifiedSnapshotSurvivesSourceSymlinkSwapsBeforeSessionCreation() async throws {
            let fixture = try Self.symlinkFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let recorder = VerifiedSnapshotRecorder()

            let engine = MiniBARTG2PEngine(
                resourceProvider: { fixture.resources },
                sessionFactory: { snapshot in
                    try Self.replaceArtifactLinksWithPoison(fixture)
                    await recorder.record(snapshot)
                    return Self.session(fixture: .cat)
                })

            #expect(try await engine.evaluate(word: "cat") == Self.catCandidate())
            let captured = try #require(await recorder.snapshot())
            #expect(captured.encoderModelData == fixture.expected.encoderModelData)
            #expect(captured.decoderModelData == fixture.expected.decoderModelData)
            #expect(captured.tokenizerData == fixture.expected.tokenizerData)
            #expect(captured.configData == fixture.expected.configData)
            #expect(captured.generationConfigData == fixture.expected.generationConfigData)
            #expect(captured.licenseData == fixture.expected.licenseData)
            for url in fixture.artifactURLs {
                #expect(try Data(contentsOf: url) == fixture.poisonData)
            }
        }

        @Test func tokenizationInferenceAndOutputFailuresAreCategorized() async throws {
            #expect(
                try await engine(fixture: .cat).evaluate(word: "two words")
                    == .rejected(.tokenization))

            let badEncoder = MiniBARTG2PInferenceSession(
                encode: { _, _ in .init(values: [0], shape: [1, 1]) },
                decode: Self.session(fixture: .cat).decode)
            let malformedEncoder = MiniBARTG2PEngine(
                resourceProvider: { Self.lockedResources() },
                sessionFactory: { _ in badEncoder })
            #expect(
                try await malformedEncoder.evaluate(word: "cat") == .rejected(.inference))

            #expect(
                try await engine(fixture: .malformed).evaluate(word: "cat")
                    == .rejected(.inference))
            #expect(
                try await engine(fixture: .empty).evaluate(word: "cat")
                    == .rejected(.emptyOutput))
            #expect(
                try await engine(fixture: .unsupported).evaluate(word: "cat")
                    == .rejected(.unsupportedOutput))
        }

        @Test func correctShapeNonFiniteEncoderAndLogitValuesAreRejected() async throws {
            for nonFinite in [Float.nan, Float.infinity] {
                let nonFiniteEncoder = MiniBARTG2PInferenceSession(
                    encode: { inputIDs, _ in
                        var values = [Float](repeating: 0, count: inputIDs.count * 256)
                        values[0] = nonFinite
                        return .init(values: values, shape: [1, inputIDs.count, 256])
                    },
                    decode: Self.session(fixture: .cat).decode)
                let engine = MiniBARTG2PEngine(
                    resourceProvider: { Self.lockedResources() },
                    sessionFactory: { _ in nonFiniteEncoder })
                #expect(try await engine.evaluate(word: "cat") == .rejected(.inference))
            }

            #expect(
                try await engine(fixture: .nanLogits).evaluate(word: "cat")
                    == .rejected(.inference))
            #expect(
                try await engine(fixture: .infiniteLogits).evaluate(word: "cat")
                    == .rejected(.inference))
        }

        @Test func beamWidthIsExactlyFive() async throws {
            let result = try await engine(fixture: .beamWidth).evaluate(word: "cat")
            guard case .candidate(let candidate) = result else {
                Issue.record("expected a candidate, got \(result)")
                return
            }
            #expect(candidate.ipa == "pə")
        }

        @Test func maximumOutputLengthIsTwentyIncludingBoundaries() async throws {
            let result = try await engine(fixture: .noEOS).evaluate(word: "cat")
            guard case .candidate(let candidate) = result else {
                Issue.record("expected a candidate, got \(result)")
                return
            }
            #expect(candidate.ipa == String(repeating: "k", count: 18))
        }

        @Test func lexicalOrderingIsTheFinalScoreTieBreaker() async throws {
            let result = try await engine(fixture: .lexicalTie).evaluate(word: "cat")
            guard case .candidate(let candidate) = result else {
                Issue.record("expected a candidate, got \(result)")
                return
            }
            #expect(candidate.ipa == "kə")
        }

        @Test func candidateIsStableShadowEvidenceWithFrozenIdentities() async throws {
            let engine = engine(fixture: .cat)
            let first = try await engine.evaluate(word: "cat")
            let second = try await engine.evaluate(word: "cat")

            #expect(first == second)
            #expect(first == Self.catCandidate())
            guard case .candidate(let candidate) = first else { return }
            #expect(candidate.modelRevision == MiniBARTG2PEngine.modelRevision)
            #expect(candidate.conversionPolicyVersion == ARPAbetToKokoroIPA.policyVersion)
            #expect(candidate.validationPolicyVersion == "kokoro-vocab-validation-v1")
            #expect(candidate.selectionPolicyVersion == "mini-bart-g2p-beam5-max20-v1")
        }

        @Test func finalizedBeamNormalizesModelBOSAndRightPaddingBeforeDecode() async throws {
            let result = try await engine(fixture: .cat).evaluate(word: "cat")
            #expect(result == Self.catCandidate())

            #expect(
                MiniBARTG2PEngine.normalizedDecoderOutputForTesting([2, 20, 38, 18, 2, 1, 1])
                    == [2, 20, 38, 18, 2])
            #expect(
                MiniBARTG2PEngine.normalizedDecoderOutputForTesting([2, 0, 20, 38, 18, 2, 1])
                    == [2, 20, 38, 18, 2])
            #expect(
                MiniBARTG2PEngine.normalizedDecoderOutputForTesting([2, 20, 1, 18, 2, 1])
                    == [2, 20, 1, 18, 2])
            #expect(
                MiniBARTG2PEngine.normalizedDecoderOutputForTesting([2, 20, 0, 18, 2, 1])
                    == [2, 20, 0, 18, 2])
        }

        @Test func projectCopiesArtifactsOnlyToIOSMacOSAndCLIHosts() throws {
            let project = try String(
                contentsOf: Self.repositoryRoot().appending(path: "Echo.xcodeproj/project.pbxproj"),
                encoding: .utf8)
            let appResources = try #require(
                project.slice(from: "CC08EC572F9522F600206D2F /* Resources */ = {", to: "};"))
            let macResources = try #require(
                project.slice(from: "AA0100000000000000000031 /* Resources */ = {", to: "};"))
            let cliResources = try #require(
                project.slice(
                    from: "95300DF22F2694306AD5F79C /* Copy Narration Resources */ = {",
                    to: "};"))
            let widgetExceptions = try #require(
                project.slice(
                    from:
                        "CC33EBB42FB41C610035179D /* Exceptions for \"EchoCore\" folder in \"Echo WidgetExtension\" target */ = {",
                    to: "};"))
            let widgetResources = try #require(
                project.slice(from: "CC00BC4B2FA6B66400323F38 /* Resources */ = {", to: "};"))
            let watchResources = try #require(
                project.slice(from: "CCC48E992FA6AB330003458B /* Resources */ = {", to: "};"))
            let widgetTarget = try #require(
                project.slice(
                    from:
                        "CC00BC4C2FA6B66400323F38 /* Echo WidgetExtension */ = {\n\t\t\tisa = PBXNativeTarget;",
                    to: "productType = \"com.apple.product-type.app-extension\";\n\t\t};"))
            let watchTarget = try #require(
                project.slice(
                    from:
                        "CCC48E9A2FA6AB330003458B /* Echo Watch App */ = {\n\t\t\tisa = PBXNativeTarget;",
                    to: "productType = \"com.apple.product-type.application\";\n\t\t};"))

            for name in Self.artifactNames {
                #expect(appResources.contains(name), "iOS must copy \(name)")
                #expect(macResources.contains(name), "macOS must copy \(name)")
                #expect(cliResources.contains(name), "echo-cli must copy \(name)")
                let synchronizedPath = "Services/Narration/NeuralG2PResources/\(name)"
                #expect(
                    !widgetExceptions.contains(synchronizedPath),
                    "Widget cross-group membership must not include \(name)")
                #expect(!widgetResources.contains(name), "Widget must not copy \(name)")
                #expect(!watchResources.contains(name), "Watch must not copy \(name)")
                #expect(!widgetTarget.contains(name), "Widget target must not reference \(name)")
                #expect(!watchTarget.contains(name), "Watch target must not reference \(name)")
            }
            #expect(!widgetTarget.contains("CC08EC5B2F9522F600206D2F /* EchoCore */"))
            #expect(!watchTarget.contains("CC08EC5B2F9522F600206D2F /* EchoCore */"))
        }

        @Test func bundledLiveSessionSurvivesImmediateModelCleanupAndRelaunch() async throws {
            await MiniBARTG2PEngine.shared.unload()
            let baseline = try Self.temporaryModelDirectories()

            for _ in 0..<2 {
                let result = try await MiniBARTG2PEngine.shared.evaluate(word: "cat")
                guard case .candidate(let candidate) = result else {
                    Issue.record("live locked artifact smoke rejected: \(result)")
                    return
                }
                #expect(!candidate.ipa.isEmpty)
                #expect(candidate.selectionPolicyVersion == "mini-bart-g2p-beam5-max20-v1")
                #expect(try Self.temporaryModelDirectories() == baseline)
                await MiniBARTG2PEngine.shared.unload()
            }
        }

        private static let artifactNames = [
            "encoder_model.onnx", "decoder_model.onnx", "tokenizer.json", "config.json",
            "generation_config.json", "LICENSE",
        ]

        private static func catCandidate() -> NeuralG2PShadowResult {
            .candidate(
                NeuralG2PCandidate(
                    candidateID:
                        "sha256:797ec4ca8c44fb2a71b66e81fdf92f4366c866f264e9801a85175b8ec2c6b773",
                    ipa: "kˈæt",
                    modelRevision: "f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06",
                    conversionPolicyVersion: "mini-bart-arpabet-to-kokoro-v1",
                    validationPolicyVersion: "kokoro-vocab-validation-v1",
                    selectionPolicyVersion: "mini-bart-g2p-beam5-max20-v1"))
        }

        private nonisolated static func lockedResources() -> MiniBARTG2PModelResources? {
            let root = repositoryRoot().appending(
                path: "EchoCore/Services/Narration/NeuralG2PResources", directoryHint: .isDirectory)
            return MiniBARTG2PModelResources(
                encoderModelURL: root.appending(path: "encoder_model.onnx"),
                decoderModelURL: root.appending(path: "decoder_model.onnx"),
                tokenizerURL: root.appending(path: "tokenizer.json"),
                configURL: root.appending(path: "config.json"),
                generationConfigURL: root.appending(path: "generation_config.json"),
                licenseURL: root.appending(path: "LICENSE"))
        }

        private nonisolated static func repositoryRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        private nonisolated static func symlinkFixture() throws -> SymlinkFixture {
            let original = try #require(lockedResources())
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "EchoMiniBARTG2PTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            let poisonData = Data("swapped-after-snapshot".utf8)
            let poisonURL = directory.appending(path: "poison")
            try poisonData.write(to: poisonURL)

            func link(_ source: URL, named name: String) throws -> URL {
                let url = directory.appending(path: name)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
                return url
            }

            let resources = MiniBARTG2PModelResources(
                encoderModelURL: try link(original.encoderModelURL, named: "encoder_model.onnx"),
                decoderModelURL: try link(original.decoderModelURL, named: "decoder_model.onnx"),
                tokenizerURL: try link(original.tokenizerURL, named: "tokenizer.json"),
                configURL: try link(original.configURL, named: "config.json"),
                generationConfigURL: try link(
                    original.generationConfigURL, named: "generation_config.json"),
                licenseURL: try link(original.licenseURL, named: "LICENSE"))
            let expected = ExpectedArtifactBytes(
                encoderModelData: try Data(contentsOf: original.encoderModelURL),
                decoderModelData: try Data(contentsOf: original.decoderModelURL),
                tokenizerData: try Data(contentsOf: original.tokenizerURL),
                configData: try Data(contentsOf: original.configURL),
                generationConfigData: try Data(contentsOf: original.generationConfigURL),
                licenseData: try Data(contentsOf: original.licenseURL))
            return SymlinkFixture(
                directory: directory, resources: resources,
                artifactURLs: resources.urls, poisonURL: poisonURL,
                poisonData: poisonData, expected: expected)
        }

        private nonisolated static func replaceArtifactLinksWithPoison(
            _ fixture: SymlinkFixture
        ) throws {
            for url in fixture.artifactURLs {
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(
                    at: url, withDestinationURL: fixture.poisonURL)
            }
        }

        private nonisolated static func temporaryModelDirectories() throws -> Set<String> {
            Set(
                try FileManager.default.contentsOfDirectory(
                    at: FileManager.default.temporaryDirectory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
                    .filter { $0.hasPrefix(MiniBARTG2PEngine.temporaryModelDirectoryPrefix) })
        }

        private func engine(fixture: DecodeFixture) -> MiniBARTG2PEngine {
            MiniBARTG2PEngine(
                resourceProvider: { Self.lockedResources() },
                sessionFactory: { _ in Self.session(fixture: fixture) })
        }

        private nonisolated static func session(fixture: DecodeFixture)
            -> MiniBARTG2PInferenceSession
        {
            MiniBARTG2PInferenceSession(
                encode: { inputIDs, _ in
                    .init(
                        values: [Float](repeating: 0, count: inputIDs.count * 256),
                        shape: [1, inputIDs.count, 256])
                },
                decode: { decoderIDs, _, _ in
                    if case .cancelAfterFirstStep = fixture {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    if case .malformed = fixture {
                        return .init(logits: [0], shape: [1, decoderIDs.count, 102])
                    }

                    var last = [Float](repeating: -100, count: 103)
                    let lexicalCount = decoderIDs.count - 1
                    switch fixture {
                    case .cat, .cancelAfterFirstStep:
                        let output: [Int] = [20, 38, 18, 2]
                        last[output[min(lexicalCount, output.count - 1)]] = 10
                    case .empty:
                        last[2] = 10
                    case .unsupported:
                        last[lexicalCount == 0 ? 6 : 2] = 10
                    case .noEOS:
                        last[20] = 10
                    case .lexicalTie:
                        if lexicalCount == 0 {
                            last[20] = 10
                            last[36] = 10
                        } else if lexicalCount == 1 {
                            last[11] = 10
                        } else {
                            last[2] = 10
                        }
                    case .beamWidth:
                        if lexicalCount == 0 {
                            for (id, score) in zip(
                                [20, 17, 27, 13, 36, 19],
                                [1.05, 1.04, 1.03, 1.02, 1.01, 1.0])
                            {
                                last[id] = Float(score)
                            }
                        } else if lexicalCount == 1 {
                            switch decoderIDs[1] {
                            case 36:
                                last[11] = 2.2
                                last[38] = 0
                            case 19:
                                last[11] = 100
                            default:
                                last = [Float](repeating: 0, count: 103)
                            }
                        } else {
                            last[2] = 100
                        }
                    case .malformed:
                        break
                    case .nanLogits:
                        last[20] = .nan
                    case .infiniteLogits:
                        last[20] = .infinity
                    }

                    var logits = [Float](repeating: 0, count: decoderIDs.count * 103)
                    logits.replaceSubrange(logits.count - 103..<logits.count, with: last)
                    return .init(logits: logits, shape: [1, decoderIDs.count, 103])
                })
        }
    }

    private struct ExpectedArtifactBytes: Sendable {
        let encoderModelData: Data
        let decoderModelData: Data
        let tokenizerData: Data
        let configData: Data
        let generationConfigData: Data
        let licenseData: Data
    }

    private struct SymlinkFixture: Sendable {
        let directory: URL
        let resources: MiniBARTG2PModelResources
        let artifactURLs: [URL]
        let poisonURL: URL
        let poisonData: Data
        let expected: ExpectedArtifactBytes
    }

    private actor VerifiedSnapshotRecorder {
        private var value: MiniBARTG2PVerifiedSnapshot?

        func record(_ snapshot: MiniBARTG2PVerifiedSnapshot) { value = snapshot }
        func snapshot() -> MiniBARTG2PVerifiedSnapshot? { value }
    }

    private actor DelayedSessionFactory {
        private let session: MiniBARTG2PInferenceSession
        private let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        private let releaseStream: AsyncStream<Void>
        private let releaseContinuation: AsyncStream<Void>.Continuation
        private var callCount = 0

        init(session: MiniBARTG2PInferenceSession) {
            (entered, enteredContinuation) = AsyncStream.makeStream()
            (releaseStream, releaseContinuation) = AsyncStream.makeStream()
            self.session = session
        }

        func make(resources _: MiniBARTG2PVerifiedSnapshot) async throws
            -> MiniBARTG2PInferenceSession
        {
            callCount += 1
            if callCount == 1 {
                enteredContinuation.yield(())
                var iterator = releaseStream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return session
        }

        func waitUntilEntered() async {
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
        }

        func release() {
            releaseContinuation.yield(())
            releaseContinuation.finish()
        }
    }

    extension String {
        fileprivate func slice(from start: String, to end: String) -> Substring? {
            guard let startRange = range(of: start) else { return nil }
            let suffix = self[startRange.lowerBound...]
            guard let endRange = suffix.range(of: end) else { return nil }
            return suffix[..<endRange.upperBound]
        }
    }

    extension MiniBARTG2PModelResources {
        fileprivate nonisolated var urls: [URL] {
            [
                encoderModelURL, decoderModelURL, tokenizerURL, configURL,
                generationConfigURL, licenseURL,
            ]
        }
    }
#endif
