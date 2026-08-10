// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct NarrationStatusPresentation: Equatable, Sendable {
    let primaryText: String
    let secondaryText: String?
    let progress: Double?
    let systemImage: String
    let showsActivity: Bool
    let isFailure: Bool
    let accessibilityLabel: String
    let lockScreenSubtitle: String?
}

nonisolated enum NarrationStatusFormatter {
    static func presentation(
        for snapshot: NarrationStatusSnapshot,
        hasSession: Bool,
        now: Date
    ) -> NarrationStatusPresentation? {
        guard hasSession else { return nil }

        if let failure = failureDetail(for: snapshot) {
            return status(
                primary: String(localized: "Narration unavailable"), secondary: failure,
                image: "exclamationmark.triangle", isFailure: true)
        }

        if case .waitingForRender(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: false)
            return status(
                primary: chapterText(String(localized: "Waiting for"), chapter: chapter),
                secondary: render.text, progress: render.progress,
                image: "hourglass", showsActivity: true)
        }

        if let modelStatus = modelPresentation(for: snapshot.render) {
            return modelStatus
        }

        if case .cancelled = snapshot.render {
            return status(primary: String(localized: "Narration cancelled"), image: "stop.fill")
        }

        if case .complete = snapshot.render {
            switch snapshot.playback {
            case .completed:
                return status(primary: String(localized: "Playback completed"), image: "checkmark.circle")
            case .stopped:
                return status(primary: String(localized: "Narration stopped"), image: "stop.fill")
            case .playing, .paused, .loading, .resuming:
                return status(
                    primary: playbackText(for: snapshot.playback),
                    secondary: String(localized: "All chapters rendered"),
                    image: playbackImage(for: snapshot.playback),
                    showsActivity: isPlaying(snapshot.playback))
            default:
                return status(
                    primary: String(localized: "All chapters rendered"),
                    secondary: String(localized: "Ready to play"),
                    image: "checkmark.circle")
            }
        }

        if case .playing(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText(String(localized: "Playing"), chapter: chapter), secondary: render.text,
                progress: render.progress, image: "play.fill", showsActivity: true)
        }

        if case .paused(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText(String(localized: "Paused"), chapter: chapter), secondary: render.text,
                progress: render.progress, image: "pause.fill")
        }

        if case .rendering(let unit) = snapshot.render {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            let voice = VoiceCatalog.voice(for: unit.voiceID)?.displayName ?? unit.voiceID.rawValue
            return status(
                primary: String(localized: "Rendering chapter \(unit.chapterDisplayNumber) with \(voice)"),
                secondary: render.text, progress: render.progress,
                image: "waveform", showsActivity: true)
        }

        switch snapshot.playback {
        case .completed:
            return status(primary: String(localized: "Playback completed"), image: "checkmark.circle")
        case .stopped:
            return status(primary: String(localized: "Narration stopped"), image: "stop.fill")
        case .loading(let chapter), .resuming(let chapter):
            return status(
                primary: chapterText(String(localized: "Loading"), chapter: chapter), image: "arrow.clockwise",
                showsActivity: true)
        case .notStarted:
            return status(primary: String(localized: "Narration ready"), image: "waveform")
        case .playing, .paused, .waitingForRender, .failed:
            return nil
        }
    }

    static func megabyteText(receivedBytes: Int64, totalBytes: Int64) -> String {
        String(localized: "\(decimalMegabytes(receivedBytes)) of \(decimalMegabytes(totalBytes)) MB")
    }

    private static func failureDetail(for snapshot: NarrationStatusSnapshot) -> String? {
        switch snapshot.render {
        case .failed(let message), .blocked(let message): return message
        case .noNarratableText: return String(localized: "No narratable text was found")
        default: break
        }
        if case .failed(let message) = snapshot.playback { return message }
        return nil
    }

    private static func modelPresentation(
        for render: NarrationRenderActivity
    ) -> NarrationStatusPresentation? {
        switch render {
        case .checkingModel(let expectedBytes):
            return status(
                primary: String(localized: "Checking narration model"),
                secondary: String(localized: "\(decimalMegabytes(expectedBytes)) MB expected"),
                image: "magnifyingglass", showsActivity: true)
        case .downloadingModel(let receivedBytes, let totalBytes):
            let progress = fraction(receivedBytes, totalBytes)
            return status(
                primary: String(localized: "Downloading narration model"),
                secondary: String(localized: "\(megabyteText(receivedBytes: receivedBytes, totalBytes: totalBytes)) · \(percent(progress))%"),
                progress: progress, image: "arrow.down.circle", showsActivity: true)
        case .validatingModel(let byteCount):
            return status(
                primary: String(localized: "Validating narration model"),
                secondary: String(localized: "\(decimalMegabytes(byteCount)) MB"),
                image: "checkmark.shield", showsActivity: true)
        case .loadingModel:
            return status(
                primary: String(localized: "Loading narration model"), image: "arrow.clockwise",
                showsActivity: true)
        case .modelReady:
            return status(primary: String(localized: "Narration model ready"), image: "checkmark.circle")
        default:
            return nil
        }
    }

    private static func renderDetail(
        for render: NarrationRenderActivity,
        buffer: NarrationBufferStatus,
        now: Date,
        includeChapter: Bool
    ) -> (text: String?, progress: Double?) {
        guard case .rendering(let unit) = render else { return (nil, nil) }
        let progress = unit.fraction
        let secondsWithoutProgress = max(0, Int(now.timeIntervalSince(unit.lastProgressAt)))
        if secondsWithoutProgress >= 30 {
            return (
                String(localized: "Still synthesizing block \(max(1, unit.completedBlocks + 1)) · no update for \(secondsWithoutProgress)s"),
                progress)
        }
        let text: String
        if includeChapter, buffer.readyAhead > 0 {
            text = String(localized: "Rendering chapter \(unit.chapterDisplayNumber) · \(percent(progress))% · \(buffer.readyAhead) ready ahead")
        } else if includeChapter {
            text = String(localized: "Rendering chapter \(unit.chapterDisplayNumber) · \(percent(progress))%")
        } else if buffer.readyAhead > 0 {
            text = String(localized: "Rendering \(percent(progress))% · \(buffer.readyAhead) ready ahead")
        } else {
            text = String(localized: "Rendering \(percent(progress))%")
        }
        return (text, progress)
    }

    private static func status(
        primary: String,
        secondary: String? = nil,
        progress: Double? = nil,
        image: String,
        showsActivity: Bool = false,
        isFailure: Bool = false
    ) -> NarrationStatusPresentation {
        NarrationStatusPresentation(
            primaryText: primary, secondaryText: secondary, progress: progress,
            systemImage: image, showsActivity: showsActivity, isFailure: isFailure,
            accessibilityLabel: accessibilityLabel(primary: primary, secondary: secondary),
            lockScreenSubtitle: secondary)
    }

    private static func fraction(_ numerator: Int64, _ denominator: Int64) -> Double {
        guard denominator > 0 else { return 0 }
        return min(1, max(0, Double(numerator) / Double(denominator)))
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    private static func decimalMegabytes(_ bytes: Int64) -> Int {
        max(0, Int((Double(bytes) / 1_000_000).rounded()))
    }

    private static func chapterText(_ verb: String, chapter: Int?) -> String {
        guard let chapter else { return verb }
        return String(localized: "\(verb) chapter \(chapter)")
    }

    private static func playbackText(for playback: NarrationPlaybackActivity) -> String {
        switch playback {
        case .playing(let chapter): return chapterText(String(localized: "Playing"), chapter: chapter)
        case .paused(let chapter): return chapterText(String(localized: "Paused"), chapter: chapter)
        case .loading(let chapter), .resuming(let chapter): return chapterText(String(localized: "Loading"), chapter: chapter)
        default: return String(localized: "Narration ready")
        }
    }

    private static func isPlaying(_ playback: NarrationPlaybackActivity) -> Bool {
        if case .playing = playback { return true }
        return false
    }

    private static func playbackImage(for playback: NarrationPlaybackActivity) -> String {
        if case .paused = playback { return "pause.fill" }
        return "play.fill"
    }

    private static func accessibilityLabel(primary: String, secondary: String?) -> String {
        guard let secondary else { return primary }
        return String(localized: "\(primary). \(secondary)")
    }
}
