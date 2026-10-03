import Foundation
import Photos
import PhotoStreamShared

@MainActor
final class PhotoLibraryService {
    private(set) var assets: [PHAsset] = []
    private var idIndex: [String: PHAsset] = [:]

    var count: Int { assets.count }

    func requestAuthorization(timeoutSeconds: Double = 45) async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return true
        }
        if current == .denied || current == .restricted {
            return false
        }

        // Fire-and-forget the system prompt. Awaiting the async Photos API can hang
        // forever for ad-hoc menu-bar apps after a re-sign (TCC sheet never completes).
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                return true
            }
            if status == .denied || status == .restricted {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let final = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return final == .authorized || final == .limited
    }

    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false

        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        var index: [String: PHAsset] = [:]
        index.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            list.append(asset)
            index[asset.localIdentifier] = asset
        }

        assets = list
        idIndex = index
    }

    func page(cursor: String?, limit: Int) -> AssetPage {
        let start: Int
        if let cursor, let value = Int(cursor) {
            start = max(0, value)
        } else {
            start = 0
        }
        let end = min(assets.count, start + max(1, min(limit, 200)))
        let slice = assets[start..<end]
        let items = slice.map(Self.summary(for:))
        let next = end < assets.count ? String(end) : nil
        return AssetPage(items: items, nextCursor: next, totalCount: assets.count)
    }

    func timeline() -> TimelineResponse {
        TimelineBuilder.build(dates: assets.map(\.creationDate))
    }

    func asset(id: String) -> PHAsset? {
        idIndex[id]
    }

    static func summary(for asset: PHAsset) -> AssetSummary {
        let kind: MediaKind
        switch asset.mediaType {
        case .image: kind = .photo
        case .video: kind = .video
        default: kind = .other
        }
        return AssetSummary(
            id: asset.localIdentifier,
            createdAt: asset.creationDate ?? .distantPast,
            mediaType: kind,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            duration: kind == .video ? asset.duration : 0
        )
    }
}
