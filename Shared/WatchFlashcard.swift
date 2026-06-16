// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Lightweight flashcard model synced to the watch for hands-free review.
/// Only contains display text — SM-2 grading is handled on iPhone after the
/// watch sends the grade back.
struct WatchFlashcard: Codable, Identifiable {
    let id: String
    let frontText: String
    let backText: String
}
