import SwiftUI

struct TimelineTab: View {
    @Environment(PlayerModel.self) private var model

    var onReviewTap: (() -> Void)?
    var onEditBookmark: ((UUID) -> Void)?
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        PlaylistView(isEmbedded: true)
    }
}
