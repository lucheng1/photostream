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
        let calendar = Calendar.current
        var buckets: [TimelineBucket] = []
        var years: [TimelineYear] = []

        var currentYear: Int?
        var currentMonth: Int?
        var bucketStart = 0
        var bucketCount = 0
        var yearStart = 0
        var yearCount = 0

        func flushBucket() {
            guard let y = currentYear, let m = currentMonth, bucketCount > 0 else { return }
            buckets.append(TimelineBucket(year: y, month: m, startIndex: bucketStart, count: bucketCount))
        }
        func flushYear() {
            guard let y = currentYear, yearCount > 0 else { return }
            years.append(TimelineYear(year: y, startIndex: yearStart, count: yearCount))
        }

        for (index, asset) in assets.enumerated() {
            let y: Int
            let m: Int
            if let date = asset.creationDate {
                y = calendar.component(.year, from: date)
                m = calendar.component(.month, from: date)
            } else {
                // Sentinel for Amazon-style "No Date" rail label.
                y = 0
                m = 0
            }

            if currentYear == nil {
                currentYear = y
                currentMonth = m
                bucketStart = index
                yearStart = index
            }

            if y != currentYear {
                flushBucket()
                flushYear()
                currentYear = y
                currentMonth = m
                bucketStart = index
                bucketCount = 0
                yearStart = index
                yearCount = 0
            } else if m != currentMonth {
                flushBucket()
                currentMonth = m
                bucketStart = index
                bucketCount = 0
            }

            bucketCount += 1
            yearCount += 1
        }
        flushBucket()
        flushYear()

        return TimelineResponse(buckets: buckets, years: years, totalCount: assets.count)
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
            isFavorite: asset.isFavorite
        )
    }
}
