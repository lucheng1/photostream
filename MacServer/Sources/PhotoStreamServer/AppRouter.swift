import Foundation
import PhotoStreamShared

final class AppRouter: @unchecked Sendable {
    let library: PhotoLibraryService
    let folder: FolderLibraryService
    let auth: AuthStore
    let hostName: String
    let port: UInt16

    init(
        library: PhotoLibraryService,
        folder: FolderLibraryService,
        auth: AuthStore,
        hostName: String,
        port: UInt16
    ) {
        self.library = library
        self.folder = folder
        self.auth = auth
        self.hostName = hostName
        self.port = port
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        let method = request.method.uppercased()

        if method == "GET" && path == "/health" {
            return .text("ok")
        }

        if method == "POST" && path == "/v1/pair" {
            return await pair(request)
        }

        let needsAuth = path.hasPrefix("/v1/")
        if needsAuth && path != "/v1/pair" {
            let ok = await auth.isAuthorized(request.token)
            if !ok {
                return .json(APIErrorBody(error: "unauthorized"), status: 401)
            }
        }

        let mode = await auth.mode(for: request.token) ?? .photos

        switch (method, path) {
        case ("GET", "/v1/info"):
            return await info(mode: mode)
        case ("GET", "/v1/assets"):
            return await assets(request, mode: mode)
        case ("GET", "/v1/timeline"):
            return await timeline(mode: mode)
        default:
            if method == "GET", path.hasPrefix("/v1/assets/"), path.hasSuffix("/thumb") {
                return await thumb(request, path: path, mode: mode)
            }
            if method == "GET", path.hasPrefix("/v1/assets/"), path.hasSuffix("/full") {
                return await full(request, path: path, mode: mode)
            }
            if (method == "GET" || method == "HEAD"),
               path.hasPrefix("/v1/assets/"),
               path.hasSuffix("/video") {
                return await video(request, path: path, mode: mode, includeBody: method == "GET")
            }
            return .json(APIErrorBody(error: "not found"), status: 404)
        }
    }

    private func pair(_ request: HTTPRequest) async -> HTTPResponse {
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(PairingRequest.self, from: request.body) else {
            return .json(APIErrorBody(error: "invalid body"), status: 400)
        }
        let folderOK = await MainActor.run { folder.isConfigured }
        guard let result = await auth.pair(pin: body.pin, folderConfigured: folderOK) else {
            let hint = body.pin.hasSuffix("9") && body.pin.count == 5
                ? "folder not configured on Mac"
                : "invalid pin"
            return .json(APIErrorBody(error: hint), status: 401)
        }
        return .json(PairingResponse(token: result.token, mode: result.mode.rawValue))
    }

    private func info(mode: StreamMode) async -> HTTPResponse {
        switch mode {
        case .photos:
            let count = await MainActor.run { library.count }
            return .json(
                LibraryInfo(
                    name: "Mac Photos",
                    assetCount: count,
                    serverVersion: "0.1.0",
                    hostName: hostName
                )
            )
        case .folder:
            let (count, name) = await MainActor.run { (folder.count, folder.displayName) }
            return .json(
                LibraryInfo(
                    name: "Folder · \(name)",
                    assetCount: count,
                    serverVersion: "0.1.0",
                    hostName: hostName
                )
            )
        }
    }

    private func assets(_ request: HTTPRequest, mode: StreamMode) async -> HTTPResponse {
        let limit = Int(request.query["limit"] ?? "10") ?? 10
        let cursor = request.query["cursor"]
        let page = await MainActor.run { () -> AssetPage in
            switch mode {
            case .photos: return library.page(cursor: cursor, limit: limit)
            case .folder: return folder.page(cursor: cursor, limit: limit)
            }
        }
        return .json(page)
    }

    private func timeline(mode: StreamMode) async -> HTTPResponse {
        let response = await MainActor.run { () -> TimelineResponse in
            switch mode {
            case .photos: return library.timeline()
            case .folder: return folder.timeline()
            }
        }
        return .json(response)
    }

    private func assetID(from path: String, suffix: String) -> String? {
        let prefix = "/v1/assets/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let encoded = String(path[start..<end])
        return AssetIDCoding.decode(encoded)
    }

