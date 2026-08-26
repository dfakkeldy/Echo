// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum ArticleWorkshopLimits {
    static let maxEnvelopeBytes = 12 * 1_024 * 1_024
    static let maxContentXHTMLBytes = 8 * 1_024 * 1_024
    static let maxDOMElements = 50_000
    static let maxBlocks = 20_000
    static let maxImages = 100
    static let maxSingleImageBytes = 12 * 1_024 * 1_024
    static let maxTotalImageBytes = 50 * 1_024 * 1_024
    static let maxRedirects = 5
    static let maxURLResponseBytes = 12 * 1_024 * 1_024
}
