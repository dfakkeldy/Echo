import Foundation

extension String {
    func levenshteinDistance(to target: String) -> Int {
        let source = Array(self)
        let targetChars = Array(target)
        let sourceCount = source.count
        let targetCount = targetChars.count

        if sourceCount == 0 { return targetCount }
        if targetCount == 0 { return sourceCount }

        var previousRow = [Int](0...targetCount)
        var currentRow = [Int](repeating: 0, count: targetCount + 1)

        for i in 1...sourceCount {
            currentRow[0] = i
            for j in 1...targetCount {
                let substitutionCost = source[i - 1] == targetChars[j - 1] ? 0 : 1
                currentRow[j] = Swift.min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + substitutionCost
                )
            }
            swap(&previousRow, &currentRow)
        }

        return previousRow[targetCount]
    }

    /// Returns a similarity score in [0.0, 1.0] where 1.0 is an exact match.
    /// Calculated as `1.0 - (levenshteinDistance / max(length))`.
    func normalizedLevenshteinSimilarity(to target: String) -> Double {
        let distance = Double(levenshteinDistance(to: target))
        let maxLength = Double(max(count, target.count))
        guard maxLength > 0 else { return 1.0 }
        return 1.0 - (distance / maxLength)
    }
}
