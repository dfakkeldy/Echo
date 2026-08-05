// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
