import AVFoundation
import Foundation
import Photos
import PhotoStreamShared

enum VideoExportError: Error {
    case noResource
    case exportFailed
}

/// Resolve videos to on-disk files and serve them with HTTP byte-range support.
enum VideoExporter {
    private static let cache = VideoExportCache()

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoStreamVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Prefer a readable file URL quickly (local library / folder). Export only when needed.
    static func fileURL(for asset: PHAsset) async throws -> (url: URL, contentType: String) {
        guard asset.mediaType == .video else { throw VideoExportError.noResource }

        if let cached = await cache.url(for: asset.localIdentifier),
           FileManager.default.fileExists(atPath: cached.path) {
            return (cached, mimeType(forExtension: cached.pathExtension.lowercased()))
        }

        if let direct = try await requestDirectFileURL(for: asset) {
            let streamable = try await prepareForStreaming(sourceURL: direct)
            return (streamable, mimeType(forExtension: streamable.pathExtension.lowercased()))
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let resource =
            resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .pairedVideo })
        guard let resource else { throw VideoExportError.noResource }

        let ext = resource.originalFilename.split(separator: ".").last.map(String.init)?.lowercased() ?? "mov"
        let safe = AssetIDCoding.encode(asset.localIdentifier)
        let out = cacheDirectory.appendingPathComponent(safe).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: out.path) {
            await cache.set(out, for: asset.localIdentifier)
            return (out, mimeType(forExtension: ext))
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: out, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        await cache.set(out, for: asset.localIdentifier)
        let streamable = try await prepareForStreaming(sourceURL: out)
        return (streamable, mimeType(forExtension: streamable.pathExtension.lowercased()))
    }

    /// Ensure `moov` is near the start so HTTP progressive playback can begin
    /// without reading the whole file (iPhone camera MOVs keep moov at the end).
    static func prepareForStreaming(sourceURL: URL) async throws -> URL {
        if moovIsNearStart(sourceURL) { return sourceURL }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(sourceURL.path)|\(size)|\(mtime)"
        let digest = AssetIDCoding.encode(key)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let out = cacheDirectory
            .appendingPathComponent("faststart-\(digest)")
            .appendingPathExtension(ext)

        if FileManager.default.fileExists(atPath: out.path) {
            return out
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            return sourceURL
        }

        let fileType: AVFileType = (ext == "mp4" || ext == "m4v") ? .mp4 : .mov
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        if session.status == .completed, FileManager.default.fileExists(atPath: out.path) {
            return out
        }
        try? FileManager.default.removeItem(at: out)
        return sourceURL
    }

    private static func moovIsNearStart(_ url: URL, probeBytes: Int = 512 * 1024) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: probeBytes)) ?? Data()
        return data.range(of: Data("moov".utf8)) != nil
    }

    private static func requestDirectFileURL(for phAsset: PHAsset) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if let urlAsset = avAsset as? AVURLAsset,
                   FileManager.default.isReadableFile(atPath: urlAsset.url.path) {
                    continuation.resume(returning: urlAsset.url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    static func thumbnailJPEG(fileURL: URL, maxPixel: Int) throws -> Data {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
        return try ImageEncoder.jpegDataPublic(from: cg, quality: 0.67, maxPixel: maxPixel)
    }

    static func duration(fileURL: URL) -> Double {
        let asset = AVURLAsset(url: fileURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : 0
    }

    static func dimensions(fileURL: URL) -> (Int, Int) {
        let asset = AVURLAsset(url: fileURL)
        guard let track = asset.tracks(withMediaType: .video).first else { return (0, 0) }
        let size = track.naturalSize.applying(track.preferredTransform)
        return (Int(abs(size.width)), Int(abs(size.height)))
    }
}

actor VideoExportCache {
    private var urls: [String: URL] = [:]

    func url(for id: String) -> URL? { urls[id] }

    func set(_ url: URL, for id: String) {
        urls[id] = url
    }
}

enum ByteRange {
    case full
    case partial(start: Int, end: Int) // inclusive end

    static func parse(_ header: String?, fileSize: Int) -> ByteRange? {
        guard fileSize > 0 else { return .full }
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count)
        // Support a single range only (what AVPlayer sends).
        let part = spec.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? String(spec)
        // Must keep empty trailing/leading pieces so `bytes=0-` and `bytes=-500` parse.
        let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard bounds.count == 2 else { return nil }

        if bounds[0].isEmpty {
            // suffix: bytes=-500
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            let start = max(0, fileSize - suffix)
            return .partial(start: start, end: fileSize - 1)
        }

        guard let start = Int(bounds[0]), start >= 0, start < fileSize else { return nil }
        if bounds[1].isEmpty {
            return .partial(start: start, end: fileSize - 1)
        }
        guard let end = Int(bounds[1]), end >= start else { return nil }
        return .partial(start: start, end: min(end, fileSize - 1))
    }
}

enum VideoHTTP {
    /// Build a 200/206 response backed by a file region (streamed by HTTPServer).
    /// Honor the exact byte range AVPlayer asked for — truncating open-ended
    /// `bytes=0-` breaks iPhone MOVs that keep `moov` at the end of the file.
    static func response(
        fileURL: URL,
        contentType: String,
        rangeHeader: String?,
        includeBody: Bool
    ) -> HTTPResponse {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let fileSize = attrs[.size] as? NSNumber else {
                return .json(APIErrorBody(error: "stat failed"), status: 500)
            }
            let size = fileSize.intValue

            guard size > 0 else {
                return HTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": contentType,
                        "Accept-Ranges": "bytes",
                        "Content-Length": "0",
                        "Cache-Control": "private, max-age=3600",
                    ],
                    body: Data()
                )
            }

            // No Range header → full 200 (streamed). Never emit an unsolicited 206;
            // AVPlayer treats that as a hard failure ("unknown error").
            guard let rangeHeader, !rangeHeader.isEmpty else {
                var headers: [String: String] = [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "private, max-age=3600",
                ]
                let body: HTTPBody
                if includeBody {
                    body = .file(url: fileURL, offset: 0, length: size)
                } else {
                    headers["Content-Length"] = String(size)
                    body = .data(Data())
                }
                return HTTPResponse(status: 200, headers: headers, body: body)
            }

            guard let range = ByteRange.parse(rangeHeader, fileSize: size) else {
                return HTTPResponse(
                    status: 416,
                    headers: [
                        "Content-Range": "bytes */\(size)",
                        "Content-Type": "text/plain",
                        "Content-Length": "0",
                    ],
                    body: Data()
                )
            }

            let start: Int
            let end: Int
            switch range {
            case .full:
                start = 0
                end = size - 1
            case .partial(let s, let e):
                start = s
                end = e
            }

            let length = end - start + 1

            var headers: [String: String] = [
                "Content-Type": contentType,
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/\(size)",
                "Cache-Control": "private, max-age=3600",
            ]

            let body: HTTPBody
            if includeBody {
                body = .file(url: fileURL, offset: start, length: length)
            } else {
                headers["Content-Length"] = String(length)
                body = .data(Data())
            }

            return HTTPResponse(status: 206, headers: headers, body: body)
        } catch {
            return .json(APIErrorBody(error: error.localizedDescription), status: 500)
        }
    }
}
