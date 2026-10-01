import PhotoStreamShared
import UIKit

final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    let imageView = UIImageView()
    private let placeholder = UIView()
    private(set) var assetID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.secondarySystemFill
        contentView.clipsToBounds = true

        placeholder.backgroundColor = UIColor.tertiarySystemFill
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholder)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        assetID = nil
        imageView.image = nil
        imageView.isHidden = true
        placeholder.isHidden = false
    }

    func configure(asset: AssetSummary, image: UIImage?) {
        assetID = asset.id
        if let image {
            imageView.image = image
            imageView.isHidden = false
            placeholder.isHidden = true
        } else {
            imageView.image = nil
            imageView.isHidden = true
            placeholder.isHidden = false
        }
    }

    func apply(image: UIImage, for id: String) {
        guard assetID == id else { return }
        imageView.image = image
        imageView.isHidden = false
        placeholder.isHidden = true
    }
}
