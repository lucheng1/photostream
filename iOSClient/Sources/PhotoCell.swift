import UIKit

final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    let imageView = UIImageView()
    private let placeholder = UIView()
    private let playBadge = UIImageView()
    private let durationLabel = UILabel()
    private let durationBackdrop = UIView()
    private(set) var assetID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.secondarySystemFill
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 6
        contentView.layer.cornerCurve = .continuous

        placeholder.backgroundColor = UIColor.tertiarySystemFill
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholder)

        // Frames are sized to each photo's aspect ratio, so stretch-to-fill is exact.
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        let playConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        playBadge.image = UIImage(systemName: "play.circle.fill", withConfiguration: playConfig)
        playBadge.tintColor = UIColor.white.withAlphaComponent(0.92)
        playBadge.contentMode = .scaleAspectFit
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        playBadge.isHidden = true
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.35
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        contentView.addSubview(playBadge)

        durationBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        durationBackdrop.layer.cornerRadius = 4
        durationBackdrop.translatesAutoresizingMaskIntoConstraints = false
        durationBackdrop.isHidden = true
        contentView.addSubview(durationBackdrop)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationBackdrop.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            playBadge.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playBadge.widthAnchor.constraint(equalToConstant: 36),
            playBadge.heightAnchor.constraint(equalToConstant: 36),

            durationBackdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            durationBackdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            durationLabel.topAnchor.constraint(equalTo: durationBackdrop.topAnchor, constant: 2),
            durationLabel.bottomAnchor.constraint(equalTo: durationBackdrop.bottomAnchor, constant: -2),
            durationLabel.leadingAnchor.constraint(equalTo: durationBackdrop.leadingAnchor, constant: 5),
            durationLabel.trailingAnchor.constraint(equalTo: durationBackdrop.trailingAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        assetID = nil
        imageView.image = nil
        imageView.isHidden = true
        placeholder.isHidden = false
        playBadge.isHidden = true
        durationBackdrop.isHidden = true
        durationLabel.text = nil
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
        applyVideoChrome(for: asset)
    }

    func apply(image: UIImage, for id: String) {
        guard assetID == id else { return }
        imageView.image = image
        imageView.isHidden = false
        placeholder.isHidden = true
    }

    private func applyVideoChrome(for asset: AssetSummary) {
        let isVideo = asset.mediaType == .video
        playBadge.isHidden = !isVideo
        if isVideo, asset.duration > 0 {
            durationLabel.text = Self.formatDuration(asset.duration)
            durationBackdrop.isHidden = false
        } else {
            durationLabel.text = nil
            durationBackdrop.isHidden = true
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
