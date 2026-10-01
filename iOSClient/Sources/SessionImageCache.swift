import UIKit

final class SessionImageCache {
    static let shared = SessionImageCache()

    private let thumbs = NSCache<NSString, UIImage>()
    private let fulls = NSCache<NSString, UIImage>()

    private init() {
        thumbs.countLimit = 400
        fulls.countLimit = 20
        thumbs.totalCostLimit = 80 * 1024 * 1024
        fulls.totalCostLimit = 120 * 1024 * 1024
    }

    func thumb(for id: String) -> UIImage? {
        thumbs.object(forKey: id as NSString)
    }

    func setThumb(_ image: UIImage, for id: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        thumbs.setObject(image, forKey: id as NSString, cost: cost)
    }

    func full(for id: String) -> UIImage? {
        fulls.object(forKey: id as NSString)
    }

    func setFull(_ image: UIImage, for id: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        fulls.setObject(image, forKey: id as NSString, cost: cost)
    }

    func clear() {
        thumbs.removeAllObjects()
        fulls.removeAllObjects()
    }
}
