import UIKit

final class FullImageViewController: UIViewController, UIScrollViewDelegate {
    private let client: PhotoStreamAPIClient
    private let asset: AssetSummary
    private let placeholder: UIImage?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)

    init(client: PhotoStreamAPIClient, asset: AssetSummary, placeholder: UIImage?) {
        self.client = client
        self.asset = asset
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.image = placeholder
        scrollView.addSubview(imageView)

        closeButton.setTitle("Close", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task { await loadFull() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let imageSize = image.size
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageView.frame = CGRect(
            x: (bounds.width - scaled.width) / 2,
            y: (bounds.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        )
        scrollView.contentSize = bounds
        scrollView.zoomScale = 1
    }

    private func loadFull() async {
        if let cached = SessionImageCache.shared.full(for: asset.id) {
            imageView.image = cached
            layoutImage()
            return
        }
        spinner.startAnimating()
        do {
            let data = try await client.fullImage(assetID: asset.id)
            let image = UIImage(data: data)
            if let image {
                SessionImageCache.shared.setFull(image, for: asset.id)
                imageView.image = image
                layoutImage()
            }
        } catch {
            // Keep placeholder
        }
        spinner.stopAnimating()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let bounds = scrollView.bounds.size
        let offsetX = max((bounds.width - scrollView.contentSize.width) * 0.5, 0)
        let offsetY = max((bounds.height - scrollView.contentSize.height) * 0.5, 0)
        imageView.center = CGPoint(
            x: scrollView.contentSize.width * 0.5 + offsetX,
            y: scrollView.contentSize.height * 0.5 + offsetY
        )
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let zoom: CGFloat = 2.5
            let size = CGSize(
                width: scrollView.bounds.width / zoom,
                height: scrollView.bounds.height / zoom
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= 1.05 else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            if translation.y > 0 {
                view.transform = CGAffineTransform(translationX: 0, y: translation.y)
                view.alpha = max(0.4, 1 - translation.y / 300)
            }
        case .ended, .cancelled:
            if translation.y > 140 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.view.transform = .identity
                    self.view.alpha = 1
                }
            }
        default:
            break
        }
    }
}

extension FullImageViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x) && v.y > 0 && scrollView.zoomScale <= 1.05
    }
}
