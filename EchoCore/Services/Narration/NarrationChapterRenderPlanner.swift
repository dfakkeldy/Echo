// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One chapter's immutable narration inputs after anthology provenance and voice
/// selection have been resolved. Downstream renderers consume this plan without
/// revisiting the manifest or the voice catalog.
nonisolated struct NarrationChapterRenderPlan: Equatable, Sendable {
    let chapterIndex: Int
    let displayNumber: Int
    let sourceChapterKey: String?
    let title: String
    let blocks: [EPubBlockRecord]
    let voice: VoiceID
}

nonisolated enum NarrationChapterRenderPlanError: Error, Equatable, Sendable {
    case missingSourceChapterKey(chapterIndex: Int)
    case mixedSourceChapterKeys(chapterIndex: Int)
    case unknownSourceChapterKey(String)
    case duplicateSourceChapterKey(String)
    case duplicateStableToken(String)
    case incompleteImportedChapterSet
    case unavailableVoice(String)
}

/// Resolves a chapter plan exactly once at the boundary where a validated
/// anthology manifest becomes narration work. Ordinary EPUBs intentionally skip
/// all source-key inspection and retain their preferred voice.
nonisolated enum NarrationChapterRenderPlanner {
    static func plan(
        chapters: [NarrationChapterPlanner.PlannedChapter],
        preferredVoice: VoiceID,
        manifest: AnthologyBuildManifest?
    ) throws -> [NarrationChapterRenderPlan] {
        try plan(
            chapters: chapters,
            preferredVoice: preferredVoice,
            manifest: manifest,
            stableToken: {
                NarrationFileNaming.stableChapterToken(for: $0.uuidString)
            })
    }

    static func plan(
        chapters: [NarrationChapterPlanner.PlannedChapter],
        preferredVoice: VoiceID,
        manifest: AnthologyBuildManifest?,
        stableToken: @Sendable (UUID) -> String
    ) throws -> [NarrationChapterRenderPlan] {
        guard let manifest else {
            return chapters.map {
                NarrationChapterRenderPlan(
                    chapterIndex: $0.index,
                    displayNumber: $0.displayNumber,
                    sourceChapterKey: nil,
                    title: $0.title,
                    blocks: $0.blocks,
                    voice: preferredVoice)
            }
        }

        var manifestChaptersByKey: [String: AnthologyChapterManifest] = [:]
        for manifestChapter in manifest.chapters {
            manifestChaptersByKey[manifestChapter.entryID.uuidString] = manifestChapter
        }

        var seenSourceChapterKeys = Set<String>()
        var seenStableTokens = Set<String>()
        let plans = try chapters.map { chapter in
            let sourceChapterKeys = Set(chapter.blocks.map(\.sourceChapterKey))
            guard sourceChapterKeys.contains(nil) == false else {
                throw NarrationChapterRenderPlanError.missingSourceChapterKey(
                    chapterIndex: chapter.index)
            }
            guard sourceChapterKeys.count == 1, let sourceChapterKey = sourceChapterKeys.first! else {
                throw NarrationChapterRenderPlanError.mixedSourceChapterKeys(chapterIndex: chapter.index)
            }
            guard let manifestChapter = manifestChaptersByKey[sourceChapterKey] else {
                throw NarrationChapterRenderPlanError.unknownSourceChapterKey(sourceChapterKey)
            }
            guard seenSourceChapterKeys.insert(sourceChapterKey).inserted else {
                throw NarrationChapterRenderPlanError.duplicateSourceChapterKey(sourceChapterKey)
            }

            let token = stableToken(manifestChapter.entryID)
            guard seenStableTokens.insert(token).inserted else {
                throw NarrationChapterRenderPlanError.duplicateStableToken(token)
            }

            let voice: VoiceID
            if let rawVoiceID = manifestChapter.voiceID {
                voice = VoiceID(rawVoiceID)
                guard VoiceCatalog.voice(for: voice) != nil else {
                    throw NarrationChapterRenderPlanError.unavailableVoice(rawVoiceID)
                }
            } else {
                voice = preferredVoice
            }

            return NarrationChapterRenderPlan(
                chapterIndex: chapter.index,
                displayNumber: chapter.displayNumber,
                sourceChapterKey: sourceChapterKey,
                title: chapter.title,
                blocks: chapter.blocks,
                voice: voice)
        }
        guard seenSourceChapterKeys == Set(manifestChaptersByKey.keys) else {
            throw NarrationChapterRenderPlanError.incompleteImportedChapterSet
        }
        return plans
    }
}
