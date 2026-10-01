import UIKit

protocol FullImageBrowsing: AnyObject {
    var browseAssets: [AssetSummary] { get }
    func browseLoadMore() async
    func browseLoadPrevious() async
}

final class FullImageViewController: UIViewController, UIScrollViewDelegate {
    private let client: PhotoStreamAPIClient
    private weak var browser: FullImageBrowsing?
    private var index: Int
    private var currentID: String

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private var loadTask: Task<Void, Never>?
    private var isTransitioning = false

    init(
        client: PhotoStreamAPIClient,
        browser: FullImageBrowsing,
        index: Int,
        placeholder: UIImage?
    ) {
        self.client = client
        self.browser = browser
        self.index = index
        let asset = browser.browseAssets[index]
        self.currentID = asset.id
        super.init(nibName: nil, bundle: nil)
        imageView.image = placeholder
    }

    required init?(coder: NSCoder) { nil }

    private var assets: [AssetSummary] {
        browser?.browseAssets ?? []
    }

    private var currentAsset: AssetSummary? {
        guard assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

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

        Task { await loadFull(for: currentID) }
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

    private func loadFull(for id: String) async {
        if let cached = SessionImageCache.shared.full(for: id) {
            guard currentID == id else { return }
            imageView.image = cached
            layoutImage()
            return
        }
        spinner.startAnimating()
        do {
            let data = try await client.fullImage(assetID: id)
            guard currentID == id else { return }
            let image = UIImage(data: data)
            if let image {
                SessionImageCache.shared.setFull(image, for: id)
                imageView.image = image
                layoutImage()
            }
        } catch {
            // Keep placeholder / prior image
        }
        if currentID == id {
            spinner.stopAnimating()
        }
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

    /// Swipe down / right → next (earlier date); swipe up / left → prev (more recent).
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= 1.05, !isTransitioning else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            view.transform = CGAffineTransform(translationX: translation.x * 0.45, y: translation.y * 0.45)
            let distance = hypot(translation.x, translation.y)
            view.alpha = max(0.6, 1 - distance / 280)

        case .ended, .cancelled:
            // Short swipes — small travel or a light flick is enough.
            let threshold: CGFloat = 28
            let velocityThreshold: CGFloat = 220
            let dominantHorizontal = abs(translation.x) >= abs(translation.y)
            let goNext: Bool
            let goPrev: Bool
            if dominantHorizontal {
                goNext = translation.x > threshold || velocity.x > velocityThreshold
                goPrev = translation.x < -threshold || velocity.x < -velocityThreshold
            } else {
                goNext = translation.y > threshold || velocity.y > velocityThreshold
                goPrev = translation.y < -threshold || velocity.y < -velocityThreshold
            }

            if goNext {
                // Next = earlier chronologically (higher index in newest-first library).
                navigate(delta: 1, from: translation)
            } else if goPrev {
                // Prev = more recent chronologically (lower index).
                navigate(delta: -1, from: translation)
            } else {
                UIView.animate(withDuration: 0.18) {
                    self.view.transform = .identity
                    self.view.alpha = 1
                }
            }

        default:
            break
        }
    }

    private func navigate(delta: Int, from translation: CGPoint) {
        // Newest-first library: -1 = more recent (prev), +1 = earlier (next).
        let target = index + delta
        guard assets.indices.contains(target), target != index else {
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.5) {
                self.view.transform = .identity
                self.view.alpha = 1
            }
            return
        }

        isTransitioning = true
        let exitX: CGFloat = abs(translation.x) >= abs(translation.y)
            ? (delta > 0 ? view.bounds.width : -view.bounds.width)
            : translation.x * 0.2
        let exitY: CGFloat = abs(translation.y) > abs(translation.x)
            ? (delta > 0 ? view.bounds.height : -view.bounds.height)
            : translation.y * 0.2

        UIView.animate(withDuration: 0.14, animations: {
            self.view.transform = CGAffineTransform(translationX: exitX * 0.45, y: exitY * 0.45)
            self.view.alpha = 0.15
        }, completion: { _ in
            self.applyAsset(at: target)
            self.view.transform = CGAffineTransform(translationX: -exitX * 0.2, y: -exitY * 0.2)
            UIView.animate(withDuration: 0.16, animations: {
                self.view.transform = .identity
                self.view.alpha = 1
            }, completion: { _ in
                self.isTransitioning = false
            })
            Task { await self.prefetchNeighbors() }
        })
    }

    private func applyAsset(at newIndex: Int) {
        guard assets.indices.contains(newIndex) else { return }
        index = newIndex
        let asset = assets[newIndex]
        currentID = asset.id
        scrollView.setZoomScale(1, animated: false)
        loadTask?.cancel()
        spinner.stopAnimating()

        if let full = SessionImageCache.shared.full(for: asset.id) {
            imageView.image = full
        } else if let thumb = SessionImageCache.shared.thumb(for: asset.id) {
            imageView.image = thumb
        } else {
            imageView.image = nil
        }
        layoutImage()

        let id = asset.id
        loadTask = Task {
            await loadFull(for: id)
        }
    }

    private func prefetchNeighbors() async {
        await browser?.browseLoadMore()
        if let refreshed = browser?.browseAssets,
           let newIdx = refreshed.firstIndex(where: { $0.id == currentID }) {
            index = newIdx
        }
        // Also backfill newer photos when near the start of a jumped window.
        if index < 12 {
            await browser?.browseLoadPrevious()
            if let refreshed = browser?.browseAssets,
               let newIdx = refreshed.firstIndex(where: { $0.id == currentID }) {
                index = newIdx
            }
        }
        let neighbors = [index - 1, index + 1].filter { assets.indices.contains($0) }
        for i in neighbors {
            let id = assets[i].id
            if SessionImageCache.shared.full(for: id) != nil { continue }
            Task {
                if let data = try? await client.fullImage(assetID: id),
                   let image = UIImage(data: data) {
                    SessionImageCache.shared.setFull(image, for: id)
                }
            }
        }
    }
}

extension FullImageViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard scrollView.zoomScale <= 1.05, !isTransitioning else { return false }
        let v = pan.velocity(in: view)
        return hypot(v.x, v.y) > 40
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
