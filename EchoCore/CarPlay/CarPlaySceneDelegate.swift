import CarPlay
import SwiftUI

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        let tabTemplate = CPTabBarTemplate(templates: [
            createBrowseTemplate(),
            CPNowPlayingTemplate.shared
        ])
        interfaceController.setRootTemplate(tabTemplate, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Browse Template

    private func createBrowseTemplate() -> CPListTemplate {
        var sections: [CPListSection] = []

        let model = EchoCoreApp.playerModel

        // ── Now Playing ──
        let nowPlayingItem = CPListItem(text: model?.currentTitle ?? "Nothing Playing",
                                         detailText: model?.currentSubtitle)
        nowPlayingItem.isPlaying = model?.isPlaying ?? false
        sections.append(CPListSection(items: [nowPlayingItem], header: "Now Playing", sectionIndexTitle: nil))

        // ── Chapters ──
        if let model, model.isMultiM4B, !model.aggregatedChapters.isEmpty {
            let chapterItems = model.aggregatedChapters.map { chapter -> CPListItem in
                let item = CPListItem(text: chapter.chapterTitle,
                                      detailText: "\(chapter.bookTitle) · \(NowPlayingController.formatTime(chapter.endSeconds - chapter.startSeconds))")
                item.handler = { [weak model] _, completion in
                    model?.seekToAggregatedChapterPosition(bookIndex: chapter.bookIndex,
                                                            startSeconds: chapter.startSeconds)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: chapterItems, header: "Chapters", sectionIndexTitle: nil))
        } else if let chapters = model?.chapters, chapters.count >= 2 {
            let chapterItems = chapters.map { chapter -> CPListItem in
                let title = chapter.title ?? "Ch \(chapter.index + 1)"
                let item = CPListItem(text: title,
                                      detailText: NowPlayingController.formatTime(chapter.endSeconds - chapter.startSeconds))
                item.handler = { [weak model] _, completion in
                    model?.seek(toSeconds: chapter.startSeconds)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: chapterItems, header: "Chapters", sectionIndexTitle: nil))
        }

        // ── Bookmarks ──
        if let bookmarks = model?.bookmarks, !bookmarks.isEmpty {
            let bookmarkItems = bookmarks.map { bm -> CPListItem in
                let item = CPListItem(text: bm.title,
                                      detailText: NowPlayingController.formatTime(bm.timestamp))
                item.handler = { [weak model] _, completion in
                    model?.jumpToBookmark(bm)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: bookmarkItems, header: "Bookmarks", sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "Echo", sections: sections)
        template.tabTitle = "Browse"
        template.tabImage = UIImage(systemName: "list.bullet")
        return template
    }
}
