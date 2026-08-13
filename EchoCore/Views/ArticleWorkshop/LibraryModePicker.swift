// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct LibraryModePicker: View {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Binding var selection: LibraryMode

        @ViewBuilder
        var body: some View {
            switch LibraryModePickerPolicy.presentation(
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
            {
            case .segmented:
                Picker("Library section", selection: $selection) {
                    modeOptions
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityLabel("Library section")
                .accessibilityValue(selection.title)
                .accessibilityHint("Choose Books, Inbox, or Anthologies")
            case .menu:
                LabeledContent("Library section") {
                    Picker(selection: $selection) {
                        modeOptions
                    } label: {
                        Label(selection.title, systemImage: selection.systemImage)
                    }
                    .pickerStyle(.menu)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Library section")
                .accessibilityValue(selection.title)
                .accessibilityHint("Choose Books, Inbox, or Anthologies")
            }
        }

        @ViewBuilder
        private var modeOptions: some View {
            ForEach(LibraryModePickerPolicy.availableModes) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
    }
#endif
