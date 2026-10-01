import UIKit

final class GridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
    private let client: PhotoStreamAPIClient
    private let loader: ThumbLoader
    private var assets: [AssetSummary] = []
    private var nextCursor: String? = nil
    private var totalCount: Int = 0
    private var isLoadingPage = false
    private var collectionView: UICollectionView!
    private let scrubber = UILabel()
    private var lastVelocity: CGFloat = 0
    private let velocityThreshold: CGFloat = 2.2

    init(client: PhotoStreamAPIClient) {
        self.client = client
        self.loader = ThumbLoader(client: client)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "PhotoStream"
        navigationItem.largeTitleDisplayMode = .never

        let spacing: CGFloat = 2
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = UIEdgeInsets(top: spacing, left: spacing, bottom: spacing, right: spacing)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        scrubber.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        scrubber.textColor = .label
        scrubber.textAlignment = .center
        scrubber.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        scrubber.layer.cornerRadius = 10
        scrubber.clipsToBounds = true
        scrubber.alpha = 0
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrubber)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrubber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrubber.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            scrubber.heightAnchor.constraint(equalToConstant: 28),
        ])

        updateCellMetrics()
        Task { await loadInitial() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCellMetrics()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let spacing: CGFloat = 2
            let width = collectionView.bounds.width - spacing * 3
            let side = floor(width / 2)
            layout.itemSize = CGSize(width: side, height: side)
        }
    }

    private func updateCellMetrics() {
        let spacing: CGFloat = 2
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let side = floor((width - spacing * 3) / 2)
        loader.cellPixelSize = side
        loader.scale = Int(view.window?.screen.scale ?? UIScreen.main.scale)
    }

    private func loadInitial() async {
        do {
            let info = try await client.info()
            totalCount = info.assetCount
            title = "\(info.hostName) · \(info.assetCount)"
            try await loadMoreIfNeeded(force: true)
            refreshVisibleThumbs(settle: true)
        } catch {
            presentError(error)
        }
    }

    private func loadMoreIfNeeded(force: Bool = false) async throws {
        if isLoadingPage { return }
        if !force, nextCursor == nil, !assets.isEmpty { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let page = try await client.assets(cursor: nextCursor, limit: 40)
        let start = assets.count
        assets.append(contentsOf: page.items)
        nextCursor = page.nextCursor
        totalCount = page.totalCount
        let indexPaths = (start..<assets.count).map { IndexPath(item: $0, section: 0) }
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: indexPaths)
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
        let asset = assets[indexPath.item]
        cell.configure(asset: asset, image: SessionImageCache.shared.thumb(for: asset.id))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let asset = assets[indexPath.item]
        let thumb = SessionImageCache.shared.thumb(for: asset.id)
        let viewer = FullImageViewController(client: client, asset: asset, placeholder: thumb)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item > assets.count - 20 {
            Task {
                do { try await loadMoreIfNeeded() } catch { /* ignore while scrolling */ }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        // Metadata-only prefetch via willDisplay; do not prefetch thumbs during flick.
        let maxIndex = indexPaths.map(\.item).max() ?? 0
        if maxIndex > assets.count - 30 {
            Task { try? await loadMoreIfNeeded() }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {}

    // MARK: Scroll / flick

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let velocity = abs(scrollView.panGestureRecognizer.velocity(in: scrollView).y) / 1000
        lastVelocity = max(velocity, abs(scrollView.contentOffset.y - (scrollView.layer.presentation()?.bounds.origin.y ?? scrollView.contentOffset.y)) )
        // Prefer pan velocity when dragging; during deceleration estimate via offset changes is noisy —
        // use isDecelerating + pan velocity.
        let panV = abs(scrollView.panGestureRecognizer.velocity(in: view).y)
        let fast = panV > 1200 || (scrollView.isDecelerating && panV > 400)
        loader.setFastScrolling(fast)
        updateScrubber(visible: fast || scrollView.isDragging || scrollView.isDecelerating)
        if !fast && !scrollView.isDecelerating && !scrollView.isDragging {
            refreshVisibleThumbs(settle: false)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        updateScrubber(visible: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            loader.setFastScrolling(false)
            refreshVisibleThumbs(settle: true)
            hideScrubberSoon()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        loader.setFastScrolling(false)
        refreshVisibleThumbs(settle: true)
        hideScrubberSoon()
    }

    private func refreshVisibleThumbs(settle: Bool) {
        let paths = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        guard !paths.isEmpty else { return }
        var ids = paths.map { assets[$0.item].id }
        // 1-row buffer (2 cells)
        if let first = paths.first?.item, first > 0 {
            ids.insert(assets[max(0, first - 2)].id, at: 0)
        }
        if let last = paths.last?.item, last + 1 < assets.count {
            ids.append(assets[min(assets.count - 1, last + 2)].id)
        }
        let onImage: @MainActor (String, UIImage) -> Void = { [weak self] id, image in
            guard let self else { return }
            for cell in self.collectionView.visibleCells {
                (cell as? PhotoCell)?.apply(image: image, for: id)
            }
        }
        if settle {
            loader.scheduleSettle(visibleIDs: ids, onImage: onImage)
        } else {
            loader.loadVisible(ids: ids, onImage: onImage)
        }
        updateScrubberLabel()
    }

    private func updateScrubber(visible: Bool) {
        updateScrubberLabel()
        UIView.animate(withDuration: 0.15) {
            self.scrubber.alpha = visible ? 1 : self.scrubber.alpha
        }
    }

    private func updateScrubberLabel() {
        guard let mid = collectionView.indexPathsForVisibleItems.sorted(by: { $0.item < $1.item }).dropFirst(
            max(0, collectionView.indexPathsForVisibleItems.count / 2 - 1)
        ).first else {
            scrubber.text = "  —  "
            return
        }
        let asset = assets[mid.item]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let date = formatter.string(from: asset.createdAt)
        scrubber.text = "  \(date) · \(mid.item + 1)/\(max(totalCount, assets.count))  "
    }

    private func hideScrubberSoon() {
        UIView.animate(withDuration: 0.25, delay: 0.8) {
            self.scrubber.alpha = 0
        }
    }
}
