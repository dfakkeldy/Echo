// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationResumeTarget: Equatable {
    case sourceChapterKey(String)
    case chapterIndex(Int)
}

/// Resolves anthology resume through the source chapter's stable cache identity,
/// never through its mutable EPUB position.
nonisolated enum NarrationResumeResolver {
    static func sourceChapterKey(
        fromLastTrackURL url: URL?,
        plans: [NarrationChapterRenderPlan]
    ) -> String? {
        guard let url,
            let token = NarrationFileNaming.location(fromFileName: url.lastPathComponent)?
                .stableChapterToken
        else { return nil }

        return plans.compactMap(\.sourceChapterKey).first {
            NarrationFileNaming.stableChapterToken(for: $0) == token
        }
    }

    static func target(
        fromLastTrackURL url: URL?,
        plans: [NarrationChapterRenderPlan],
        isAnthology: Bool
    ) -> NarrationResumeTarget? {
        if isAnthology {
            return sourceChapterKey(fromLastTrackURL: url, plans: plans)
                .map(NarrationResumeTarget.sourceChapterKey)
        }
        guard let fileName = url?.lastPathComponent,
            let chapterIndex = NarrationFileNaming.chapterIndex(fromFileName: fileName)
        else { return nil }
        return .chapterIndex(chapterIndex)
    }
}
