import Foundation
import PhotoStreamShared

/// In-memory + on-disk JPEG thumb cache for Photo Library assets only.
final class ThumbDiskCache: @unchecked Sendable {
    static let shared = ThumbDiskCache()

    private let memory = NSCache<NSString, NSData>()
    private let ioQueue = DispatchQueue(label: "app.photostream.thumbcache", attributes: .concurrent)
    private let dir: URL

    private init() {
        memory.countLimit = 2000
        memory.totalCostLimit = 256 * 1024 * 1024
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("PhotoStreamThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func key(assetID: String, maxPixel: Int) -> String {
        "\(assetID)#\(maxPixel)"
    }

    func data(forKey key: String) -> Data? {
        // Folder assets are never cached on disk/memory across sessions.
        if key.hasPrefix("folder:") { return nil }
        if let hit = memory.object(forKey: key as NSString) {
            return hit as Data
        }
        let url = dir.appendingPathComponent(fileName(for: key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func store(_ data: Data, forKey key: String) {
        if key.hasPrefix("folder:") { return }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        let url = dir.appendingPathComponent(fileName(for: key))
        ioQueue.async(flags: .barrier) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func fileName(for key: String) -> String {
        AssetIDCoding.encode(key) + ".jpg"
    }
}
