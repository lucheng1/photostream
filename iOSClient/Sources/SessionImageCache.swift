import UIKit

/// In-memory thumbs/fulls plus an on-device JPEG disk cache for thumbs.
/// Disk hits avoid re-fetching from the Mac when NSCache / memory pressure drops images.
final class SessionImageCache: @unchecked Sendable {
    static let shared = SessionImageCache()

    private let thumbs = NSCache<NSString, UIImage>()
    private let fulls = NSCache<NSString, UIImage>()
    /// Strong LRU so recently seen thumbs survive NSCache purges while scrolling.
    private var thumbLRU: [String: UIImage] = [:]
    private var thumbOrder: [String] = []
    private let maxStrongThumbs = 350
    private let lock = NSLock()

    private let diskQueue = DispatchQueue(label: "app.photostream.thumbdisk", qos: .utility)
    private let diskDir: URL

    private init() {
        thumbs.countLimit = 800
        thumbs.totalCostLimit = 180 * 1024 * 1024
        fulls.countLimit = 24
        fulls.totalCostLimit = 140 * 1024 * 1024

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = base.appendingPathComponent("PhotoStreamClientThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    func thumb(for id: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let image = thumbLRU[id] {
            touchLocked(id)
            return image
        }
        if let image = thumbs.object(forKey: id as NSString) {
            insertStrongLocked(image, for: id)
            return image
        }
        return nil
    }

    /// Synchronous disk read for cold memory misses (fast on flash; used when configuring cells).
    func thumbFromDisk(for id: String) -> UIImage? {
        if let mem = thumb(for: id) { return mem }
        let url = diskURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        setThumb(image, for: id, persistData: nil)
        return image
    }

    func setThumb(_ image: UIImage, for id: String, persistData: Data? = nil) {
        let cost = max(1, Int(image.size.width * image.size.height))
        lock.lock()
        insertStrongLocked(image, for: id)
        thumbs.setObject(image, forKey: id as NSString, cost: cost)
        lock.unlock()

        if let persistData {
            let url = diskURL(for: id)
            diskQueue.async {
                try? persistData.write(to: url, options: .atomic)
            }
        }
    }

    func full(for id: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return fulls.object(forKey: id as NSString)
    }

    func setFull(_ image: UIImage, for id: String) {
        let cost = max(1, Int(image.size.width * image.size.height))
        lock.lock(); defer { lock.unlock() }
        fulls.setObject(image, forKey: id as NSString, cost: cost)
    }

    func clear() {
        lock.lock()
        thumbLRU.removeAll()
        thumbOrder.removeAll()
        thumbs.removeAllObjects()
        fulls.removeAllObjects()
        lock.unlock()
    }

    private func touchLocked(_ id: String) {
        if let idx = thumbOrder.firstIndex(of: id) {
            thumbOrder.remove(at: idx)
            thumbOrder.append(id)
        }
    }

    private func insertStrongLocked(_ image: UIImage, for id: String) {
        if thumbLRU[id] == nil {
            thumbOrder.append(id)
        } else {
            touchLocked(id)
        }
        thumbLRU[id] = image
        while thumbOrder.count > maxStrongThumbs {
            let evict = thumbOrder.removeFirst()
            thumbLRU[evict] = nil
        }
    }

    private func diskURL(for id: String) -> URL {
        let name = AssetIDCoding.encode(id) + ".jpg"
        return diskDir.appendingPathComponent(name)
    }
}
