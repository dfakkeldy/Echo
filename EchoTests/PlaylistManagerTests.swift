import Foundation
import Testing

@testable import Echo

@Suite struct PlaylistManagerTests {

    @Test func recognizesAudioExtensions() {
        #expect(PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/song.mp3")))
        #expect(PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/audiobook.m4b")))
        // Case-insensitive — file providers vary the casing.
        #expect(PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/track.M4A")))
    }

    @Test func rejectsDocumentsAndOtherFilesAsAudio() {
        // A document picked at import must NOT become a playable audio track —
        // otherwise the player would try to "play" an EPUB/PDF.
        #expect(!PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/alice.epub")))
        #expect(!PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/notes.pdf")))
        #expect(!PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/readme.txt")))
        #expect(!PlaylistManager.isAudioFile(URL(fileURLWithPath: "/books/folder")))
    }

    @Test func recognizesStudyDocuments() {
        #expect(PlaylistManager.isDocumentFile(URL(fileURLWithPath: "/books/alice.EPUB")))
        #expect(PlaylistManager.isDocumentFile(URL(fileURLWithPath: "/books/notes.pdf")))
    }

    @Test func nonDefaultAudioIsNotADocument() {
        // Regression guard: lone non-default audio files must still open as
        // playable tracks (not be diverted to the audio-less document path).
        for ext in ["wav", "aiff", "aac", "caf", "flac", "mp3"] {
            #expect(!PlaylistManager.isDocumentFile(URL(fileURLWithPath: "/books/x.\(ext)")))
        }
    }
}
