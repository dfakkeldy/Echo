// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct EchoWidgetArtworkView: View {
    enum Presentation {
        case circular
        case rectangular
    }

    let thumbnailData: Data?
    let presentation: Presentation

    var body: some View {
        if let thumbnailData, let image = UIImage(data: thumbnailData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            switch presentation {
            case .circular:
                Image(systemName: "music.note")
            case .rectangular:
                Image(systemName: "music.note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
        }
    }
}
