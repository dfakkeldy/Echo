// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Testing

@testable import Echo

// These tests prove the width policy only. They do not prove that replacing
// the native inspector removes the AppKit constraint-pass abort; that still
// needs the gated runtime resize check with Notes visible.
//
// The exact shared policy also runs in a standalone headless test package;
// only the module import differs there. No AppKit windows are created.

@MainActor
@Suite("MacNotesPaneWidthPolicy")
struct MacNotesPaneWidthPolicyTests {
    let policy = MacNotesPaneWidthPolicy.standard

    @Test func keepsTheExistingBounds() {
        #expect(policy.readerMinimum == 320)
        #expect(policy.notesMinimum == 220)
        #expect(policy.notesIdeal == 320)
        #expect(policy.notesMaximum == 520)
    }

    @Test func showsIdealWidthWhenThereIsRoom() {
        let notes = policy.notesWidth(preferred: policy.notesIdeal, available: 900, isShown: true)
        #expect(notes == 320)
        #expect(policy.readerWidth(notesWidth: notes, available: 900) == 571)
    }

    @Test func clampsPreferredWidthToMinimumAndMaximum() {
        #expect(policy.notesWidth(preferred: 100, available: 2000, isShown: true) == 220)
        #expect(policy.notesWidth(preferred: 900, available: 2000, isShown: true) == 520)
    }

    @Test(arguments: [1169, 900, 700, 612, 549] as [CGFloat])
    func resizingKeepsTheReaderMinimumAndFillsTheWidth(available: CGFloat) {
        let notes = policy.notesWidth(preferred: 480, available: available, isShown: true)
        let reader = policy.readerWidth(notesWidth: notes, available: available)
        #expect(notes >= policy.notesMinimum)
        #expect(reader >= policy.readerMinimum)
        #expect(notes + policy.dividerWidth + reader == available)
    }

    @Test func notesYieldsWhenBothMinimumsCannotFit() {
        // The normal host advertises this stable minimum; transient smaller
        // proposals yield instead of creating incompatible width demands.
        let minimum = policy.minimumContainerWidth(isNotesShown: true)
        #expect(policy.notesWidth(preferred: 320, available: minimum, isShown: true) == 220)
        #expect(policy.notesWidth(preferred: 320, available: minimum - 1, isShown: true) == 0)
        #expect(policy.readerWidth(notesWidth: 0, available: minimum - 1) == minimum - 1)
    }

    @Test func narrowingThenWideningRestoresThePreferredWidth() {
        #expect(policy.notesWidth(preferred: 480, available: 700, isShown: true) == 371)
        #expect(policy.notesWidth(preferred: 480, available: 400, isShown: true) == 0)
        #expect(policy.notesWidth(preferred: 480, available: 1200, isShown: true) == 480)
    }

    @Test func hiddenNotesGivesTheReaderAllTheWidth() {
        let notes = policy.notesWidth(preferred: 400, available: 900, isShown: false)
        #expect(notes == 0)
        #expect(policy.readerWidth(notesWidth: notes, available: 900) == 900)
        // The preferred width is untouched by hiding, so showing again restores it.
        #expect(policy.notesWidth(preferred: 400, available: 900, isShown: true) == 400)
    }

    @Test(arguments: [.nan, .infinity, -.infinity, -50, 0] as [CGFloat])
    func invalidAvailableWidthFailsClosed(available: CGFloat) {
        let notes = policy.notesWidth(preferred: 320, available: available, isShown: true)
        let reader = policy.readerWidth(notesWidth: notes, available: available)
        #expect(notes == 0)
        #expect(reader == 0)
        #expect(policy.notesUpperBound(available: available) == nil)
    }

    @Test func nonfinitePreferredWidthFallsBackToIdeal() {
        #expect(policy.clampedPreferred(.nan) == 320)
        #expect(policy.clampedPreferred(.infinity) == 320)
        #expect(policy.notesWidth(preferred: .nan, available: 900, isShown: true) == 320)
    }

    @Test func draggingLeftWidensAndRightNarrowsWithinBounds() {
        #expect(policy.dragged(startWidth: 320, translation: -100, available: 1200) == 420)
        #expect(policy.dragged(startWidth: 320, translation: 50, available: 1200) == 270)
        #expect(policy.dragged(startWidth: 320, translation: 500, available: 1200) == 220)
        #expect(policy.dragged(startWidth: 320, translation: -1000, available: 1200) == 520)
        // Capped so the reader keeps its minimum: 700 - 320 - 9 = 371.
        #expect(policy.dragged(startWidth: 320, translation: -1000, available: 700) == 371)
    }

    @Test func dragEventsDoNotAccumulate() {
        // A drag reports total translation from its start on every event.
        var width: CGFloat = 0
        for translation in [-10, -20, -30] as [CGFloat] {
            width = policy.dragged(startWidth: 320, translation: translation, available: 1200)
        }
        #expect(width == 350)
    }

    @Test func invalidDragInputLeavesTheWidthUsable() {
        #expect(policy.dragged(startWidth: 320, translation: .nan, available: 1200) == 320)
        #expect(policy.dragged(startWidth: .nan, translation: -10, available: 1200) == 330)
        // No room for Notes: the preferred width is kept, not driven out of range.
        #expect(policy.dragged(startWidth: 400, translation: -100, available: 500) == 400)
    }

    @Test func shownHostReservesBothUsableMinimaAndHiddenHostOnlyReader() {
        let shown = policy.minimumContainerWidth(isNotesShown: true)
        let hidden = policy.minimumContainerWidth(isNotesShown: false)
        #expect(shown == 549)
        #expect(hidden == 320)
        let notes = policy.notesWidth(preferred: 320, available: shown, isShown: true)
        #expect(notes == 220)
        #expect(policy.readerWidth(notesWidth: notes, available: shown) == 320)
        #expect(policy.readerWidth(notesWidth: 0, available: hidden) == 320)
    }

    @Test func rightToLeftPhysicalDragsMirrorWithoutReversingAccessibilityWidth() {
        #expect(policy.dragged(startWidth: 320, translation: 100, available: 1200,
                              notesOnLeadingEdge: true) == 420)
        #expect(policy.dragged(startWidth: 320, translation: -50, available: 1200,
                              notesOnLeadingEdge: true) == 270)
        #expect(policy.dragged(startWidth: 320, translation: 1000, available: 700,
                              notesOnLeadingEdge: true) == 371)
        // Accessibility uses a logical width step; physical layout does not enter it.
        #expect(policy.dragged(startWidth: 320, translation: -20, available: 1200) == 340)
        #expect(policy.dragged(startWidth: 320, translation: 20, available: 1200) == 300)
    }

    @Test func capacityAndBoundsRemainLegalAcrossPreferenceAndGeometryChanges() {
        for available in [549, 550, 600, 900, 1200, 2000] as [CGFloat] {
            for preferred in [-100, 0, 220, 320, 520, 900, .nan] as [CGFloat] {
                let notes = policy.notesWidth(preferred: preferred, available: available, isShown: true)
                let reader = policy.readerWidth(notesWidth: notes, available: available)
                #expect(notes.isFinite && reader.isFinite)
                #expect(notes >= 220 && notes <= 520)
                #expect(reader >= 320)
                #expect(abs(reader + notes + policy.dividerWidth - available) < 0.000001)
            }
        }
    }
}
