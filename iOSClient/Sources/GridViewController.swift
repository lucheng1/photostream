import UIKit

final class GridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIScrollViewDelegate, TimelineGrabberDelegate, MasonryLayoutDelegate, FullImageBrowsing {
    private let client: PhotoStreamAPIClient
    private let loader: ThumbLoader
    private var assets: [AssetSummary] = []
    /// Library index of `assets[0]` (supports timeline jumps into the middle).
    private var windowStart: Int = 0
    private var nextCursor: String? = nil
    private var totalCount: Int = 0
    private var isLoadingPage = false
    private var isJumping = false
    private var collectionView: UICollectionView!
    private let masonryLayout = MasonryLayout()
    private let scrubber = UILabel()
    private let grabber = TimelineGrabberView()
    private var lastPauseBucketID: String?

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

        masonryLayout.delegate = self
        // ~3 columns on a typical iPhone; more on larger phones/iPad (Fotoro algorithm).
        masonryLayout.idealColumnWidth = 120
        masonryLayout.columnSpacing = 4
        masonryLayout.rowSpacing = 4
        masonryLayout.sectionInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: masonryLayout)
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.alwaysBounceVertical = true
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

        grabber.delegate = self
        grabber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grabber)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrubber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrubber.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            scrubber.heightAnchor.constraint(equalToConstant: 28),
            grabber.topAnchor.constraint(equalTo: view.topAnchor),
            grabber.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grabber.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 110),
        ])

        updateThumbScale()
        Task { await loadInitial() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateThumbScale()
    }

    private func updateThumbScale() {
        let scale = Int(view.window?.screen.scale ?? UIScreen.main.scale)
        loader.setScale(scale)
    }

    private func aspectRatio(for asset: AssetSummary) -> CGFloat {
        guard asset.pixelWidth > 0 else { return 1 }
        return CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth)
    }

    private func thumbPointSize(for asset: AssetSummary) -> CGFloat {
        let col = max(masonryLayout.columnWidth, masonryLayout.idealColumnWidth, 1)
        let aspect = min(max(aspectRatio(for: asset), 0.2), 5)
        return col * max(1, aspect)
    }

    // MARK: MasonryLayoutDelegate

    func masonryLayout(_ layout: MasonryLayout, aspectRatioForItemAt index: Int) -> CGFloat {
        guard assets.indices.contains(index) else { return 1 }
        return aspectRatio(for: assets[index])
    }

    private func loadInitial() async {
        do {
            let info = try await client.info()
            totalCount = info.assetCount
            title = "\(info.hostName) · \(info.assetCount)"
            async let timelineTask: Void = loadTimeline()
            try await loadMoreIfNeeded(force: true)
            await timelineTask
            refreshVisibleThumbs(settle: true)
        } catch {
            presentError(error)
        }
    }

    private func loadTimeline() async {
        do {
            let timeline = try await client.timeline()
            grabber.configure(timeline: timeline)
        } catch {
            // Grabber stays hidden if timeline fails; grid still works.
        }
    }

    private func loadMoreIfNeeded(force: Bool = false) async throws {
        if isLoadingPage || isJumping { return }
        if !force, nextCursor == nil, !assets.isEmpty { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let requestCursor = nextCursor
        let page = try await client.assets(cursor: requestCursor, limit: 40)
        let start = assets.count
        if assets.isEmpty {
            windowStart = Int(requestCursor ?? "0") ?? 0
        }
        assets.append(contentsOf: page.items)
        nextCursor = page.nextCursor
        totalCount = page.totalCount
        let indexPaths = (start..<assets.count).map { IndexPath(item: $0, section: 0) }
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: indexPaths)
        }
    }

    /// Load newer photos above the current window so the user can scroll up after a timeline jump.
    private func loadPreviousIfNeeded() async throws {
        if isLoadingPage || isJumping || windowStart <= 0 { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let pageSize = 40
        let newStart = max(0, windowStart - pageSize)
        let limit = windowStart - newStart
        guard limit > 0 else { return }

        let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let anchorPath = visible.first
        let anchorID = anchorPath.map { assets[$0.item].id }
        var anchorOffsetY: CGFloat = 0
        if let anchorPath,
           let attrs = masonryLayout.layoutAttributesForItem(at: anchorPath) {
            anchorOffsetY = attrs.frame.minY - collectionView.contentOffset.y
        }

        let page = try await client.assets(cursor: String(newStart), limit: limit)
        guard !page.items.isEmpty else { return }

        windowStart = newStart
        assets.insert(contentsOf: page.items, at: 0)
        totalCount = page.totalCount

        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        if let anchorID,
           let newIndex = assets.firstIndex(where: { $0.id == anchorID }),
           let attrs = masonryLayout.layoutAttributesForItem(at: IndexPath(item: newIndex, section: 0)) {
            let y = max(0, attrs.frame.minY - anchorOffsetY)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    /// Replace the grid window at a library index (timeline jump / pause preview).
    private func jumpToLibraryIndex(_ startIndex: Int, prefetchThumbs: Bool) async {
        if isJumping { return }
        isJumping = true
        defer { isJumping = false }
        do {
            loader.cancelAll()
            // Include a look-behind so the user can immediately scroll up to newer photos.
            let lookBehind = min(30, startIndex)
            let fetchStart = startIndex - lookBehind
            let page = try await client.assets(cursor: String(fetchStart), limit: 60 + lookBehind)
            windowStart = fetchStart
            assets = page.items
            nextCursor = page.nextCursor
            totalCount = page.totalCount
            collectionView.reloadData()
            collectionView.layoutIfNeeded()

            let localIndex = min(max(0, startIndex - fetchStart), max(0, assets.count - 1))
            if let attrs = masonryLayout.layoutAttributesForItem(at: IndexPath(item: localIndex, section: 0)) {
                collectionView.setContentOffset(
                    CGPoint(x: 0, y: max(0, attrs.frame.minY - masonryLayout.sectionInset.top)),
                    animated: false
                )
            } else {
                collectionView.setContentOffset(.zero, animated: false)
            }
            updateScrubberLabel()
            if prefetchThumbs {
                refreshVisibleThumbs(settle: true)
            }
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func libraryIndex(forItem item: Int) -> Int {
        windowStart + item
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
        let asset = assets[indexPath.item]
        // Memory first, then local disk — avoid a network round-trip when scrolling back.
        let image = SessionImageCache.shared.thumb(for: asset.id)
            ?? SessionImageCache.shared.thumbFromDisk(for: asset.id)
        cell.configure(asset: asset, image: image)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let asset = assets[indexPath.item]
        let thumb = SessionImageCache.shared.thumb(for: asset.id)
        let viewer = FullImageViewController(
            client: client,
            browser: self,
            index: indexPath.item,
            placeholder: thumb
        )
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true)
    }

    // MARK: FullImageBrowsing

    var browseAssets: [AssetSummary] { assets }

    func browseLoadMore() async {
        do { try await loadMoreIfNeeded() } catch { /* ignore */ }
    }

    func browseLoadPrevious() async {
        do { try await loadPreviousIfNeeded() } catch { /* ignore */ }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item > assets.count - 20 {
            Task {
                do { try await loadMoreIfNeeded() } catch { /* ignore while scrolling */ }
            }
        }
        if indexPath.item < 12, windowStart > 0 {
            Task {
                do { try await loadPreviousIfNeeded() } catch { /* ignore while scrolling */ }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let maxIndex = indexPaths.map(\.item).max() ?? 0
        let minIndex = indexPaths.map(\.item).min() ?? 0
        if maxIndex > assets.count - 30 {
            Task { try? await loadMoreIfNeeded() }
        }
        if minIndex < 15, windowStart > 0 {
            Task { try? await loadPreviousIfNeeded() }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {}

    // MARK: Scroll / flick

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let panV = abs(scrollView.panGestureRecognizer.velocity(in: view).y)
        let fast = panV > 1200 || (scrollView.isDecelerating && panV > 400)
        Task { loader.setFastScrolling(fast) }
        updateScrubber(visible: fast || scrollView.isDragging || scrollView.isDecelerating)
        if fast || scrollView.isDecelerating {
            grabber.showGrabber(animated: true)
        }
        if scrollView.contentOffset.y < 240, windowStart > 0 {
            Task { try? await loadPreviousIfNeeded() }
        }
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
            grabber.scheduleHide()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        loader.setFastScrolling(false)
        refreshVisibleThumbs(settle: true)
        hideScrubberSoon()
        grabber.scheduleHide()
    }

    private func midVisibleItem() -> Int? {
        let paths = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        guard !paths.isEmpty else { return nil }
        return paths[paths.count / 2].item
    }

    private func refreshVisibleThumbs(settle: Bool) {
        let paths = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        guard !paths.isEmpty else { return }

        var indices = paths.map(\.item)
        if let first = paths.first?.item, first > 0 {
            indices.insert(max(0, first - 2), at: 0)
        }
        if let last = paths.last?.item, last + 1 < assets.count {
            indices.append(min(assets.count - 1, last + 2))
        }
        // Deduplicate while preserving order
        var seen = Set<Int>()
        indices = indices.filter { seen.insert($0).inserted }

        let items: [ThumbRequest] = indices.compactMap { idx in
            guard assets.indices.contains(idx) else { return nil }
            let asset = assets[idx]
            return ThumbRequest(id: asset.id, pointSize: thumbPointSize(for: asset))
        }

        let collectionView = self.collectionView
        let onImage: @Sendable @MainActor (String, UIImage) -> Void = { id, image in
            for cell in collectionView?.visibleCells ?? [] {
                (cell as? PhotoCell)?.apply(image: image, for: id)
            }
        }
        if settle {
            loader.scheduleSettle(items: items, onImage: onImage)
        } else {
            loader.loadVisible(items: items, onImage: onImage)
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
        guard let mid = midVisibleItem() else {
            scrubber.text = "  —  "
            return
        }
        let asset = assets[mid]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let date = formatter.string(from: asset.createdAt)
        let absolute = libraryIndex(forItem: mid) + 1
        scrubber.text = "  \(date) · \(absolute)/\(max(totalCount, absolute))  "
    }

    private func hideScrubberSoon() {
        UIView.animate(withDuration: 0.25, delay: 0.8) {
            self.scrubber.alpha = 0
        }
    }

    // MARK: Timeline grabber

    func timelineGrabberDidBeginScrub(_ grabber: TimelineGrabberView) {
        lastPauseBucketID = nil
        loader.setFastScrolling(true)
        updateScrubber(visible: true)
    }

    func timelineGrabber(_ grabber: TimelineGrabberView, didScrubTo bucket: TimelineBucket, progress: CGFloat) {
        if bucket.year <= 1 {
            scrubber.text = "  No Date  "
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            var comps = DateComponents()
            comps.year = bucket.year
            comps.month = bucket.month
            comps.day = 1
            let date = Calendar.current.date(from: comps) ?? Date()
            scrubber.text = "  \(formatter.string(from: date)) · \(bucket.startIndex + 1)/\(totalCount)  "
        }
        scrubber.alpha = 1
    }

    func timelineGrabber(_ grabber: TimelineGrabberView, didPauseAt bucket: TimelineBucket) {
        guard lastPauseBucketID != bucket.id else { return }
        lastPauseBucketID = bucket.id
        Task {
            await jumpToLibraryIndex(bucket.startIndex, prefetchThumbs: true)
        }
    }

    func timelineGrabber(_ grabber: TimelineGrabberView, didEndScrubAt bucket: TimelineBucket) {
        Task {
            if lastPauseBucketID != bucket.id {
                await jumpToLibraryIndex(bucket.startIndex, prefetchThumbs: true)
            } else {
                loader.setFastScrolling(false)
                refreshVisibleThumbs(settle: true)
            }
            lastPauseBucketID = nil
            hideScrubberSoon()
        }
    }
}