    private func thumb(_ request: HTTPRequest, path: String, mode: StreamMode) async -> HTTPResponse {
        guard let id = assetID(from: path, suffix: "/thumb") else {
            return .json(APIErrorBody(error: "bad id"), status: 400)
        }
        let w = Int(request.query["w"] ?? "200") ?? 200
        let h = Int(request.query["h"] ?? "200") ?? 200
        let scale = Int(request.query["scale"] ?? "3") ?? 3
        let maxPixel = max(w, h) * max(1, min(scale, 3))

        switch mode {
        case .photos:
            let cacheKey = ThumbDiskCache.shared.key(assetID: id, maxPixel: maxPixel)
            if let cached = ThumbDiskCache.shared.data(forKey: cacheKey) {
                return .jpeg(cached)
            }
            guard let asset = await MainActor.run(body: { library.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            do {
                let data = try await ImageEncoder.jpegThumbnail(for: asset, maxPixel: maxPixel)
                ThumbDiskCache.shared.store(data, forKey: cacheKey)
                return .jpeg(data)
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }

        case .folder:
            guard let asset = await MainActor.run(body: { folder.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            do {
                let data: Data
                if asset.mediaType == .video {
                    data = try VideoExporter.thumbnailJPEG(fileURL: asset.fileURL, maxPixel: maxPixel)
                } else {
                    data = try ImageEncoder.jpegThumbnail(fileURL: asset.fileURL, maxPixel: maxPixel)
                }
                return .jpeg(data)
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }
        }
    }

    private func full(_ request: HTTPRequest, path: String, mode: StreamMode) async -> HTTPResponse {
        guard let id = assetID(from: path, suffix: "/full") else {
            return .json(APIErrorBody(error: "bad id"), status: 400)
        }
        switch mode {
        case .photos:
            guard let asset = await MainActor.run(body: { library.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            do {
                let data = try await ImageEncoder.jpegFull(for: asset)
                return .jpeg(data)
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }
        case .folder:
            guard let asset = await MainActor.run(body: { folder.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            do {
                let data: Data
                if asset.mediaType == .video {
                    // Poster frame for swipe/preview; playback uses /video.
                    data = try VideoExporter.thumbnailJPEG(fileURL: asset.fileURL, maxPixel: 1920)
                } else {
                    data = try ImageEncoder.jpegFull(fileURL: asset.fileURL)
                }
                return .jpeg(data)
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }
        }
    }

    private func video(
        _ request: HTTPRequest,
        path: String,
        mode: StreamMode,
        includeBody: Bool
    ) async -> HTTPResponse {
        guard let id = assetID(from: path, suffix: "/video") else {
            return .json(APIErrorBody(error: "bad id"), status: 400)
        }
        switch mode {
        case .photos:
            guard let asset = await MainActor.run(body: { library.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            guard asset.mediaType == .video else {
                return .json(APIErrorBody(error: "not a video"), status: 400)
            }
            do {
                let (sourceURL, _) = try await VideoExporter.fileURL(for: asset)
                let fileURL = try await Self.videoFile(
                    sourceURL: sourceURL,
                    quality: request.query["quality"]
                )
                let contentType = VideoExporter.mimeType(
                    forExtension: fileURL.pathExtension.lowercased()
                )
                return VideoHTTP.response(
                    fileURL: fileURL,
                    contentType: contentType,
                    rangeHeader: request.rangeHeader,
                    includeBody: includeBody
                )
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }
        case .folder:
            guard let asset = await MainActor.run(body: { folder.asset(id: id) }) else {
                return .json(APIErrorBody(error: "not found"), status: 404)
            }
            guard asset.mediaType == .video else {
                return .json(APIErrorBody(error: "not a video"), status: 400)
            }
            do {
                let prepared = try await VideoExporter.prepareForStreaming(sourceURL: asset.fileURL)
                let fileURL = try await Self.videoFile(
                    sourceURL: prepared,
                    quality: request.query["quality"]
                )
                let contentType = VideoExporter.mimeType(
                    forExtension: fileURL.pathExtension.lowercased()
                )
                return VideoHTTP.response(
                    fileURL: fileURL,
                    contentType: contentType,
                    rangeHeader: request.rangeHeader,
                    includeBody: includeBody
                )
            } catch {
                return .json(APIErrorBody(error: error.localizedDescription), status: 500)
            }
        }
    }

    /// `quality=mobile` → ≤1080p ~5.5 Mbps proxy for cellular / 5G streaming.
    private static func videoFile(sourceURL: URL, quality: String?) async throws -> URL {
        let normalized = quality?.lowercased()
        if normalized == "mobile" || normalized == "5g" || normalized == "cellular" {
            return try await VideoMobileProxy.fileURL(for: sourceURL)
        }
        return sourceURL
    }
}
