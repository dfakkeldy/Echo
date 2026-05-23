import SwiftUI

// MARK: - PlaybackControllerDelegate

extension PlayerModel: PlaybackControllerDelegate {
    func playbackController(_ controller: PlaybackController, didUpdateTime currentTime: TimeInterval) {
        autoreleasepool {
            updateNowPlayingElapsedTime()
            updateCurrentChapterFromPlayerTime()
            updateProgressFromPlayer()
            artworkCoordinator.updateCurrentDisplayArtwork(at: currentTime)
            playbackController.enforceEnabledState()
            playbackController.applyChapterLoopIfNeeded()
            playbackController.applyBookmarkLoopIfNeeded()
            if resolvedPlayBookmarksInline,
               currentTime.isFinite {
                checkVoiceMemoTrigger(at: currentTime, previousSeconds: lastBookmarkCheckSecond)
                if let card = flashcardTriggerController.checkTrigger(
                    at: currentTime,
                    previousSeconds: lastBookmarkCheckSecond,
                    hasActiveCard: activeInlineCard != nil
                ) {
                    audioEngine.pause()
                    activeInlineCard = card
                }
                lastBookmarkCheckSecond = currentTime
            }
        }
    }

    func playbackControllerDidPlayToEnd(_ controller: PlaybackController) {
        playbackController.handleTrackEnded()
    }

    func playbackControllerInterruptionBegan(_ controller: PlaybackController) {
        pause()
    }

    func playbackControllerInterruptionEnded(_ controller: PlaybackController, shouldResume: Bool) {
        if shouldResume {
            play()
        }
    }
}
