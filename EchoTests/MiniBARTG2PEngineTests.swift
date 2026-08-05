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

        @Test func projectCopiesEveryLockedArtifactToIOSMacOSAndCLI() throws {
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

            for name in Self.artifactNames {
                #expect(appResources.contains(name), "iOS must copy \(name)")
                #expect(macResources.contains(name), "macOS must copy \(name)")
                #expect(cliResources.contains(name), "echo-cli must copy \(name)")
            }
        }

        @Test func bundledLockedArtifactsRunInTheLiveORTSession() async throws {
            let result = try await MiniBARTG2PEngine.shared.evaluate(word: "cat")
            guard case .candidate(let candidate) = result else {
                Issue.record("live locked artifact smoke rejected: \(result)")
                return
            }
            #expect(!candidate.ipa.isEmpty)
            #expect(candidate.selectionPolicyVersion == "mini-bart-g2p-beam5-max20-v1")
            await MiniBARTG2PEngine.shared.unload()
        }

        private static let artifactNames = [
            "encoder_model.onnx", "decoder_model.onnx", "tokenizer.json", "config.json",
            "generation_config.json", "LICENSE",
        ]

        private static func catCandidate() -> NeuralG2PShadowResult {
            .candidate(
                NeuralG2PCandidate(
                    candidateID:
                        "sha256:fa7cda6d1e79d74d18a87ee9e0c9cb13ad26927dec59536073511eeda48572d1",
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
                    }

                    var logits = [Float](repeating: 0, count: decoderIDs.count * 103)
                    logits.replaceSubrange(logits.count - 103..<logits.count, with: last)
                    return .init(logits: logits, shape: [1, decoderIDs.count, 103])
                })
        }
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

        func make(resources _: MiniBARTG2PModelResources) async throws
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
#endif
