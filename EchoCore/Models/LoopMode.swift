/// Playback loop behavior for the current audiobook.
enum LoopMode: String, Codable {
    /// No looping; playback advances normally.
    case off
    /// Loop the current chapter repeatedly.
    case chapter
    /// Loop between consecutive bookmarks.
    case bookmark
}
