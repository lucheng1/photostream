import Foundation
import Photos
import PhotoStreamShared

@MainActor
final class PhotoLibraryService {
    private(set) var assets: [PHAsset] = []
    private var idIndex: [String: PHAsset] = [:]

    var count: Int { assets.count }

    func requestAuthorization() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return true
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
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
