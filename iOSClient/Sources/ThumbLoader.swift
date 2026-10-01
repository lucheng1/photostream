import UIKit

/// Velocity-gated thumbnail loader: skips cells flicked past; settle-only fetch.
final class ThumbLoader: @unchecked Sendable {
    private let client: PhotoStreamAPIClient
    private let queue = DispatchQueue(label: "app.photostream.thumbloader")
    private var inflight: [String: Task<Void, Never>] = [:]
    private var isFastScrolling = false
    private var settleWorkItem: DispatchWorkItem?

    private var cellPixelSize: CGFloat = 200
    private var scale: Int = 3

    init(client: PhotoStreamAPIClient) {
        self.client = client
    }

    func setCellMetrics(pixelSize: CGFloat, scale: Int) {
        queue.async {
            self.cellPixelSize = pixelSize
            self.scale = scale
        }
    }

    func setFastScrolling(_ fast: Bool) {
        queue.async {
            self.isFastScrolling = fast
            if fast {
                self.cancelAllLocked()
                self.settleWorkItem?.cancel()
                self.settleWorkItem = nil
            }
        }
    }

    func scheduleSettle(visibleIDs: [String], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        queue.async {
            self.settleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.loadVisible(ids: visibleIDs, onImage: onImage)
            }
            self.settleWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.07, execute: work)
        }
    }

    func loadVisible(ids: [String], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        queue.async {
            guard !self.isFastScrolling else { return }
            let wanted = Set(ids)
            for (id, task) in self.inflight where !wanted.contains(id) {
                task.cancel()
                self.inflight[id] = nil
            }
            for id in ids {
                if SessionImageCache.shared.thumb(for: id) != nil { continue }
                self.startLocked(id: id, onImage: onImage)
            }
        }
    }

    func cancelAll() {
        queue.async { self.cancelAllLocked() }
    }

    private func cancelAllLocked() {
        for (_, task) in inflight {
            task.cancel()
        }
        inflight.removeAll()
    }

    private func startLocked(id: String, onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        if inflight[id] != nil { return }

        let maxPixel = cellPixelSize
        let scale = self.scale
        let client = self.client

        let task = Task { [weak self] in
            defer {
                self?.queue.async {
                    self?.inflight[id] = nil
                }
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
            } catch {
                return
            }
        }
        inflight[id] = task
    }
}
