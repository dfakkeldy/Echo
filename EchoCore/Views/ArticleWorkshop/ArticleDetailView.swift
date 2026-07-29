// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
    import SwiftUI

    struct ArticleDetailView: View {
        let article: ArticleInboxItem
        let cleanupContext: ArticleCleanupContext?

        var body: some View {
            List {
                Section("Article") {
                    Text(article.title)
                        .font(.title2)
                        .bold()
                        .accessibilityAddTraits(.isHeader)

                    if let byline {
                        LabeledContent("By", value: byline)
                    }

                    if let siteName = article.siteName, siteName.isEmpty == false {
                        LabeledContent("Site", value: siteName)
                    }

                    Label(article.state.title, systemImage: article.state.systemImage)

                    if let sourceURL {
                        Link(destination: sourceURL) {
                            Label("View Original", systemImage: "safari")
                                .frame(minHeight: 44)
                        }
                        .accessibilityHint("Opens the original article")
                    }
                }

                if article.isPossibleDuplicate || article.warnings.isEmpty == false {
                    Section("Review") {
                        if article.isPossibleDuplicate {
                            Label(
                                "Possible duplicate. Keep Both remains available.",
                                systemImage: "doc.on.doc"
                            )
                        }

                        ForEach(article.warningOccurrences) { warning in
                            Label(warning.text, systemImage: "exclamationmark.triangle")
                        }
                    }
                }

                Section("Clean Up") {
                    Label("Cleanup is on demand", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text(
                        "Echo always keeps the original capture. Cleanup saves a reversible structural revision."
                    )
                    .foregroundStyle(.secondary)

                    if cleanupContext != nil {
                        NavigationLink(value: ArticleCleanupRoute(captureID: article.id)) {
                            Label("Clean Up Article", systemImage: "slider.horizontal.3")
                                .frame(minHeight: 44)
                        }
                        .accessibilityHint(
                            "Opens reversible controls for removing blocks, trimming, and correcting metadata"
                        )
                    } else {
                        Label(
                            "Cleanup is unavailable in this context.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Article")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ArticleCleanupRoute.self) { route in
                if let cleanupContext {
                    ArticleCleanupLoadingView(
                        captureID: route.captureID,
                        context: cleanupContext)
                }
            }
        }

        private var byline: String? {
            guard
                let author = article.author?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                author.isEmpty == false
            else {
                return nil
            }
            return author
        }

        private var sourceURL: URL? {
            guard
                let url = URL(string: article.sourceURL),
                let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                url.host != nil
            else {
                return nil
            }
            return url
        }
    }

    nonisolated struct ArticleCleanupRoute: Hashable, Sendable {
        let captureID: String
    }
#endif
