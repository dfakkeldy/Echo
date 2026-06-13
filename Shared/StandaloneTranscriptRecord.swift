import Foundation
import GRDB

/// A transcribed segment stored when no EPUB/PDF companion is available.
///
/// Each row represents one VAD-delimited chunk of speech within a chapter.
/// Word-level timing data is optionally stored as JSON in `wordsJSON`.
struct StandaloneTranscriptRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var chapterIndex: Int
    var segmentIndex: Int
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var wordsJSON: String?
    var createdAt: String

    static let databaseTableName = "standalone_transcript"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case chapterIndex = "chapter_index"
        case segmentIndex = "segment_index"
        case text
        case startTime = "start_time"
        case endTime = "end_time"
        case wordsJSON = "words_json"
        case createdAt = "created_at"
    }
}

/// Word-level timing produced by the standalone transcription pipeline.
///
/// Differs from `AlignmentTranscript.TranscribedWord` by including end time
/// and confidence — data that is available from WhisperKit's `WordTiming`
/// but not needed by the alignment pipeline.
struct StandaloneTranscribedWord: Codable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}
