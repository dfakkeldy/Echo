// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

typealias PlannedNarrationChapter = NarrationChapterPlanner.PlannedChapter

nonisolated struct BlockVoicePlanDocument: Decodable, Sendable {
    let schemaVersion: Int
    let source: Source
    let defaultSpeakerID: String
    let speakers: [Speaker]
    let assignments: [Assignment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, source, defaultSpeakerID, speakers, assignments
    }

    struct Source: Decodable, Sendable {
        let epubSHA256: String

        enum CodingKeys: String, CodingKey { case epubSHA256 }
    }

    struct Speaker: Decodable, Sendable {
        let id: String
        let voiceID: String

        enum CodingKeys: String, CodingKey { case id, voiceID }
    }

    struct Assignment: Decodable, Sendable {
        let speakerID: String
        let blocks: [String]?
        let range: Range?

        enum CodingKeys: String, CodingKey { case speakerID, blocks, range }

        struct Range: Decodable, Sendable {
            let start: String
            let end: String

            enum CodingKeys: String, CodingKey { case start, end }
        }
    }
}

nonisolated struct ResolvedBlockVoice: Codable, Equatable, Sendable {
    let blockID: String
    let speakerID: String
    let voiceID: VoiceID
}

nonisolated struct ResolvedBlockVoicePlan: Equatable, Sendable {
    let sourceEPUBSHA256: String
    let defaultSpeakerID: String
    let blocks: [ResolvedBlockVoice]
    let voicePlanSHA256: String

    private let voicesByBlockID: [String: VoiceID]
    private let speakersByBlockID: [String: String]
    private let defaultVoiceID: VoiceID

    init(
        sourceEPUBSHA256: String,
        defaultSpeakerID: String,
        defaultVoiceID: VoiceID,
        blocks: [ResolvedBlockVoice]
    ) {
        self.sourceEPUBSHA256 = sourceEPUBSHA256
        self.defaultSpeakerID = defaultSpeakerID
        self.blocks = blocks
        voicesByBlockID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.blockID, $0.voiceID) })
        speakersByBlockID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.blockID, $0.speakerID) })
        self.defaultVoiceID = defaultVoiceID
        voicePlanSHA256 = Self.sha256(of: Self.canonicalData(
            sourceEPUBSHA256: sourceEPUBSHA256,
            defaultSpeakerID: defaultSpeakerID,
            blocks: blocks))
    }

    var voicePlanID: String { "plan-" + voicePlanSHA256.prefix(12) }
    var defaultVoice: VoiceID { defaultVoiceID }

    func voice(forBlockID blockID: String) -> VoiceID {
        precondition(voicesByBlockID[blockID] != nil, "Voice plan omitted speakable block \(blockID).")
        return voicesByBlockID[blockID]!
    }

    func speaker(forBlockID blockID: String) -> String {
        precondition(speakersByBlockID[blockID] != nil, "Voice plan omitted speakable block \(blockID).")
        return speakersByBlockID[blockID]!
    }

    func chapterDigest(blockIDs: [String]) -> String {
        let chapterBlocks = blockIDs.map { blockID -> ResolvedBlockVoice in
            precondition(voicesByBlockID[blockID] != nil, "Voice plan omitted speakable block \(blockID).")
            return ResolvedBlockVoice(
                blockID: blockID,
                speakerID: speakersByBlockID[blockID]!,
                voiceID: voicesByBlockID[blockID]!)
        }
        return Self.sha256(of: try! JSONEncoder.compactSortedData(chapterBlocks))
    }

    private struct CanonicalDocument: Codable {
        let schemaVersion: Int
        let sourceEPUBSHA256: String
        let defaultSpeakerID: String
        let blocks: [ResolvedBlockVoice]

        init(sourceEPUBSHA256: String, defaultSpeakerID: String, blocks: [ResolvedBlockVoice]) {
            schemaVersion = 1
            self.sourceEPUBSHA256 = sourceEPUBSHA256
            self.defaultSpeakerID = defaultSpeakerID
            self.blocks = blocks
        }
    }

    private static func canonicalData(
        sourceEPUBSHA256: String, defaultSpeakerID: String, blocks: [ResolvedBlockVoice]
    ) -> Data {
        try! JSONEncoder.compactSortedData(CanonicalDocument(
            sourceEPUBSHA256: sourceEPUBSHA256,
            defaultSpeakerID: defaultSpeakerID,
            blocks: blocks))
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum BlockVoicePlanError: LocalizedError, Equatable {
    case malformedJSON(String)
    case duplicateJSONKey(String)
    case unsupportedSchema(Int)
    case unknownField(String)
    case invalidSourceSHA256(String)
    case sourceMismatch(expected: String, actual: String)
    case invalidSpeakerID(String)
    case duplicateSpeaker(String)
    case missingDefaultSpeaker(String)
    case unknownVoice(String)
    case invalidBlockID(String)
    case missingBlock(String)
    case nonNarratableBlock(String)
    case duplicateAssignment(String)
    case invalidRange(start: String, end: String)
    case crossChapterRange(start: String, end: String)
}

nonisolated enum BlockVoicePlanLoader {
    static func decode(data: Data) throws -> BlockVoicePlanDocument {
        do {
            var scanner = JSONDuplicateKeyScanner(data: data)
            try scanner.validate()
            let object = try JSONSerialization.jsonObject(with: data)
            try validateFields(object)
            return try JSONDecoder().decode(BlockVoicePlanDocument.self, from: data)
        } catch let error as BlockVoicePlanError {
            throw error
        } catch {
            throw BlockVoicePlanError.malformedJSON(String(describing: error))
        }
    }

    static func resolve(
        document: BlockVoicePlanDocument,
        sourceEPUBSHA256: String,
        chapters: [PlannedNarrationChapter]
    ) throws -> ResolvedBlockVoicePlan {
        guard document.schemaVersion == 1 else { throw BlockVoicePlanError.unsupportedSchema(document.schemaVersion) }
        guard isSHA256(document.source.epubSHA256) else {
            throw BlockVoicePlanError.invalidSourceSHA256(document.source.epubSHA256)
        }
        guard document.source.epubSHA256 == sourceEPUBSHA256 else {
            throw BlockVoicePlanError.sourceMismatch(expected: document.source.epubSHA256, actual: sourceEPUBSHA256)
        }

        guard isSpeakerID(document.defaultSpeakerID) else {
            throw BlockVoicePlanError.invalidSpeakerID(document.defaultSpeakerID)
        }
        var voiceBySpeaker: [String: VoiceID] = [:]
        for speaker in document.speakers {
            guard isSpeakerID(speaker.id) else { throw BlockVoicePlanError.invalidSpeakerID(speaker.id) }
            guard voiceBySpeaker[speaker.id] == nil else { throw BlockVoicePlanError.duplicateSpeaker(speaker.id) }
            let voiceID = VoiceID(speaker.voiceID)
            guard VoiceCatalog.voice(for: voiceID) != nil else { throw BlockVoicePlanError.unknownVoice(speaker.voiceID) }
            voiceBySpeaker[speaker.id] = voiceID
        }
        guard let defaultVoice = voiceBySpeaker[document.defaultSpeakerID] else {
            throw BlockVoicePlanError.missingDefaultSpeaker(document.defaultSpeakerID)
        }

        let ordered = chapters.flatMap { chapter in
            chapter.blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }.map { (chapter, $0) }
        }.filter { isSpeakable($0.1) }
        let blockByID = Dictionary(uniqueKeysWithValues: ordered.map {
            (AlignmentSidecar.portableSuffix(of: $0.1.id), $0)
        })
        let allBlocksByID = Dictionary(uniqueKeysWithValues: chapters.flatMap { chapter in
            chapter.blocks.map { (AlignmentSidecar.portableSuffix(of: $0.id), $0) }
        })
        var assignments: [String: (speaker: String, voice: VoiceID)] = [:]

        for assignment in document.assignments {
            guard let voice = voiceBySpeaker[assignment.speakerID] else {
                throw BlockVoicePlanError.missingDefaultSpeaker(assignment.speakerID)
            }
            let assignedIDs: [String]
            switch (assignment.blocks, assignment.range) {
            case let (.some(blocks), .none):
                guard !blocks.isEmpty else { throw BlockVoicePlanError.invalidBlockID("") }
                assignedIDs = blocks
            case let (.none, .some(range)):
                assignedIDs = try expand(
                    range: range,
                    ordered: ordered,
                    blockByID: blockByID,
                    allBlocksByID: allBlocksByID)
            default:
                throw BlockVoicePlanError.malformedJSON("assignment")
            }
            for blockID in assignedIDs {
                try validateAssignmentBlock(
                    blockID,
                    blockByID: blockByID,
                    allBlocksByID: allBlocksByID)
                guard assignments[blockID] == nil else { throw BlockVoicePlanError.duplicateAssignment(blockID) }
                assignments[blockID] = (assignment.speakerID, voice)
            }
        }

        let resolved = ordered.map { _, block -> ResolvedBlockVoice in
            let blockID = AlignmentSidecar.portableSuffix(of: block.id)
            let assignment = assignments[blockID]
            return ResolvedBlockVoice(
                blockID: blockID,
                speakerID: assignment?.speaker ?? document.defaultSpeakerID,
                voiceID: assignment?.voice ?? defaultVoice)
        }
        return ResolvedBlockVoicePlan(
            sourceEPUBSHA256: sourceEPUBSHA256,
            defaultSpeakerID: document.defaultSpeakerID,
            defaultVoiceID: defaultVoice,
            blocks: resolved)
    }

    private static func expand(
        range: BlockVoicePlanDocument.Assignment.Range,
        ordered: [(PlannedNarrationChapter, EPubBlockRecord)],
        blockByID: [String: (PlannedNarrationChapter, EPubBlockRecord)],
        allBlocksByID: [String: EPubBlockRecord]
    ) throws -> [String] {
        try validateAssignmentBlock(
            range.start, blockByID: blockByID, allBlocksByID: allBlocksByID)
        try validateAssignmentBlock(
            range.end, blockByID: blockByID, allBlocksByID: allBlocksByID)
        let start = try index(of: range.start, in: ordered)
        let end = try index(of: range.end, in: ordered)
        guard start <= end else { throw BlockVoicePlanError.invalidRange(start: range.start, end: range.end) }
        guard ordered[start].0.index == ordered[end].0.index else {
            throw BlockVoicePlanError.crossChapterRange(start: range.start, end: range.end)
        }
        return ordered[start...end].map { AlignmentSidecar.portableSuffix(of: $0.1.id) }
    }

    private static func index(
        of blockID: String, in ordered: [(PlannedNarrationChapter, EPubBlockRecord)]
    ) throws -> Int {
        guard let index = ordered.firstIndex(where: {
            AlignmentSidecar.portableSuffix(of: $0.1.id) == blockID
        }) else { throw BlockVoicePlanError.missingBlock(blockID) }
        return index
    }

    private static func validateAssignmentBlock(
        _ blockID: String,
        blockByID: [String: (PlannedNarrationChapter, EPubBlockRecord)],
        allBlocksByID: [String: EPubBlockRecord]
    ) throws {
        guard isBlockID(blockID) else { throw BlockVoicePlanError.invalidBlockID(blockID) }
        guard allBlocksByID[blockID] != nil else { throw BlockVoicePlanError.missingBlock(blockID) }
        guard blockByID[blockID] != nil else { throw BlockVoicePlanError.nonNarratableBlock(blockID) }
    }

    private static func isSpeakable(_ block: EPubBlockRecord) -> Bool {
        guard block.isHidden == false else { return false }
        return NarratedBlockText.text(for: block)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isSpeakerID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    private static func isBlockID(_ value: String) -> Bool {
        value.range(of: "^s[0-9]+-b[0-9]+$", options: .regularExpression) != nil
    }

    private static func validateFields(_ object: Any) throws {
        guard let root = object as? [String: Any] else { throw BlockVoicePlanError.malformedJSON("root") }
        try validateKeys(root, allowed: ["schemaVersion", "source", "defaultSpeakerID", "speakers", "assignments"])
        if let source = root["source"] as? [String: Any] {
            try validateKeys(source, allowed: ["epubSHA256"])
        }
        if let speakers = root["speakers"] as? [[String: Any]] {
            for speaker in speakers { try validateKeys(speaker, allowed: ["id", "voiceID"]) }
        }
        if let assignments = root["assignments"] as? [[String: Any]] {
            for assignment in assignments {
                try validateKeys(assignment, allowed: ["speakerID", "blocks", "range"])
                if let range = assignment["range"] as? [String: Any] {
                    try validateKeys(range, allowed: ["start", "end"])
                }
            }
        }
    }

    private static func validateKeys(_ object: [String: Any], allowed: Set<String>) throws {
        if let key = object.keys.sorted().first(where: { allowed.contains($0) == false }) {
            throw BlockVoicePlanError.unknownField(key)
        }
    }
}

private extension JSONEncoder {
    nonisolated static func compactSortedData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private nonisolated struct JSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard offset == bytes.count else { throw BlockVoicePlanError.malformedJSON("trailing data") }
    }

    private mutating func parseValue() throws {
        skipWhitespace()
        guard offset < bytes.count else { throw BlockVoicePlanError.malformedJSON("unexpected end") }
        switch bytes[offset] {
        case 123: try parseObject()
        case 91: try parseArray()
        case 34: _ = try parseString()
        case 45, 48...57: try parseNumber()
        case 116: try parseLiteral("true")
        case 102: try parseLiteral("false")
        case 110: try parseLiteral("null")
        default: throw BlockVoicePlanError.malformedJSON("invalid token")
        }
    }

    private mutating func parseObject() throws {
        offset += 1; skipWhitespace()
        var keys = Set<String>()
        if consume(125) { return }
        while true {
            guard peek == 34 else { throw BlockVoicePlanError.malformedJSON("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw BlockVoicePlanError.duplicateJSONKey(key) }
            skipWhitespace(); guard consume(58) else { throw BlockVoicePlanError.malformedJSON("object colon") }
            try parseValue(); skipWhitespace()
            if consume(125) { return }
            guard consume(44) else { throw BlockVoicePlanError.malformedJSON("object separator") }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        offset += 1; skipWhitespace()
        if consume(93) { return }
        while true {
            try parseValue(); skipWhitespace()
            if consume(93) { return }
            guard consume(44) else { throw BlockVoicePlanError.malformedJSON("array separator") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(34) else { throw BlockVoicePlanError.malformedJSON("string") }
        let start = offset - 1
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if escaped {
                if byte == 117 { guard offset + 4 <= bytes.count else { throw BlockVoicePlanError.malformedJSON("unicode escape") }; offset += 4 }
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                let data = Data(bytes[start..<offset])
                guard let string = try? JSONDecoder().decode(String.self, from: data) else {
                    throw BlockVoicePlanError.malformedJSON("string")
                }
                return string
            } else if byte < 32 {
                throw BlockVoicePlanError.malformedJSON("control character")
            }
        }
        throw BlockVoicePlanError.malformedJSON("unterminated string")
    }

    private mutating func parseNumber() throws {
        let start = offset
        while offset < bytes.count, "-+0123456789.eE".utf8.contains(bytes[offset]) { offset += 1 }
        guard String(bytes: bytes[start..<offset], encoding: .utf8).flatMap(Double.init) != nil else {
            throw BlockVoicePlanError.malformedJSON("number")
        }
    }

    private mutating func parseLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard bytes[offset...].starts(with: literalBytes) else { throw BlockVoicePlanError.malformedJSON("literal") }
        offset += literalBytes.count
    }

    private var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        offset += 1; return true
    }
    private mutating func skipWhitespace() {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { offset += 1 }
    }
}
