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
                primary: "Narration unavailable", secondary: failure,
                image: "exclamationmark.triangle", isFailure: true)
        }

        if case .waitingForRender(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: false)
            return status(
                primary: chapterText("Waiting for", chapter: chapter),
                secondary: render.text, progress: render.progress,
                image: "hourglass", showsActivity: true)
        }

        if let modelStatus = modelPresentation(for: snapshot.render) {
            return modelStatus
        }

        if case .playing(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText("Playing", chapter: chapter), secondary: render.text,
                progress: render.progress, image: "play.fill", showsActivity: true)
        }

        if case .paused(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText("Paused", chapter: chapter), secondary: render.text,
                progress: render.progress, image: "pause.fill")
        }

        if case .rendering(let unit) = snapshot.render {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            let voice = VoiceCatalog.voice(for: unit.voiceID)?.displayName ?? unit.voiceID.rawValue
            return status(
                primary: "Rendering chapter \(unit.chapterDisplayNumber) with \(voice)",
                secondary: render.text, progress: render.progress,
                image: "waveform", showsActivity: true)
        }

        if case .complete = snapshot.render, isActivePlayback(snapshot.playback) {
            return status(
                primary: playbackText(for: snapshot.playback), secondary: "All chapters rendered",
                image: "play.fill", showsActivity: isPlaying(snapshot.playback))
        }

        if case .complete = snapshot.render {
            return status(
                primary: "All chapters rendered", secondary: "Ready to play",
                image: "checkmark.circle")
        }

        switch snapshot.playback {
        case .completed:
            return status(primary: "Playback completed", image: "checkmark.circle")
        case .stopped:
            return status(primary: "Narration stopped", image: "stop.fill")
        case .loading(let chapter), .resuming(let chapter):
            return status(
                primary: chapterText("Loading", chapter: chapter), image: "arrow.clockwise",
                showsActivity: true)
        case .notStarted:
            return status(primary: "Narration ready", image: "waveform")
        case .playing, .paused, .waitingForRender, .failed:
            return nil
        }
    }

    static func megabyteText(receivedBytes: Int64, totalBytes: Int64) -> String {
        "\(decimalMegabytes(receivedBytes)) of \(decimalMegabytes(totalBytes)) MB"
    }

    private static func failureDetail(for snapshot: NarrationStatusSnapshot) -> String? {
        switch snapshot.render {
        case .failed(let message), .blocked(let message): return message
        case .noNarratableText: return "No narratable text was found"
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
                primary: "Checking narration model",
                secondary: "\(decimalMegabytes(expectedBytes)) MB expected",
                image: "magnifyingglass", showsActivity: true)
        case .downloadingModel(let receivedBytes, let totalBytes):
            let progress = fraction(receivedBytes, totalBytes)
            return status(
                primary: "Downloading narration model",
                secondary: "\(megabyteText(receivedBytes: receivedBytes, totalBytes: totalBytes)) · \(percent(progress))%",
                progress: progress, image: "arrow.down.circle", showsActivity: true)
        case .validatingModel(let byteCount):
            return status(
                primary: "Validating narration model",
                secondary: "\(decimalMegabytes(byteCount)) MB",
                image: "checkmark.shield", showsActivity: true)
        case .loadingModel:
            return status(
                primary: "Loading narration model", image: "arrow.clockwise",
                showsActivity: true)
        case .modelReady:
            return status(primary: "Narration model ready", image: "checkmark.circle")
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
                "Still synthesizing block \(max(1, unit.completedBlocks + 1)) · no update for \(secondsWithoutProgress)s",
                progress)
        }
        var components = ["Rendering"]
        if includeChapter { components[0] += " chapter \(unit.chapterDisplayNumber)" }
        components.append("\(percent(progress))%")
        if buffer.readyAhead > 0 { components.append("\(buffer.readyAhead) ready ahead") }
        return (components.joined(separator: " · "), progress)
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
            accessibilityLabel: [primary, secondary].compactMap { $0 }.joined(separator: ". "),
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
        return "\(verb) chapter \(chapter)"
    }

    private static func playbackText(for playback: NarrationPlaybackActivity) -> String {
        switch playback {
        case .playing(let chapter): return chapterText("Playing", chapter: chapter)
        case .paused(let chapter): return chapterText("Paused", chapter: chapter)
        case .loading(let chapter), .resuming(let chapter): return chapterText("Loading", chapter: chapter)
        default: return "Narration ready"
        }
    }

    private static func isActivePlayback(_ playback: NarrationPlaybackActivity) -> Bool {
        switch playback {
        case .playing, .paused, .loading, .resuming: return true
        default: return false
        }
    }

    private static func isPlaying(_ playback: NarrationPlaybackActivity) -> Bool {
        if case .playing = playback { return true }
        return false
    }
}
