// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NarrationStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Bindable var state: NarrationState
    @State private var isExpanded = false

    var body: some View {
        Group {
            if state.hasSession {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let presentation = NarrationStatusFormatter.presentation(
                        for: state.snapshot,
                        hasSession: state.hasSession,
                        now: context.date)
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            collapsedSummary(presentation)

                            DisclosureGroup(isExpanded: $isExpanded) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        ForEach(state.events.reversed()) { event in
                                            NarrationEventRow(event: event)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 220)
                            } label: {
                                Text("Details")
                                    .font(.caption.bold())
                            }
                            .accessibilityIdentifier("narration.status.details")
                            .accessibilityValue(
                                isExpanded ? Text("Expanded") : Text("Collapsed"))
                        }
                        .padding(8)
                        .background(.regularMaterial)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay {
                            if presentation.isFailure {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.red.opacity(0.5))
                            }
                        }
                    }
                }
                .transition(
                    accessibilityReduceMotion
                        ? .identity
                        : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .default,
            value: state.hasSession)
    }

    private func collapsedSummary(
        _ presentation: NarrationStatusPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if presentation.showsActivity {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(presentation.isFailure ? Color.red : Color.primary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.primaryText)
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let secondaryText = presentation.secondaryText {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let progress = presentation.progress {
                    ProgressView(value: progress)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct NarrationEventRow: View {
    let event: NarrationEvent

    private var systemImage: String {
        switch event.category {
        case .preparation: "list.bullet.clipboard"
        case .model: "arrow.down.circle"
        case .voice: "person.wave.2"
        case .render: "waveform.badge.plus"
        case .buffer: "rectangle.stack"
        case .playback: "play.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(event.message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
