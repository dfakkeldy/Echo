// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Groups `StudyDeckSource`s into spine-bounded batches.
///
/// A new batch is started whenever the source's `spineIndex` differs from the
/// current batch's spine index, or the current batch has already reached
/// `maxPerBatch` items.  This mirrors EDB's `GenerationBatcher` algorithm,
/// retyped over `StudyDeckSource`.
nonisolated struct StudyDeckBatcher: Sendable {
    func batches(from sources: [StudyDeckSource], maxPerBatch: Int) -> [[StudyDeckSource]] {
        guard !sources.isEmpty else {
            return []
        }

        let safeBatchSize = max(1, maxPerBatch)
        var batches: [[StudyDeckSource]] = []
        var currentBatch: [StudyDeckSource] = []
        var currentSpineIndex: Int?

        for source in sources {
            let startsNewSpine = currentSpineIndex != nil && source.spineIndex != currentSpineIndex
            let exceedsBatchSize = currentBatch.count >= safeBatchSize
            if !currentBatch.isEmpty && (startsNewSpine || exceedsBatchSize) {
                batches.append(currentBatch)
                currentBatch = []
            }

            currentSpineIndex = source.spineIndex
            currentBatch.append(source)
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }
}
