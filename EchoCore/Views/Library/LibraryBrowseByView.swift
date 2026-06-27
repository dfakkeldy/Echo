// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryBrowseByView: View {
    let selectedAxis: LibraryAxis
    let onSelect: (LibraryAxis) -> Void

    var body: some View {
        Menu {
            ForEach(LibraryAxis.allCases, id: \.self) { axis in
                Button(axis.label, systemImage: axis.systemImage) {
                    onSelect(axis)
                }
            }
        } label: {
            Label(selectedAxis.label, systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(Text("Browse by \(selectedAxis.label)"))
    }
}

private extension LibraryAxis {
    var label: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .author: "Author"
        case .topic: "Topic"
        case .folder: "Folder"
        case .studyStatus: "Study Status"
        case .processingStatus: "Processing Status"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .author: "person"
        case .topic: "tag"
        case .folder: "folder"
        case .studyStatus: "checkmark.circle"
        case .processingStatus: "wand.and.sparkles"
        }
    }
}
