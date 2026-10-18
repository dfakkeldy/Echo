// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Strict parser for repeatable `echo-cli narrate --chapter-voice N=voice_id`
/// overrides. `N` is the 1-based chapter number shown to the listener.
nonisolated struct ChapterVoiceAssignments: Equatable, Sendable {
    enum AssignmentError: LocalizedError, Equatable {
        case malformed(String)
        case invalidChapterNumber(String)
        case duplicateChapter(Int)
        case unknownVoice(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let value):
                return "Invalid chapter voice '\(value)'; expected N=voice_id."
            case .invalidChapterNumber(let value):
                return "Invalid chapter number '\(value)'; expected a positive integer."
            case .duplicateChapter(let chapter):
                return "Chapter \(chapter) has more than one voice assignment."
            case .unknownVoice(let voice):
                return "Unknown English narration voice '\(voice)'."
            }
        }
    }

    let byDisplayNumber: [Int: VoiceID]

    init(arguments: [String]) throws {
        var assignments: [Int: VoiceID] = [:]
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else {
                throw AssignmentError.malformed(argument)
            }
            let chapterText = String(parts[0])
            guard let chapter = Int(chapterText), chapter > 0 else {
                throw AssignmentError.invalidChapterNumber(chapterText)
            }
            let voiceText = String(parts[1])
            guard VoiceCatalog.voice(for: VoiceID(voiceText)) != nil else {
                throw AssignmentError.unknownVoice(voiceText)
            }
            guard assignments[chapter] == nil else {
                throw AssignmentError.duplicateChapter(chapter)
            }
            assignments[chapter] = VoiceID(voiceText)
        }
        byDisplayNumber = assignments
    }
}
