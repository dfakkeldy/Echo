// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Reader | Notes, side by side, sized from the width SwiftUI actually offers.
///
/// This replaces the native `.inspector` at this one boundary, so no AppKit
/// split view sits between the reader and Notes. The container's only width
/// demand on its column is the stable visible/hidden minimum the caller applies.
/// Notes takes a measured share of the offered width. Invalid transient geometry
/// yields without demanding an impossible width; normal shown layout reserves
/// both usable pane minima.
struct MacReaderNotesSplit<Reader: View, Notes: View>: View {
    private let isNotesShown: Bool
    private let reader: Reader
    private let notes: Notes
    private let policy = MacNotesPaneWidthPolicy.standard

    /// Survives hiding and showing Notes because this view stays in the hierarchy.
    @State private var preferredNotesWidth = MacNotesPaneWidthPolicy.standard.notesIdeal
    /// The Notes width when the current drag began; translation is applied to this.
    @GestureState private var dragStartWidth: CGFloat?
    @Environment(\.layoutDirection) private var layoutDirection

    init(
        isNotesShown: Bool,
        @ViewBuilder reader: () -> Reader,
        @ViewBuilder notes: () -> Notes
    ) {
        self.isNotesShown = isNotesShown
        self.reader = reader()
        self.notes = notes()
    }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            let notesWidth = policy.notesWidth(
                preferred: preferredNotesWidth, available: available, isShown: isNotesShown)

            HStack(spacing: 0) {
                reader
                    .frame(width: policy.readerWidth(notesWidth: notesWidth, available: available))

                if notesWidth > 0 {
                    divider(notesWidth: notesWidth, available: available)
                    notes
                        .frame(width: notesWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func divider(notesWidth: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            // A real layout/hit region, rather than an overflowing child overlay.
            .frame(width: policy.dividerWidth)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // Global translation avoids feedback as the divider itself moves.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragStartWidth) { _, start, _ in
                        if start == nil { start = notesWidth }
                    }
                    .onChanged { value in
                        preferredNotesWidth = policy.dragged(
                            startWidth: dragStartWidth ?? notesWidth,
                            translation: value.translation.width,
                            available: available,
                            notesOnLeadingEdge: layoutDirection == .rightToLeft)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Notes Pane Width"))
            .accessibilityValue(Text("\(Int(notesWidth.rounded())) points"))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat
                switch direction {
                case .increment: step = -20
                case .decrement: step = 20
                @unknown default: return
                }
                // Accessibility increment/decrement describe width, independent
                // of the physical side occupied by Notes in this locale.
                preferredNotesWidth = policy.dragged(
                    startWidth: notesWidth, translation: step, available: available)
            }
    }
}
