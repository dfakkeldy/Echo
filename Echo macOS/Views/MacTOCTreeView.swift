import SwiftUI
import GRDB

/// A TOC tree node for the macOS sidebar.
private struct TOCNode: Identifiable {
    let id: String
    var title: String
    let blockID: String
    var children: [TOCNode]?
}

/// Sidebar view showing the publisher TOC tree from the shared database.
///
/// Loads `EPubTOCEntryRecord` entries from the database and builds a
/// navigable disclosure-group tree by parentID relationships. Clicking a
/// node looks up its alignment anchor and seeks playback to that timestamp.
struct MacTOCTreeView: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService
    @State private var searchText = ""
    @State private var tocNodes: [TOCNode] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading TOC…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if filteredNodes.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Table of Contents",
                    systemImage: "list.bullet",
                    description: Text("Import an EPUB to see chapters here.")
                )
                Spacer()
            } else {
                List(filteredNodes, id: \.id, children: \.children) { node in
                    TOCRowView(node: node)
                        .id(node.id)
                        .onTapGesture {
                            navigateTo(node: node)
                        }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, prompt: "Filter chapters…")
            }
        }
        .frame(minWidth: 200)
        .task {
            await loadTOC()
        }
        .onChange(of: player.currentURL) { _, _ in
            Task { await loadTOC() }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Chapters")
                .font(.headline)
            Spacer()
            Text("\(tocNodes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filtered nodes

    private var filteredNodes: [TOCNode] {
        guard !searchText.isEmpty else { return tocNodes }
        return tocNodes.compactMap { filter(node: $0) }
    }

    /// Recursively filters the tree keeping only nodes matching the search.
    private func filter(node: TOCNode) -> TOCNode? {
        let matchingChildren = (node.children ?? []).compactMap { filter(node: $0) }
        let selfMatches = node.title.localizedCaseInsensitiveContains(searchText)
        if selfMatches || !matchingChildren.isEmpty {
            return TOCNode(
                id: node.id,
                title: node.title,
                blockID: node.blockID,
                children: matchingChildren.isEmpty ? nil : matchingChildren
            )
        }
        return nil
    }

    // MARK: - Load

    private func loadTOC() async {
        isLoading = true
        defer { isLoading = false }

        guard let audiobookID = player.audiobookID else {
            tocNodes = []
            return
        }

        do {
            let entries = try await dbService.writer.read { db in
                try EPubTOCEntryRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .order(Column("order_index"))
                    .fetchAll(db)
            }

            tocNodes = buildTree(from: entries)
        } catch {
            tocNodes = []
        }
    }

    /// Builds a tree of `TOCNode` from flat `EPubTOCEntryRecord` entries
    /// by grouping on `parentID` and sorting by `orderIndex`.
    private func buildTree(from entries: [EPubTOCEntryRecord]) -> [TOCNode] {
        let childrenByParent = Dictionary(grouping: entries, by: \.parentID)
        return nodes(forParent: nil, childrenByParent: childrenByParent)
    }

    private func nodes(
        forParent parentID: String?,
        childrenByParent: [String?: [EPubTOCEntryRecord]]
    ) -> [TOCNode] {
        guard let children = childrenByParent[parentID], !children.isEmpty else { return [] }
        return children.map { entry in
            let grandChildren = nodes(forParent: entry.id, childrenByParent: childrenByParent)
            return TOCNode(
                id: entry.id,
                title: entry.title,
                blockID: entry.blockID ?? grandChildren.first?.blockID ?? "",
                children: grandChildren.isEmpty ? nil : grandChildren
            )
        }
    }

    // MARK: - Navigation

    private func navigateTo(node: TOCNode) {
        guard let audiobookID = player.audiobookID else { return }
        guard !node.blockID.isEmpty else { return }

        do {
            let anchor = try dbService.writer.read { db in
                try AlignmentAnchorRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(Column("epub_block_id") == node.blockID)
                    .fetchOne(db)
            }
            if let anchor {
                player.seek(to: anchor.audioTime)
                if !player.isPlaying { player.play() }
            }
        } catch {
            // Silently ignore alignment lookup failures
        }
    }
}

// MARK: - TOC Row

private struct TOCRowView: View {
    let node: TOCNode

    var body: some View {
        HStack(spacing: 6) {
            if node.children == nil || node.children!.isEmpty {
                Image(systemName: "book.pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(node.title)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
