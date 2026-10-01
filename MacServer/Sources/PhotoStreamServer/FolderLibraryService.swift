import Foundation
import ImageIO
import PhotoStreamShared
import UniformTypeIdentifiers

struct FolderAsset: Sendable {
    /// Stable id: `folder:` + path relative to the configured root.
    let id: String
    let fileURL: URL
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Ephemeral recursive folder index. Rebuilt on every launch / reload; never persisted.
@MainActor
final class FolderLibraryService {
    static let defaultsKey = "photostream.folderPath"

    private(set) var rootURL: URL?
    private(set) var assets: [FolderAsset] = []
    private var idIndex: [String: FolderAsset] = [:]

    var count: Int { assets.count }
    var isConfigured: Bool { rootURL != nil }
    var displayName: String {
        guard let rootURL else { return "No Folder" }
        return rootURL.lastPathComponent
    }

    init() {
        // Never restore a prior in-memory index — only the path preference.
        if let path = UserDefaults.standard.string(forKey: Self.defaultsKey), !path.isEmpty {
            rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func setFolder(_ url: URL?) {
        rootURL = url
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        clearIndex()
    }

    func clearIndex() {
        assets = []
        idIndex = [:]
    }

    /// Rescan the configured folder. Safe to call on every server start.
    func reload() async {
        clearIndex()
        guard let root = rootURL else { return }
        let rootPath = root.path
        let scanned = await Task.detached(priority: .userInitiated) {
            FolderScanner.scan(rootPath: rootPath)
        }.value
        assets = scanned
        idIndex = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
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
        let items = slice.map { asset in
            AssetSummary(
                id: asset.id,
                createdAt: asset.createdAt,
                mediaType: .photo,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: false
            )
        }
        let next = end < assets.count ? String(end) : nil
        return AssetPage(items: items, nextCursor: next, totalCount: assets.count)
    }

    func timeline() -> TimelineResponse {
        TimelineBuilder.build(dates: assets.map(\.createdAt))
    }

    func asset(id: String) -> FolderAsset? {
        idIndex[id]
    }
}

enum FolderScanner {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp",
    ]

    static func scan(rootPath: String) -> [FolderAsset] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [FolderAsset] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let relative = fileURL.path.replacingOccurrences(of: rootPath, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let id = "folder:" + relative

            let meta = imageMeta(at: fileURL)
            let created = meta.date
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast

            results.append(
                FolderAsset(
                    id: id,
                    fileURL: fileURL,
                    createdAt: created,
                    pixelWidth: meta.width,
                    pixelHeight: meta.height
                )
            )
        }

        results.sort { $0.createdAt > $1.createdAt }
        return results
    }

    private static func imageMeta(at url: URL) -> (width: Int, height: Int, date: Date?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return (0, 0, nil)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        var date: Date?
        if let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = parseEXIFDate(raw)
        }
        if date == nil,
           let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String {
            date = parseEXIFDate(raw)
        }
        return (width, height, date)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func parseEXIFDate(_ string: String) -> Date? {
        exifFormatter.date(from: string)
    }
}
