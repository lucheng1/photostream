import UIKit

protocol FullImageBrowsing: AnyObject {
    var browseAssets: [AssetSummary] { get }
    func browseLoadMore() async
    func browseLoadPrevious() async
}

/// Full-screen viewer with Google/Amazon Photos–style interactive paging:
/// the current photo tracks the finger 1:1 while the next/prev photo slides in
/// from the opposite edge until release completes or cancels the swipe.
final class FullImageViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let client: PhotoStreamAPIClient
    private weak var browser: FullImageBrowsing?
    private var index: Int
    private var currentID: String

    private let pager = UIView()
    private let currentScroll = UIScrollView()
    private let currentImage = UIImageView()
    private let adjacentScroll = UIScrollView()
    private let adjacentImage = UIImageView()

    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)

    private var loadTask: Task<Void, Never>?
    private var navPan: UIPanGestureRecognizer!
    private var isTransitioning = false
    private var activeDelta: Int = 0 // +1 next (older), -1 prev (newer), 0 none
    private var lastSwipeDelta: Int = 1 // prefer prefetching forward after open
    private var dragAxisHorizontal = true
    private let prefetchDepth = 2

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
        currentImage.image = placeholder
    }

    required init?(coder: NSCoder) { nil }

    private var assets: [AssetSummary] {
        browser?.browseAssets ?? []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        pager.clipsToBounds = true
        pager.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pager)

        configureZoomScroll(currentScroll, imageView: currentImage)
        configureZoomScroll(adjacentScroll, imageView: adjacentImage)
        adjacentScroll.isHidden = true
        pager.addSubview(adjacentScroll)
        pager.addSubview(currentScroll)

        closeButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        closeButton.tintColor = UIColor(white: 0.15, alpha: 1)
        closeButton.backgroundColor = UIColor(white: 0.94, alpha: 0.95)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = false
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOpacity = 0.18
        closeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        closeButton.layer.shadowRadius = 2
        closeButton.accessibilityLabel = "Back"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        currentScroll.addGestureRecognizer(doubleTap)

        navPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        navPan.delegate = self
        currentScroll.panGestureRecognizer.require(toFail: navPan)
        view.addGestureRecognizer(navPan)

        NSLayoutConstraint.activate([
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task {
            await loadFull(for: currentID, into: .current)
            await prefetchNeighbors()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isTransitioning, activeDelta == 0 {
            currentScroll.frame = pager.bounds
            adjacentScroll.frame = pager.bounds
            layoutImage(in: currentScroll, imageView: currentImage)
        }
    }

    private func configureZoomScroll(_ scroll: UIScrollView, imageView: UIImageView) {
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
    }

    private enum Slot { case current, adjacent }

    private func layoutImage(in scroll: UIScrollView, imageView: UIImageView) {
        guard let image = imageView.image else {
            imageView.frame = .zero
            scroll.contentSize = scroll.bounds.size
            return
        }
        let bounds = scroll.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        scroll.zoomScale = 1
        let imageSize = image.size
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageView.frame = CGRect(
            x: (bounds.width - scaled.width) / 2,
            y: (bounds.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        )
        scroll.contentSize = bounds
        scroll.contentOffset = .zero
    }

    private func displayImage(for asset: AssetSummary) -> UIImage? {
        SessionImageCache.shared.full(for: asset.id)
            ?? SessionImageCache.shared.thumb(for: asset.id)
            ?? SessionImageCache.shared.thumbFromDisk(for: asset.id)
    }

    private func loadFull(for id: String, into slot: Slot) async {
        if let cached = SessionImageCache.shared.full(for: id) {
            await MainActor.run {
                applyLoaded(image: cached, id: id, into: slot)
            }
            return
        }
        if slot == .current {
            await MainActor.run { spinner.startAnimating() }
        }
        do {
            let data = try await client.fullImage(assetID: id)
            let image = UIImage(data: data)
            if let image {
                SessionImageCache.shared.setFull(image, for: id)
                await MainActor.run {
                    applyLoaded(image: image, id: id, into: slot)
                }
            }
        } catch {
            // Keep placeholder
        }
        if slot == .current {
            await MainActor.run {
                if currentID == id { spinner.stopAnimating() }
            }
        }
    }

    private func applyLoaded(image: UIImage, id: String, into slot: Slot) {
        switch slot {
        case .current:
            guard currentID == id else { return }
            currentImage.image = image
            layoutImage(in: currentScroll, imageView: currentImage)
        case .adjacent:
            adjacentImage.image = image
            layoutImage(in: adjacentScroll, imageView: adjacentImage)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        if scrollView === currentScroll { return currentImage }
        if scrollView === adjacentScroll { return adjacentImage }
        return nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let imageView = scrollView === currentScroll ? currentImage : adjacentImage
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
        guard activeDelta == 0, !isTransitioning else { return }
        if currentScroll.zoomScale > 1.1 {
            currentScroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: currentImage)
            let zoom: CGFloat = 2.5
            let size = CGSize(
                width: currentScroll.bounds.width / zoom,
                height: currentScroll.bounds.height / zoom
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            currentScroll.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    // MARK: Interactive paging
    // Gesture map: up / left → next (older, +1); down / right → prev (newer, -1)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard currentScroll.zoomScale <= 1.05, !isTransitioning else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            break

        case .changed:
            updateInteractiveDrag(translation: translation)

        case .ended, .cancelled:
            finishInteractiveDrag(translation: translation, velocity: velocity)

        default:
            break
        }
    }

    private func updateInteractiveDrag(translation: CGPoint) {
        let bounds = pager.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        dragAxisHorizontal = abs(translation.x) >= abs(translation.y)

        // Decide neighbor from gesture map.
        let delta: Int
        if dragAxisHorizontal {
            delta = translation.x < 0 ? 1 : (translation.x > 0 ? -1 : activeDelta)
        } else {
            delta = translation.y < 0 ? 1 : (translation.y > 0 ? -1 : activeDelta)
        }

        let target = index + delta
        let hasNeighbor = delta != 0 && assets.indices.contains(target)

        if hasNeighbor {
            if activeDelta != delta {
                activeDelta = delta
                lastSwipeDelta = delta
                prepareAdjacent(for: target)
                // Warm the next couple of photos further in this swipe direction.
                prefetchAhead(direction: delta, count: prefetchDepth)
            }
        } else {
            activeDelta = 0
            adjacentScroll.isHidden = true
        }

        // Rubber-band when there's no neighbor in that direction.
        let resistance: CGFloat = hasNeighbor ? 1 : 0.28
        let dx = dragAxisHorizontal ? translation.x * resistance : 0
        let dy = dragAxisHorizontal ? 0 : translation.y * resistance

        currentScroll.frame = bounds.offsetBy(dx: dx, dy: dy)

        if hasNeighbor {
            adjacentScroll.isHidden = false
            // Neighbor starts off-screen on the edge we're dragging toward, then follows.
            // left/up (next,+1): neighbor enters from right / bottom
            // right/down (prev,-1): neighbor enters from left / top
            if dragAxisHorizontal {
                let startX = delta > 0 ? bounds.width : -bounds.width
                adjacentScroll.frame = bounds.offsetBy(dx: startX + dx, dy: 0)
            } else {
                let startY = delta > 0 ? bounds.height : -bounds.height
                adjacentScroll.frame = bounds.offsetBy(dx: 0, dy: startY + dy)
            }
        }
    }

    private func prepareAdjacent(for targetIndex: Int) {
        guard assets.indices.contains(targetIndex) else { return }
        let asset = assets[targetIndex]
        adjacentScroll.zoomScale = 1
        adjacentImage.image = displayImage(for: asset)
        adjacentScroll.frame = pager.bounds
        layoutImage(in: adjacentScroll, imageView: adjacentImage)
        adjacentScroll.isHidden = false
        Task { await loadFull(for: asset.id, into: .adjacent) }
    }

    private func finishInteractiveDrag(translation: CGPoint, velocity: CGPoint) {
        let bounds = pager.bounds
        let threshold: CGFloat = min(bounds.width, bounds.height) * 0.22
        let velocityThreshold: CGFloat = 500

        let primary = dragAxisHorizontal ? translation.x : translation.y
        let primaryVelocity = dragAxisHorizontal ? velocity.x : velocity.y
        let distance = abs(primary)

        let shouldCommit: Bool
        if activeDelta == 0 {
            shouldCommit = false
        } else if activeDelta > 0 {
            // Next via left/up → negative translation
            shouldCommit = primary < -threshold || primaryVelocity < -velocityThreshold
        } else {
            // Prev via right/down → positive translation
            shouldCommit = primary > threshold || primaryVelocity > velocityThreshold
        }

        if shouldCommit, assets.indices.contains(index + activeDelta) {
            commitPageChange()
        } else {
            cancelPageChange()
        }
    }

    private func commitPageChange() {
        let delta = activeDelta
        let target = index + delta
        guard assets.indices.contains(target) else {
            cancelPageChange()
            return
        }

        isTransitioning = true
        let bounds = pager.bounds
        let endCurrent: CGRect
        let endAdjacent = bounds
        if dragAxisHorizontal {
            endCurrent = bounds.offsetBy(dx: delta > 0 ? -bounds.width : bounds.width, dy: 0)
        } else {
            endCurrent = bounds.offsetBy(dx: 0, dy: delta > 0 ? -bounds.height : bounds.height)
        }

        let distance = hypot(
            endCurrent.origin.x - currentScroll.frame.origin.x,
            endCurrent.origin.y - currentScroll.frame.origin.y
        )
        let duration = min(0.32, max(0.16, distance / 1800))

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.currentScroll.frame = endCurrent
            self.adjacentScroll.frame = endAdjacent
        } completion: { _ in
            self.promoteAdjacent(to: target)
            self.isTransitioning = false
            self.lastSwipeDelta = delta
            self.activeDelta = 0
            Task { await self.prefetchNeighbors() }
        }
    }

    private func cancelPageChange() {
        isTransitioning = true
        let bounds = pager.bounds
        // Park adjacent back off-screen in the direction it came from.
        var endAdjacent = bounds
        if activeDelta != 0 {
            if dragAxisHorizontal {
                endAdjacent = bounds.offsetBy(dx: activeDelta > 0 ? bounds.width : -bounds.width, dy: 0)
            } else {
                endAdjacent = bounds.offsetBy(dx: 0, dy: activeDelta > 0 ? bounds.height : -bounds.height)
            }
        }

        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: [.allowUserInteraction]
        ) {
            self.currentScroll.frame = bounds
            self.adjacentScroll.frame = endAdjacent
        } completion: { _ in
            self.adjacentScroll.isHidden = true
            self.adjacentImage.image = nil
            self.activeDelta = 0
            self.isTransitioning = false
        }
    }

    private func promoteAdjacent(to targetIndex: Int) {
        // Swap roles: adjacent becomes current without a visual flash.
        let oldScroll = currentScroll
        // Move adjacent (now showing the new photo) into current slot visually.
        // Easiest: copy image into current, reset frames.
        guard assets.indices.contains(targetIndex) else { return }
        let asset = assets[targetIndex]
        index = targetIndex
        currentID = asset.id
        currentImage.image = adjacentImage.image ?? displayImage(for: asset)
        currentScroll.zoomScale = 1
        currentScroll.frame = pager.bounds
        layoutImage(in: currentScroll, imageView: currentImage)

        adjacentScroll.isHidden = true
        adjacentImage.image = nil
        adjacentScroll.frame = pager.bounds
        oldScroll.contentOffset = .zero

        loadTask?.cancel()
        spinner.stopAnimating()
        let id = asset.id
        loadTask = Task { await loadFull(for: id, into: .current) }
    }

    private func prefetchNeighbors() async {
        await browser?.browseLoadMore()
        if let refreshed = browser?.browseAssets,
           let newIdx = refreshed.firstIndex(where: { $0.id == currentID }) {
            index = newIdx
        }
        if index < 12 {
            await browser?.browseLoadPrevious()
            if let refreshed = browser?.browseAssets,
               let newIdx = refreshed.firstIndex(where: { $0.id == currentID }) {
                index = newIdx
            }
        }
        // Always keep a couple cached on both sides; prioritize last swipe direction.
        let primary = lastSwipeDelta == 0 ? 1 : lastSwipeDelta
        prefetchAhead(direction: primary, count: prefetchDepth)
        prefetchAhead(direction: -primary, count: prefetchDepth)
    }

    /// Cache full images for the next `count` photos in `direction` (+1 next, -1 prev).
    private func prefetchAhead(direction: Int, count: Int) {
        guard direction != 0, count > 0 else { return }
        var ids: [String] = []
        for step in 1...count {
            let i = index + direction * step
            guard assets.indices.contains(i) else { break }
            let id = assets[i].id
            if SessionImageCache.shared.full(for: id) == nil {
                ids.append(id)
            }
        }
        for id in ids {
            Task {
                if let data = try? await client.fullImage(assetID: id),
                   let image = UIImage(data: data) {
                    SessionImageCache.shared.setFull(image, for: id)
                }
            }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan == navPan else { return true }
        guard currentScroll.zoomScale <= 1.05, !isTransitioning else { return false }
        let v = pan.velocity(in: view)
        return hypot(v.x, v.y) > 20
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
