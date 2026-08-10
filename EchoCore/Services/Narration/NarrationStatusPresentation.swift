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

        if let modelStatus = modelPresentation(for: snapshot.render, now: now) {
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
                    showsActivity: showsPlaybackActivity(snapshot.playback))
            default:
                return status(
                    primary: String(localized: "All chapters rendered"),
                    secondary: String(localized: "Ready to play"),
                    image: "checkmark.circle")
            }
        }

        if case .loading(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText(String(localized: "Loading"), chapter: chapter),
                secondary: render.text, progress: render.progress,
                image: "arrow.clockwise", showsActivity: true)
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

        if case .resuming(let chapter) = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: chapterText(String(localized: "Resuming"), chapter: chapter),
                secondary: render.text, progress: render.progress,
                image: "arrow.clockwise", showsActivity: true)
        }

        if case .stopped = snapshot.playback {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: String(localized: "Narration stopped"),
                secondary: render.text, progress: render.progress,
                image: "stop.fill")
        }

        if case .planning = snapshot.render {
            return status(
                primary: String(localized: "Planning narration"),
                image: "list.bullet.clipboard", showsActivity: true)
        }

        if case .heldByBackpressure = snapshot.render {
            let render = renderDetail(
                for: snapshot.render, buffer: snapshot.buffer, now: now, includeChapter: true)
            return status(
                primary: String(localized: "Rendering paused while playback catches up"),
                secondary: render.text, progress: render.progress,
                image: "pause.circle")
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
        case .loading(let chapter):
            return status(
                primary: chapterText(String(localized: "Loading"), chapter: chapter), image: "arrow.clockwise",
                showsActivity: true)
        case .notStarted:
            return status(primary: String(localized: "Narration ready"), image: "waveform")
        case .playing, .paused, .waitingForRender, .resuming, .stopped, .failed:
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
        for render: NarrationRenderActivity,
        now: Date
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
        case .loadingModel(let startedAt):
            let elapsed = max(0, now.timeIntervalSince(startedAt)).formatted(
                .number.precision(.fractionLength(1)))
            return status(
                primary: String(localized: "Loading narration model"),
                secondary: String(localized: "\(elapsed)s elapsed"),
                image: "arrow.clockwise",
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
        let unit: NarrationRenderUnitStatus
        switch render {
        case .rendering(let current):
            unit = current
        case .heldByBackpressure(let current?):
            unit = current
        default:
            return (nil, nil)
        }
        let progress = unit.fraction
        let secondsWithoutProgress = max(0, Int(now.timeIntervalSince(unit.lastProgressAt)))
        if secondsWithoutProgress >= 30 {
            return (
                String(localized: "Still synthesizing block \(max(1, unit.completedBlocks + 1)) · no update for \(secondsWithoutProgress)s"),
                progress)
        }
        let location: String
        if includeChapter, let segmentIndex = unit.segmentIndex {
            location = String(
                localized:
                    "Rendering chapter \(unit.chapterDisplayNumber), segment \(segmentIndex + 1)")
        } else if includeChapter {
            location = String(localized: "Rendering chapter \(unit.chapterDisplayNumber)")
        } else if let segmentIndex = unit.segmentIndex {
            location = String(localized: "Rendering segment \(segmentIndex + 1)")
        } else {
            location = String(localized: "Rendering")
        }
        let block = String(
            localized: "block \(unit.completedBlocks) of \(unit.totalBlocks)")
        let voice = VoiceCatalog.voice(for: unit.voiceID)?.displayName ?? unit.voiceID.rawValue
        var text = String(
            localized: "\(location) · \(block) · \(voice) · \(percent(progress))%")
        if buffer.readyAhead > 0 {
            text = String(localized: "\(text) · \(buffer.readyAhead) ready ahead")
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
            lockScreenSubtitle: accessibilityLabel(primary: primary, secondary: secondary))
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
        case .loading(let chapter): return chapterText(String(localized: "Loading"), chapter: chapter)
        case .resuming(let chapter): return chapterText(String(localized: "Resuming"), chapter: chapter)
        default: return String(localized: "Narration ready")
        }
    }

    private static func showsPlaybackActivity(_ playback: NarrationPlaybackActivity) -> Bool {
        switch playback {
        case .playing, .loading, .resuming: return true
        default: return false
        }
    }

    private static func playbackImage(for playback: NarrationPlaybackActivity) -> String {
        switch playback {
        case .paused: return "pause.fill"
        case .loading, .resuming: return "arrow.clockwise"
        default: return "play.fill"
        }
    }

    private static func accessibilityLabel(primary: String, secondary: String?) -> String {
        guard let secondary else { return primary }
        return String(localized: "\(primary). \(secondary)")
    }
}
