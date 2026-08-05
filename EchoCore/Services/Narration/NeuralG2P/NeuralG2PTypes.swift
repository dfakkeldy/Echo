// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One governed identity for the locked Stage 3 shadow model and every policy
/// that turns its output into an advisory alternative.
nonisolated enum NeuralG2PGovernedIdentity {
    private static let namespacePrefix = "mini-bart-g2p"
    private static let candidateIDPrefix = "sha256:"

    static let modelRevision = "f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06"
    static let conversionPolicyVersion = "mini-bart-arpabet-to-kokoro-v1"
    static let validationPolicyVersion = "kokoro-vocab-validation-v1"
    static let selectionPolicyVersion = "mini-bart-g2p-beam5-max20-v1"
    static let alternativeSource =
        "mini-bart-g2p@\(modelRevision)"
        + "|\(conversionPolicyVersion)|\(validationPolicyVersion)"

    static func claimsNamespace(source: String, selectionPolicyVersion: String) -> Bool {
        source.hasPrefix(namespacePrefix)
            || selectionPolicyVersion.hasPrefix(namespacePrefix)
    }

    static func isValidCandidateID(_ candidateID: String) -> Bool {
        guard candidateID.hasPrefix(candidateIDPrefix) else { return false }
        let digest = candidateID.dropFirst(candidateIDPrefix.count)
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    static func normalizedKokoroIPA(_ ipa: String) -> String? {
        let normalized = ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            let vocabulary = try? KokoroPhonemeVocab(),
            (try? vocabulary.validatedIDs(forPhonemes: normalized)) != nil
        else {
            return nil
        }
        return normalized
    }

    static func validatedIPA(for candidate: NeuralG2PCandidate) -> String? {
        guard isValidCandidateID(candidate.candidateID),
            candidate.modelRevision == modelRevision,
            candidate.conversionPolicyVersion == conversionPolicyVersion,
            candidate.validationPolicyVersion == validationPolicyVersion,
            candidate.selectionPolicyVersion == selectionPolicyVersion
        else {
            return nil
        }
        return normalizedKokoroIPA(candidate.ipa)
    }
}

nonisolated struct NeuralG2PCandidate: Codable, Equatable, Sendable {
    let candidateID: String
    let ipa: String
    let modelRevision: String
    let conversionPolicyVersion: String
    let validationPolicyVersion: String
    let selectionPolicyVersion: String
}

nonisolated enum NeuralG2PFailure: String, Codable, Sendable {
    case unavailable, integrity, tokenization, inference, decoding
    case emptyOutput, unsupportedOutput, cancelled
}

nonisolated enum NeuralG2PShadowResult: Equatable, Sendable {
    case candidate(NeuralG2PCandidate)
    case rejected(NeuralG2PFailure)
}

/// Exact bundled files admitted by the immutable Mini-BART lock.
nonisolated struct MiniBARTG2PModelResources: Sendable {
    var encoderModelURL: URL
    var decoderModelURL: URL
    var tokenizerURL: URL
    var configURL: URL
    var generationConfigURL: URL
    var licenseURL: URL
}

/// Immutable bytes admitted by the model lock. The tokenizer and inference
/// factory consume this snapshot rather than reopening caller-controlled URLs.
nonisolated struct MiniBARTG2PVerifiedSnapshot: Sendable {
    let encoderModelData: Data
    let decoderModelData: Data
    let tokenizerData: Data
    let configData: Data
    let generationConfigData: Data
    let licenseData: Data
}

/// Sendable tensor snapshots keep tests independent of ONNX Runtime and keep
/// runtime-owned ORT values inside the actor-confined live session wrapper.
nonisolated struct MiniBARTG2PEncoderOutput: Sendable {
    let values: [Float]
    let shape: [Int]
}

nonisolated struct MiniBARTG2PDecoderOutput: Sendable {
    let logits: [Float]
    let shape: [Int]
}

/// Injected inference boundary. Production closures capture one environment and
/// one encoder/decoder session pair; tests supply deterministic tensor outputs.
nonisolated struct MiniBARTG2PInferenceSession: Sendable {
    let encode:
        @Sendable (_ inputIDs: [Int64], _ attentionMask: [Int64]) throws
            -> MiniBARTG2PEncoderOutput
    let decode:
        @Sendable (
            _ decoderInputIDs: [Int64], _ encoderAttentionMask: [Int64],
            _ encoderOutput: MiniBARTG2PEncoderOutput
        ) throws -> MiniBARTG2PDecoderOutput
}
