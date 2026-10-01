import UIKit

/// Velocity-gated thumbnail loader: skips cells flicked past; settle-only fetch.
final class ThumbLoader {
    private let client: PhotoStreamAPIClient
    private var inflight: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()
    private var isFastScrolling = false
    private var settleWorkItem: DispatchWorkItem?

    var cellPixelSize: CGFloat = 200
    var scale: Int = 3

    init(client: PhotoStreamAPIClient) {
        self.client = client
    }

    func setFastScrolling(_ fast: Bool) {
        lock.lock()
        isFastScrolling = fast
        lock.unlock()
        if fast {
            cancelAll()
            settleWorkItem?.cancel()
        }
    }

    func scheduleSettle(visibleIDs: [String], onImage: @escaping @MainActor (String, UIImage) -> Void) {
        settleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadVisible(ids: visibleIDs, onImage: onImage)
        }
        settleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func loadVisible(ids: [String], onImage: @escaping @MainActor (String, UIImage) -> Void) {
        lock.lock()
        let fast = isFastScrolling
        lock.unlock()
        guard !fast else { return }

        let wanted = Set(ids)

        lock.lock()
        for (id, task) in inflight where !wanted.contains(id) {
            task.cancel()
            inflight[id] = nil
        }
        lock.unlock()

        for id in ids {
            if SessionImageCache.shared.thumb(for: id) != nil { continue }
            start(id: id, onImage: onImage)
        }
    }

    func cancelAll() {
        lock.lock()
        let all = inflight
        inflight.removeAll()
        lock.unlock()
        for (_, task) in all {
            task.cancel()
        }
    }

    private func start(id: String, onImage: @escaping @MainActor (String, UIImage) -> Void) {
        lock.lock()
        if inflight[id] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let maxPixel = cellPixelSize
        let scale = self.scale
        let client = self.client

        let task = Task { [weak self] in
            defer {
                self?.lock.lock()
                self?.inflight[id] = nil
                self?.lock.unlock()
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
                await MainActor.run {
                    onImage(id, image)
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        lock.lock()
        inflight[id] = task
        lock.unlock()
    }
}
