// SPDX-License-Identifier: GPL-3.0-or-later

import MapKit
import SwiftUI

/// Hosts the reader feed scoped to one reconstructed session, with an optional
/// route map header when location was recorded.
struct SessionDetailFeedView: View {
    let audiobookID: String
    let session: SessionSummary
    @Environment(DatabaseService.self) private var dbService

    @State private var viewModel: ReaderFeedViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if session.hasRoute {
                    routeMap
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                recapHeader
                    .padding(.horizontal)

                if let viewModel {
                    ForEach(viewModel.sections) { section in
                        ForEach(section.items.indices, id: \.self) { idx in
                            sessionItemView(section.items[idx])
                                .padding(.horizontal)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard viewModel == nil else { return }
            let vm = ReaderFeedViewModel(audiobookID: audiobookID, db: dbService.writer)
            vm.sessionScope = .session(start: session.startPosition, end: session.endPosition)
            vm.reload()
            viewModel = vm
        }
    }

    @ViewBuilder
    private func sessionItemView(_ item: ReaderCardItem) -> some View {
        switch item {
        case .chapterHeader(let title, _):
            Text(title)
                .font(.title3.bold())
                .padding(.top, 8)
        case .block(let record):
            Text(record.text ?? "")
                .font(.body)
        case .bookmark, .ankiCard, .note, .voiceMemo:
            // Study items are intentionally not rendered in the lightweight session
            // detail preview. Listed explicitly (not via `default`) so a future
            // ReaderCardItem case triggers a compile error here instead of vanishing.
            EmptyView()
        }
    }

    @ViewBuilder
    private var recapHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(session.minutesListened.rounded())) minutes listened")
                .font(.headline)
            if let range = session.chapterRangeLabel {
                Text(range)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if session.hasRoute {
                Text(String(format: "%.1f miles travelled", session.routeMiles))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var routeMap: some View {
        Map {
            MapPolyline(coordinates: session.route.map(\.coordinate))
                .stroke(.tint, lineWidth: 4)
            if let first = session.route.first {
                Marker("Start", coordinate: first.coordinate)
            }
            if let last = session.route.last {
                Marker("End", coordinate: last.coordinate)
            }
        }
    }
}
