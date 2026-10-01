import UIKit

final class SessionImageCache: @unchecked Sendable {
    static let shared = SessionImageCache()

    private let thumbs = NSCache<NSString, UIImage>()
    private let fulls = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    private init() {
        thumbs.countLimit = 400
        fulls.countLimit = 20
        thumbs.totalCostLimit = 80 * 1024 * 1024
        fulls.totalCostLimit = 120 * 1024 * 1024
    }

    func thumb(for id: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return thumbs.object(forKey: id as NSString)
    }

    func setThumb(_ image: UIImage, for id: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        lock.lock(); defer { lock.unlock() }
        thumbs.setObject(image, forKey: id as NSString, cost: cost)
    }

    func full(for id: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return fulls.object(forKey: id as NSString)
    }

    func setFull(_ image: UIImage, for id: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        lock.lock(); defer { lock.unlock() }
        fulls.setObject(image, forKey: id as NSString, cost: cost)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        thumbs.removeAllObjects()
        fulls.removeAllObjects()
    }
}
