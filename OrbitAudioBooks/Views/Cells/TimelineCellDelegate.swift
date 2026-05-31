import UIKit

// MARK: - Timeline Cell Delegate

protocol TimelineCellDelegate: AnyObject {
    func timelineCellDidTapPlay(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapPin(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapSearch(_ cell: UICollectionViewCell, item: TimelineItem)
    func timelineCellDidTapHideToggle(_ cell: UICollectionViewCell, item: TimelineItem)
}
