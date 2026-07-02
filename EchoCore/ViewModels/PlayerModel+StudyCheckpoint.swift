// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension PlayerModel {
    func configureStudyCheckpoint() {
        guard let db = databaseService else {
            checkpointCoordinator = nil
            playbackController.coordinator_handleChapterEndCheckpoint = nil
            return
        }

        let coordinator = StudyCheckpointCoordinator(
            database: db,
            settingsProvider: { [weak self] in
                self?.currentCheckpointSettings()
                    ?? StudyCheckpointSettings(
                        timeoutSeconds: SettingsManager.Defaults.checkpointTimeoutSeconds,
                        timeoutBehavior: .replay,
                        autoAdvance: SettingsManager.Defaults.checkpointAutoAdvance,
                        remoteGrading: SettingsManager.Defaults.checkpointRemoteGrading
                    )
            },
            replayChapter: { [weak self] in
                guard let self, let idx = self.currentChapterIndex else { return }
                self.playbackController.seekToChapter(at: idx)
                self.play()
            },
            advance: { [weak self] item in
                self?.playCheckpointItem(item)
            },
            announce: { [weak self] cue in
                self?.checkpointAnnouncer.announce(cue)
            }
        )
        coordinator.pausePlayback = { [weak self] in self?.pause() }
        coordinator.isSleepStopRequested = { [weak self] in
            if case .endOfChapter = self?.sleepTimerMode { return true }
            return false
        }
        coordinator.fireSleepStop = { [weak self] in
            self?.sleepTimerManager.evaluateAtChapterEnd()
        }
        coordinator.isPlayable = { item in
            guard let url = URL(string: item.audiobookID), url.isFileURL else { return true }
            return (try? url.checkResourceIsReachable()) ?? false
        }
        checkpointCoordinator = coordinator

        playbackController.coordinator_handleChapterEndCheckpoint = { [weak self] chapterIndex in
            guard let self, let bookID = self.folderURL?.absoluteString else { return false }
            return self.checkpointCoordinator?.handleChapterEnd(
                audiobookID: bookID,
                chapterIndex: chapterIndex,
                naturalEnd: true
            ) ?? false
        }
    }

    private func currentCheckpointSettings() -> StudyCheckpointSettings? {
        guard let settings = settingsManager else { return nil }
        return StudyCheckpointSettings(
            timeoutSeconds: settings.checkpointTimeoutSeconds,
            timeoutBehavior: CheckpointTimeoutBehavior(rawValue: settings.checkpointTimeoutBehavior)
                ?? .replay,
            autoAdvance: settings.checkpointAutoAdvance,
            remoteGrading: settings.checkpointRemoteGrading,
            globalNewChapterLimit: settings.studyGlobalNewChapterLimit
        )
    }

    func playCheckpointItem(_ item: StudyPlayableItem) {
        let bookURL = URL(string: item.audiobookID) ?? URL(fileURLWithPath: item.audiobookID)
        if folderURL?.absoluteString != item.audiobookID {
            loadFolder(bookURL, autoplay: false)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.seek(toSeconds: max(0, item.startTime + 0.05))
            self.play()
        }
    }

    func playStudyAssignment(_ card: Flashcard) {
        selectedTab = .nowPlaying
        playCheckpointItem(
            StudyPlayableItem(
                flashcardID: card.id,
                audiobookID: card.audiobookID,
                chapterIndex: nil,
                planItemID: nil,
                title: card.frontText,
                startTime: card.mediaTimestamp,
                endTime: card.endTimestamp
            ))
    }

    func consumeRemoteSkipAsCheckpointGrade(
        _ action: StudyCheckpointCoordinator.CheckpointAction
    ) -> Bool {
        guard let coordinator = checkpointCoordinator,
            case .checkpointActive = coordinator.state,
            settingsManager?.checkpointRemoteGrading
                ?? SettingsManager.Defaults.checkpointRemoteGrading
        else {
            return false
        }

        coordinator.resolve(action)
        return true
    }
}
