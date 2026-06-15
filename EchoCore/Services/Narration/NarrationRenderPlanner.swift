import Foundation

/// Pure logic for determining which chapter to render next and whether the
/// render-ahead policy allows rendering to proceed, based on current playback state.
enum NarrationRenderPlanner {
    
    /// Policy configuration for rendering ahead.
    struct Policy: Sendable {
        /// How many chapters ahead of the current playing chapter we should render.
        var chaptersAhead: Int = 1
        
        static let `default` = Policy()
    }
    
    /// Determines the next chapter index to render, if any.
    /// - Parameters:
    ///   - currentPlayingChapter: The chapter index the user is currently listening to.
    ///   - renderedChapters: A set of chapter indices that have already been rendered.
    ///   - totalChapters: Total number of chapters in the audiobook.
    ///   - policy: The render-ahead policy.
    /// - Returns: The index of the next chapter to render, or `nil` if we are fully caught up
    ///            or have reached the end of the book.
    static func nextChapterToRender(
        currentPlayingChapter: Int,
        renderedChapters: Set<Int>,
        totalChapters: Int,
        policy: Policy = .default
    ) -> Int? {
        guard totalChapters > 0 else { return nil }
        
        let targetEndChapter = min(currentPlayingChapter + policy.chaptersAhead, totalChapters - 1)
        
        // Find the first unrendered chapter in the window [currentPlayingChapter, targetEndChapter]
        for chapter in currentPlayingChapter...targetEndChapter {
            if !renderedChapters.contains(chapter) {
                return chapter
            }
        }
        
        return nil
    }
}
