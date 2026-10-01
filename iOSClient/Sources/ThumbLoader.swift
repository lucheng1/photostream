import UIKit

struct ThumbRequest: Sendable {
    let id: String
    /// Longest edge in points (column width × max(1, aspect)).
    let pointSize: CGFloat
}

/// Velocity-gated thumbnail loader with a bounded parallel worker pool.
final class ThumbLoader: @unchecked Sendable {
    private let client: PhotoStreamAPIClient
    private let queue = DispatchQueue(label: "app.photostream.thumbloader")
    private var inflight: [String: Task<Void, Never>] = [:]
    private var pendingOrder: [String] = []
    private var pendingCallbacks: [String: @Sendable @MainActor (String, UIImage) -> Void] = [:]
    private var pendingSizes: [String: CGFloat] = [:]
    private var isFastScrolling = false
    private var settleWorkItem: DispatchWorkItem?
    private var activeWorkers = 0

    /// Parallel HTTP thumb fetches (LAN can handle a bit more than Wi‑Fi defaults).
    private let maxWorkers = 20

    private var scale: Int = 3

    init(client: PhotoStreamAPIClient) {
        self.client = client
    }

    func setScale(_ scale: Int) {
        queue.async {
            self.scale = min(max(scale, 1), 3)
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

    /// Clears velocity-gating and immediately runs a visible-thumb load (no settle delay).
    func resumeAndLoad(items: [ThumbRequest], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        queue.async {
            self.isFastScrolling = false
            self.settleWorkItem?.cancel()
            self.settleWorkItem = nil
            self.loadVisibleLocked(items: items, onImage: onImage)
        }
    }

    func scheduleSettle(items: [ThumbRequest], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        queue.async {
            self.settleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.loadVisible(items: items, onImage: onImage)
            }
            self.settleWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
    }

    func loadVisible(items: [ThumbRequest], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        queue.async {
            self.loadVisibleLocked(items: items, onImage: onImage)
        }
    }

    private func loadVisibleLocked(items: [ThumbRequest], onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        guard !self.isFastScrolling else { return }
        let wanted = Set(items.map(\.id))

        for (id, task) in self.inflight where !wanted.contains(id) {
            task.cancel()
            self.inflight[id] = nil
        }
        self.pendingOrder.removeAll { !wanted.contains($0) }
        for id in self.pendingCallbacks.keys where !wanted.contains(id) {
            self.pendingCallbacks[id] = nil
            self.pendingSizes[id] = nil
        }

        for item in items {
            self.pendingSizes[item.id] = item.pointSize
            if SessionImageCache.shared.thumb(for: item.id) != nil { continue }
            if let disk = SessionImageCache.shared.thumbFromDisk(for: item.id) {
                let cb = onImage
                Task { @MainActor in cb(item.id, disk) }
                continue
            }
            if self.inflight[item.id] != nil { continue }
            if self.pendingCallbacks[item.id] != nil {
                self.pendingCallbacks[item.id] = onImage
                continue
            }
            self.pendingCallbacks[item.id] = onImage
            self.pendingOrder.append(item.id)
        }
        self.pumpLocked()
    }

    func cancelAll() {
        queue.async { self.cancelAllLocked() }
    }

    private func cancelAllLocked() {
        for (_, task) in inflight {
            task.cancel()
        }
        inflight.removeAll()
        pendingOrder.removeAll()
        pendingCallbacks.removeAll()
        pendingSizes.removeAll()
        activeWorkers = 0
    }

    private func pumpLocked() {
        while activeWorkers < maxWorkers, !pendingOrder.isEmpty, !isFastScrolling {
            let id = pendingOrder.removeFirst()
            guard let onImage = pendingCallbacks.removeValue(forKey: id) else { continue }
            if SessionImageCache.shared.thumb(for: id) != nil { continue }
            if inflight[id] != nil { continue }
            startLocked(id: id, onImage: onImage)
        }
    }

    private func startLocked(id: String, onImage: @escaping @Sendable @MainActor (String, UIImage) -> Void) {
        // Midway between the speed-tuned @2x and the original full-retina request.
        let deviceScale = min(max(self.scale, 1), 3)
        let effectiveScale = (2.0 + Double(deviceScale)) / 2.0
        let pointSize = pendingSizes[id] ?? 200
        let side = max(1, Int(round(Double(pointSize) * effectiveScale)))
        let client = self.client
        activeWorkers += 1

        let task = Task { [weak self] in
            defer {
                self?.queue.async {
                    self?.inflight[id] = nil
                    self?.activeWorkers = max(0, (self?.activeWorkers ?? 1) - 1)
                    self?.pumpLocked()
                }
            }
            do {
                let data = try await client.thumbData(
                    assetID: id,
                    width: side,
                    height: side,
                    scale: 1
                )
                try Task.checkCancellation()
                guard let image = ImageDownsampler.downsample(
                    data: data,
                    maxPixel: CGFloat(side)
                ) else { return }
                SessionImageCache.shared.setThumb(image, for: id, persistData: data)
                await onImage(id, image)
            } catch {
                return
            }
        }
        inflight[id] = task
    }
}
