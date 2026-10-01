import UIKit

/// Velocity-gated thumbnail loader: skips cells flicked past; settle-only fetch.
actor ThumbLoader {
    private let client: PhotoStreamAPIClient
    private var inflight: [String: Task<Void, Never>] = [:]
    private var isFastScrolling = false
    private var settleTask: Task<Void, Never>?

    var cellPixelSize: CGFloat = 200
    var scale: Int = 3

    init(client: PhotoStreamAPIClient) {
        self.client = client
    }

    func setCellMetrics(pixelSize: CGFloat, scale: Int) {
        cellPixelSize = pixelSize
        self.scale = scale
    }

    func setFastScrolling(_ fast: Bool) {
        isFastScrolling = fast
        if fast {
            cancelAll()
            settleTask?.cancel()
            settleTask = nil
        }
    }

    func scheduleSettle(visibleIDs: [String], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            await loadVisible(ids: visibleIDs, onImage: onImage)
        }
    }

    func loadVisible(ids: [String], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        guard !isFastScrolling else { return }

        let wanted = Set(ids)
        for (id, task) in inflight where !wanted.contains(id) {
            task.cancel()
            inflight[id] = nil
        }

        for id in ids {
            if SessionImageCache.shared.thumb(for: id) != nil { continue }
            start(id: id, onImage: onImage)
        }
    }

    func cancelAll() {
        for (_, task) in inflight {
            task.cancel()
        }
        inflight.removeAll()
    }

    private func start(id: String, onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        if inflight[id] != nil { return }

        let maxPixel = cellPixelSize
        let scale = self.scale
        let client = self.client

        let task = Task { [weak self] in
            defer {
                Task { await self?.clearInflight(id) }
            }
            do {
                let data = try await client.thumbData(
                    assetID: id,
                    width: Int(maxPixel),
                    height: Int(maxPixel),
                    scale: scale
                )
                try Task.checkCancellation()
                guard let image = ImageDownsampler.downsample(
                    data: data,
                    maxPixel: maxPixel * CGFloat(scale)
                ) else { return }
                SessionImageCache.shared.setThumb(image, for: id)
                await onImage(id, image)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        inflight[id] = task
    }

    private func clearInflight(_ id: String) {
        inflight[id] = nil
    }
}
