// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct LibraryModePicker: View {
        @Binding var selection: LibraryMode

        var body: some View {
            Picker("Library section", selection: $selection) {
                ForEach(LibraryMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityHint("Choose Books, Inbox, or Anthologies")
        }
    }
#endif
