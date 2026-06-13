import Foundation

enum ChimeSound: String, CaseIterable, Identifiable {
    case cuckooClock, templeBell, singingBowl, softChime, pianoC5, harpGliss, heyWhisper
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cuckooClock: "Cuckoo Clock"
        case .templeBell: "Temple Bell"
        case .singingBowl: "Singing Bowl"
        case .softChime: "Soft Chime"
        case .pianoC5: "Piano Note"
        case .harpGliss: "Harp Gliss"
        case .heyWhisper: "Hey Whisper"
        }
    }
    var sfSymbol: String {
        switch self {
        case .cuckooClock: "clock"
        case .templeBell: "bell"
        case .singingBowl: "water.waves"
        case .softChime: "wind"
        case .pianoC5: "pianokeys"
        case .harpGliss: "harp"
        case .heyWhisper: "waveform.and.mic"
        }
    }
}
