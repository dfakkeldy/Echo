// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import CryptoKit
    import Foundation
    import OnnxRuntimeBindings

    /// Cached CPU-only Mini-BART evaluator. Its result is advisory shadow evidence;
    /// no production planner or automatic-selection API is exposed here.
    actor MiniBARTG2PEngine {
        typealias ResourceProvider = @Sendable () -> MiniBARTG2PModelResources?
        typealias SessionFactory =
            @Sendable (MiniBARTG2PVerifiedSnapshot) async throws -> MiniBARTG2PInferenceSession

        static let shared = MiniBARTG2PEngine()

        nonisolated static let modelRevision = NeuralG2PGovernedIdentity.modelRevision
        nonisolated static let validationPolicyVersion =
            NeuralG2PGovernedIdentity.validationPolicyVersion
        nonisolated static let selectionPolicyVersion =
            NeuralG2PGovernedIdentity.selectionPolicyVersion
        nonisolated static let temporaryModelDirectoryPrefix = "EchoMiniBARTG2P-"

        private nonisolated static let beamWidth = 5
        private nonisolated static let maximumSequenceLength = 20
        private nonisolated static let vocabularySize = 103
        private nonisolated static let bosID: Int64 = 0
        private nonisolated static let decoderStartID: Int64 = 2
        private nonisolated static let eosID: Int64 = 2
        private nonisolated static let padID: Int64 = 1

        private let resourceProvider: ResourceProvider
        private let sessionFactory: SessionFactory
        private var loaded: LoadedState?
        private var initializationTask: Task<LoadedState, Error>?
        private var lifecycleGeneration = 0
        private(set) var sessionLoadCountForTesting = 0

        init() {
            self.resourceProvider = { Self.bundledResources() }
            self.sessionFactory = { resources in try await Self.makeLiveSession(resources) }
        }

        init(
            resourceProvider: @escaping ResourceProvider,
            sessionFactory: @escaping SessionFactory
        ) {
            self.resourceProvider = resourceProvider
            self.sessionFactory = sessionFactory
        }

        func evaluate(word: String) async throws -> NeuralG2PShadowResult {
            do {
                try Task.checkCancellation()
                let state = try await loadIfNeeded()
                try Task.checkCancellation()

                let inputIDs: [Int64]
                do {
                    inputIDs = try state.tokenizer.encode(word: word)
                } catch {
                    throw EvaluationError.failure(.tokenization)
                }
                let attentionMask = [Int64](repeating: 1, count: inputIDs.count)

                let encoderOutput: MiniBARTG2PEncoderOutput
                do {
                    encoderOutput = try state.session.encode(inputIDs, attentionMask)
                } catch is CancellationError {
                    throw EvaluationError.failure(.cancelled)
                } catch {
                    throw EvaluationError.failure(.inference)
                }
                guard
                    encoderOutput.shape == [1, inputIDs.count, 256],
                    encoderOutput.values.count == inputIDs.count * 256,
                    encoderOutput.values.allSatisfy(\.isFinite)
                else {
                    throw EvaluationError.failure(.inference)
                }

                let beam = try decode(
                    state: state, encoderOutput: encoderOutput,
                    encoderAttentionMask: attentionMask)
                let padded =
                    beam.ids
                    + [Int64](
                        repeating: Self.padID,
                        count: max(0, Self.maximumSequenceLength - beam.ids.count))
                let normalized = Self.normalizedDecoderOutputForTesting(padded)

                let tokens: [String]
                do {
                    tokens = try state.tokenizer.decodeOutput(ids: normalized)
                } catch MiniBARTG2PTokenizer.Error.emptyOutput {
                    throw EvaluationError.failure(.emptyOutput)
                } catch {
                    throw EvaluationError.failure(.decoding)
                }

                let ipa: String
                do {
                    ipa = try ARPAbetToKokoroIPA.convert(tokens)
                } catch ARPAbetToKokoroIPA.Error.emptyTokens {
                    throw EvaluationError.failure(.emptyOutput)
                } catch {
                    throw EvaluationError.failure(.unsupportedOutput)
                }
                guard !ipa.isEmpty else { throw EvaluationError.failure(.emptyOutput) }

                return .candidate(
                    NeuralG2PCandidate(
                        candidateID: Self.candidateID(inputIDs: inputIDs, ipa: ipa),
                        ipa: ipa,
                        modelRevision: Self.modelRevision,
                        conversionPolicyVersion: ARPAbetToKokoroIPA.policyVersion,
                        validationPolicyVersion: Self.validationPolicyVersion,
                        selectionPolicyVersion: Self.selectionPolicyVersion))
            } catch let error as EvaluationError {
                return .rejected(error.failure)
            } catch is CancellationError {
                return .rejected(.cancelled)
            } catch {
                return .rejected(.inference)
            }
        }

        /// Invalidates the cached environment/session pair. A generation check in
        /// `loadIfNeeded` prevents an injected factory that ignores cancellation
        /// from restoring stale state after this method returns.
        func unload() {
            lifecycleGeneration += 1
            initializationTask?.cancel()
            initializationTask = nil
            loaded = nil
        }

        var isLoadedForTesting: Bool { loaded != nil }

        /// Task 11 requires `[2, lexical..., 2]`. Mini-BART generation emits one
        /// BART BOS immediately after decoder-start, so remove that exact
        /// generation-position control plus right padding. Any BOS elsewhere, an
        /// internal pad, decoder-start, and terminal EOS remain for validation.
        nonisolated static func normalizedDecoderOutputForTesting(_ ids: [Int64]) -> [Int64] {
            var normalized = ids
            while normalized.last == padID { normalized.removeLast() }
            if normalized.count > 2, normalized[1] == bosID {
                normalized.remove(at: 1)
            }
            return normalized
        }

        // MARK: - Lifecycle

        private func loadIfNeeded() async throws -> LoadedState {
            if let loaded { return loaded }
            if let initializationTask {
                return try await commit(
                    initializationTask, generation: lifecycleGeneration)
            }

            let generation = lifecycleGeneration
            let resourceProvider = self.resourceProvider
            let sessionFactory = self.sessionFactory
            let task = Task<LoadedState, Error> {
                try Task.checkCancellation()
                guard let resources = resourceProvider() else {
                    throw EvaluationError.failure(.unavailable)
                }
                let snapshot = try Self.validateAndSnapshot(resources)
                let tokenizer: MiniBARTG2PTokenizer
                do {
                    tokenizer = try MiniBARTG2PTokenizer(data: snapshot.tokenizerData)
                } catch {
                    throw EvaluationError.failure(.tokenization)
                }
                try Task.checkCancellation()
                let session: MiniBARTG2PInferenceSession
                do {
                    session = try await sessionFactory(snapshot)
                } catch is CancellationError {
                    throw EvaluationError.failure(.cancelled)
                } catch {
                    throw EvaluationError.failure(.inference)
                }
                try Task.checkCancellation()
                return LoadedState(tokenizer: tokenizer, session: session)
            }
            initializationTask = task
            return try await commit(task, generation: generation)
        }

        private func commit(_ task: Task<LoadedState, Error>, generation: Int) async throws
            -> LoadedState
        {
            do {
                let created = try await task.value
                guard generation == lifecycleGeneration else {
                    throw EvaluationError.failure(.cancelled)
                }
                if let loaded { return loaded }
                loaded = created
                initializationTask = nil
                sessionLoadCountForTesting += 1
                return created
            } catch {
                if generation == lifecycleGeneration { initializationTask = nil }
                throw error
            }
        }

        // MARK: - Beam decoding

        private func decode(
            state: LoadedState,
            encoderOutput: MiniBARTG2PEncoderOutput,
            encoderAttentionMask: [Int64]
        ) throws -> Beam {
            var beams = [Beam(ids: [Self.decoderStartID], score: 0, finished: false)]

            while beams.contains(where: { !$0.finished }) {
                try Task.checkCancellation()
                var expanded: [Beam] = []
                expanded.reserveCapacity(Self.beamWidth * Self.beamWidth)

                for beam in beams {
                    try Task.checkCancellation()
                    if beam.finished {
                        expanded.append(beam)
                        continue
                    }
                    if beam.ids.count == Self.maximumSequenceLength - 1 {
                        expanded.append(
                            Beam(
                                ids: beam.ids + [Self.eosID], score: beam.score,
                                finished: true))
                        continue
                    }

                    let output: MiniBARTG2PDecoderOutput
                    do {
                        output = try state.session.decode(
                            beam.ids, encoderAttentionMask, encoderOutput)
                    } catch is CancellationError {
                        throw EvaluationError.failure(.cancelled)
                    } catch {
                        throw EvaluationError.failure(.inference)
                    }
                    try Task.checkCancellation()
                    guard
                        output.shape == [1, beam.ids.count, Self.vocabularySize],
                        output.logits.count == beam.ids.count * Self.vocabularySize
                    else {
                        throw EvaluationError.failure(.inference)
                    }

                    let logits = Array(output.logits.suffix(Self.vocabularySize))
                    let logProbabilities = try Self.logSoftmax(logits)
                    let tokenIDs = logProbabilities.indices.sorted { left, right in
                        let leftScore = logProbabilities[left]
                        let rightScore = logProbabilities[right]
                        if leftScore != rightScore { return leftScore > rightScore }
                        let leftKey = Self.lexicalKey(
                            ids: beam.ids + [Int64(left)], tokenizer: state.tokenizer)
                        let rightKey = Self.lexicalKey(
                            ids: beam.ids + [Int64(right)], tokenizer: state.tokenizer)
                        if leftKey != rightKey { return leftKey < rightKey }
                        return left < right
                    }.prefix(Self.beamWidth)

                    for tokenID in tokenIDs {
                        expanded.append(
                            Beam(
                                ids: beam.ids + [Int64(tokenID)],
                                score: beam.score + logProbabilities[tokenID],
                                finished: Int64(tokenID) == Self.eosID))
                    }
                }

                beams = expanded.sorted { left, right in
                    if left.score != right.score { return left.score > right.score }
                    let leftKey = Self.lexicalKey(ids: left.ids, tokenizer: state.tokenizer)
                    let rightKey = Self.lexicalKey(ids: right.ids, tokenizer: state.tokenizer)
                    if leftKey != rightKey { return leftKey < rightKey }
                    return left.ids.lexicographicallyPrecedes(right.ids)
                }.prefix(Self.beamWidth).map { $0 }
            }

            guard
                let selected = beams.filter(\.finished).sorted(by: { left, right in
                    if left.score != right.score { return left.score > right.score }
                    let leftKey = Self.lexicalKey(ids: left.ids, tokenizer: state.tokenizer)
                    let rightKey = Self.lexicalKey(ids: right.ids, tokenizer: state.tokenizer)
                    if leftKey != rightKey { return leftKey < rightKey }
                    return left.ids.lexicographicallyPrecedes(right.ids)
                }).first
            else {
                throw EvaluationError.failure(.decoding)
            }
            return selected
        }

        private nonisolated static func logSoftmax(_ logits: [Float]) throws -> [Double] {
            guard logits.count == vocabularySize, logits.allSatisfy(\.isFinite),
                let maximum = logits.max()
            else {
                throw EvaluationError.failure(.inference)
            }
            let denominator = logits.reduce(0.0) { partial, value in
                partial + exp(Double(value - maximum))
            }
            guard denominator.isFinite, denominator > 0 else {
                throw EvaluationError.failure(.inference)
            }
            let logDenominator = log(denominator)
            return logits.map { Double($0 - maximum) - logDenominator }
        }

        private nonisolated static func lexicalKey(
            ids: [Int64], tokenizer: MiniBARTG2PTokenizer
        ) -> String {
            var complete = ids
            if complete.last != eosID { complete.append(eosID) }
            let normalized = normalizedDecoderOutputForTesting(complete)
            if let tokens = try? tokenizer.decodeOutput(ids: normalized) {
                return tokens.joined(separator: " ")
            }
            return ids.map(String.init).joined(separator: ",")
        }

        // MARK: - Locked resources

        private nonisolated static func bundledResources() -> MiniBARTG2PModelResources? {
            func resource(_ name: String, _ ext: String) -> URL? {
                NarrationResources.url(
                    forResource: name, withExtension: ext,
                    subdirectory: "NeuralG2PResources")
            }
            guard
                let encoder = resource("encoder_model", "onnx"),
                let decoder = resource("decoder_model", "onnx"),
                let tokenizer = resource("tokenizer", "json"),
                let config = resource("config", "json"),
                let generation = resource("generation_config", "json"),
                let license = resource("LICENSE", "")
            else { return nil }
            return MiniBARTG2PModelResources(
                encoderModelURL: encoder, decoderModelURL: decoder,
                tokenizerURL: tokenizer, configURL: config,
                generationConfigURL: generation, licenseURL: license)
        }

        private nonisolated static func validateAndSnapshot(
            _ resources: MiniBARTG2PModelResources
        ) throws -> MiniBARTG2PVerifiedSnapshot {
            let encoder = try verifiedData(
                at: resources.encoderModelURL, bytes: 6_634_844,
                sha256: "5df81746fe1872b63aa120205ce267ed44163b7894a54e931a1d4b4b09568faa")
            let decoder = try verifiedData(
                at: resources.decoderModelURL, bytes: 9_999_491,
                sha256: "2c199ceaa241186259167a8e79c5ff3498609ee8fc01c28c8a3d76a351d33c3d")
            let tokenizer = try verifiedData(
                at: resources.tokenizerURL, bytes: 3_212,
                sha256: "40193885f8093d3bf59dfc199db502cfa8618b24bfcb2d08aa5f8d538bc34495")
            let config = try verifiedData(
                at: resources.configURL, bytes: 1_066,
                sha256: "d647577ad51cacdab20f82c479ab8fd75ae569edba480475ca6c732881256415")
            let generationConfig = try verifiedData(
                at: resources.generationConfigURL, bytes: 182,
                sha256: "f36f1cb8f814ff32f744ced2e00610ce37de166d5a21bd92050972e220fa0449")
            let license = try verifiedData(
                at: resources.licenseURL, bytes: 11_356,
                sha256: "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1")
            return MiniBARTG2PVerifiedSnapshot(
                encoderModelData: encoder, decoderModelData: decoder,
                tokenizerData: tokenizer, configData: config,
                generationConfigData: generationConfig, licenseData: license)
        }

        /// Opens each source exactly once. `readToEnd()` copies through the open
        /// descriptor, so later path or symlink replacement cannot change the
        /// immutable bytes passed to the tokenizer or session factory.
        private nonisolated static func verifiedData(
            at url: URL, bytes: Int, sha256: String
        ) throws -> Data {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw EvaluationError.failure(.unavailable)
            }
            defer { try? handle.close() }

            let data: Data
            do {
                data = try handle.readToEnd() ?? Data()
            } catch {
                throw EvaluationError.failure(.unavailable)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == bytes, digest == sha256 else {
                throw EvaluationError.failure(.integrity)
            }
            return data
        }

        private nonisolated static func candidateID(inputIDs: [Int64], ipa: String) -> String {
            let canonical = [
                "mini-bart-g2p-candidate-v1",
                inputIDs.map(String.init).joined(separator: ","),
                ipa,
                modelRevision,
                ARPAbetToKokoroIPA.policyVersion,
                validationPolicyVersion,
                selectionPolicyVersion,
            ].joined(separator: "\n")
            let digest = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "sha256:\(digest)"
        }

        // MARK: - Live CPU ONNX session

        private nonisolated static func makeLiveSession(
            _ snapshot: MiniBARTG2PVerifiedSnapshot
        ) async throws -> MiniBARTG2PInferenceSession {
            try Task.checkCancellation()
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory.appending(
                path: "\(temporaryModelDirectoryPrefix)\(UUID().uuidString)",
                directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            defer {
                if fileManager.fileExists(atPath: directory.path) {
                    try? fileManager.removeItem(at: directory)
                }
            }

            let encoderURL = directory.appending(path: "encoder_model.onnx")
            let decoderURL = directory.appending(path: "decoder_model.onnx")
            try snapshot.encoderModelData.write(to: encoderURL, options: .atomic)
            try snapshot.decoderModelData.write(to: decoderURL, options: .atomic)
            let box = try LiveSessionBox(
                encoderModelURL: encoderURL, decoderModelURL: decoderURL)
            try fileManager.removeItem(at: directory)
            try Task.checkCancellation()
            return MiniBARTG2PInferenceSession(
                encode: { inputIDs, attentionMask in
                    try box.encode(inputIDs: inputIDs, attentionMask: attentionMask)
                },
                decode: { decoderIDs, encoderMask, encoderOutput in
                    try box.decode(
                        decoderIDs: decoderIDs, encoderMask: encoderMask,
                        encoderOutput: encoderOutput)
                })
        }

        private struct LoadedState: Sendable {
            let tokenizer: MiniBARTG2PTokenizer
            let session: MiniBARTG2PInferenceSession
        }

        private struct Beam {
            let ids: [Int64]
            let score: Double
            let finished: Bool
        }

        private enum EvaluationError: Error, Sendable {
            case failure(NeuralG2PFailure)

            var failure: NeuralG2PFailure {
                switch self {
                case .failure(let failure): failure
                }
            }
        }
    }

    /// ORT Objective-C reference types are confined to `MiniBARTG2PEngine`.
    /// `@unchecked Sendable` permits their capture by the engine's injected
    /// `@Sendable` closures; callers cannot obtain this box or run it concurrently.
    private nonisolated final class LiveSessionBox: @unchecked Sendable {
        private let env: ORTEnv
        private let encoder: ORTSession
        private let decoder: ORTSession
        private let runOptions: ORTRunOptions

        init(encoderModelURL: URL, decoderModelURL: URL) throws {
            env = try ORTEnv(loggingLevel: .warning)
            let encoderOptions = try Self.sessionOptions()
            let decoderOptions = try Self.sessionOptions()
            encoder = try ORTSession(
                env: env, modelPath: encoderModelURL.path,
                sessionOptions: encoderOptions)
            decoder = try ORTSession(
                env: env, modelPath: decoderModelURL.path,
                sessionOptions: decoderOptions)
            runOptions = try ORTRunOptions()
            try runOptions.addConfigEntry(
                withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
        }

        func encode(inputIDs: [Int64], attentionMask: [Int64]) throws
            -> MiniBARTG2PEncoderOutput
        {
            let input = try ORTValue(
                tensorData: Self.tensorData(inputIDs), elementType: .int64,
                shape: [1, NSNumber(value: inputIDs.count)])
            let mask = try ORTValue(
                tensorData: Self.tensorData(attentionMask), elementType: .int64,
                shape: [1, NSNumber(value: attentionMask.count)])
            let outputs = try encoder.run(
                withInputs: ["input_ids": input, "attention_mask": mask],
                outputNames: ["last_hidden_state"], runOptions: runOptions)
            guard let value = outputs["last_hidden_state"] else {
                throw LiveSessionError.missingOutput
            }
            return MiniBARTG2PEncoderOutput(
                values: try Self.floatArray(value), shape: try Self.shape(value))
        }

        func decode(
            decoderIDs: [Int64], encoderMask: [Int64],
            encoderOutput: MiniBARTG2PEncoderOutput
        ) throws -> MiniBARTG2PDecoderOutput {
            let decoderInput = try ORTValue(
                tensorData: Self.tensorData(decoderIDs), elementType: .int64,
                shape: [1, NSNumber(value: decoderIDs.count)])
            let mask = try ORTValue(
                tensorData: Self.tensorData(encoderMask), elementType: .int64,
                shape: [1, NSNumber(value: encoderMask.count)])
            let hidden = try ORTValue(
                tensorData: Self.tensorData(encoderOutput.values), elementType: .float,
                shape: encoderOutput.shape.map(NSNumber.init(value:)))
            let outputs = try decoder.run(
                withInputs: [
                    "input_ids": decoderInput,
                    "encoder_attention_mask": mask,
                    "encoder_hidden_states": hidden,
                ], outputNames: ["logits"], runOptions: runOptions)
            guard let value = outputs["logits"] else { throw LiveSessionError.missingOutput }
            return MiniBARTG2PDecoderOutput(
                logits: try Self.floatArray(value), shape: try Self.shape(value))
        }

        private static func sessionOptions() throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            try options.setIntraOpNumThreads(2)
            return options
        }

        private static func shape(_ value: ORTValue) throws -> [Int] {
            try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
        }

        private static func floatArray(_ value: ORTValue) throws -> [Float] {
            let data = try value.tensorData()
            let count = data.length / MemoryLayout<Float>.stride
            guard count > 0 else { return [] }
            var output = [Float](repeating: 0, count: count)
            output.withUnsafeMutableBytes { destination in
                destination.copyMemory(
                    from: UnsafeRawBufferPointer(start: data.bytes, count: destination.count))
            }
            return output
        }

        private static func tensorData<T>(_ values: [T]) -> NSMutableData {
            values.withUnsafeBufferPointer { buffer in
                NSMutableData(
                    bytes: buffer.baseAddress,
                    length: buffer.count * MemoryLayout<T>.stride)
            }
        }

        private enum LiveSessionError: Error { case missingOutput }
    }
#endif
