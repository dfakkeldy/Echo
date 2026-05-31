import UIKit

/// Card cell for EPUB image blocks. Loads image from local asset storage.
final class ImageCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ImageCardCell"

    private let artworkView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let captionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(artworkView)
        contentView.addSubview(captionLabel)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            artworkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            artworkView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            artworkView.heightAnchor.constraint(lessThanOrEqualToConstant: 300),

            captionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            captionLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 8),
            captionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with block: EPubBlockRecord, tint: UIColor) {
        var finalImage: UIImage? = nil
        
        if let imagePath = block.imagePath {
            var url = URL(fileURLWithPath: imagePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                let filename = url.lastPathComponent
                let dirName = url.deletingLastPathComponent().lastPathComponent
                let appSupport = FileLocations.applicationSupportDirectory
                url = appSupport.appendingPathComponent("EPUBAssets").appendingPathComponent(dirName).appendingPathComponent(filename)
            }
            finalImage = UIImage(contentsOfFile: url.path)
        }
        
        if let image = finalImage {
            artworkView.image = image
        } else {
            artworkView.image = UIImage(systemName: "photo")
        }
        
        captionLabel.text = block.text
        contentView.backgroundColor = tint.withAlphaComponent(0.05)
    }
}
