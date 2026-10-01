import Foundation
import PhotoStreamShared

final class AppRouter: @unchecked Sendable {
    let library: PhotoLibraryService
    let auth: AuthStore
    let hostName: String
    let port: UInt16

    init(library: PhotoLibraryService, auth: AuthStore, hostName: String, port: UInt16) {
        self.library = library
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

        // Public info for discovery UI (count only after auth for privacy? Plan says GET /v1/info — require auth)
        let needsAuth = path.hasPrefix("/v1/")
        if needsAuth && path != "/v1/pair" {
            let ok = await auth.isAuthorized(request.token)
            if !ok {
                return .json(APIErrorBody(error: "unauthorized"), status: 401)
            }
        }

        switch (method, path) {
        case ("GET", "/v1/info"):
            return await info()
        case ("GET", "/v1/assets"):
            return await assets(request)
        case ("GET", "/v1/timeline"):
            return await timeline()
        default:
            if method == "GET", path.hasPrefix("/v1/assets/"), path.hasSuffix("/thumb") {
                return await thumb(request, path: path)
            }
            if method == "GET", path.hasPrefix("/v1/assets/"), path.hasSuffix("/full") {
                return await full(request, path: path)
            }
            return .json(APIErrorBody(error: "not found"), status: 404)
        }
    }

    private func pair(_ request: HTTPRequest) async -> HTTPResponse {
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(PairingRequest.self, from: request.body) else {
            return .json(APIErrorBody(error: "invalid body"), status: 400)
        }
        guard let token = await auth.pair(pin: body.pin) else {
            return .json(APIErrorBody(error: "invalid pin"), status: 401)
        }
        return .json(PairingResponse(token: token))
    }

    private func info() async -> HTTPResponse {
        let count = await MainActor.run { library.count }
        return .json(
            LibraryInfo(
                name: "Mac Photos",
                assetCount: count,
                serverVersion: "0.1.0",
                hostName: hostName
            )
        )
    }

    private func assets(_ request: HTTPRequest) async -> HTTPResponse {
        let limit = Int(request.query["limit"] ?? "10") ?? 10
        let cursor = request.query["cursor"]
        let page = await MainActor.run { library.page(cursor: cursor, limit: limit) }
        return .json(page)
    }

    private func timeline() async -> HTTPResponse {
        let response = await MainActor.run { library.timeline() }
        return .json(response)
    }

    private func assetID(from path: String, suffix: String) -> String? {
        // /v1/assets/{base64url(localIdentifier)}/thumb
        let prefix = "/v1/assets/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let encoded = String(path[start..<end])
        return AssetIDCoding.decode(encoded)
    }

    private func thumb(_ request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let id = assetID(from: path, suffix: "/thumb") else {
            return .json(APIErrorBody(error: "bad id"), status: 400)
        }
        let w = Int(request.query["w"] ?? "200") ?? 200
        let h = Int(request.query["h"] ?? "200") ?? 200
        let scale = Int(request.query["scale"] ?? "3") ?? 3
        // Allow up to @3; clients may send pre-multiplied pixel size with scale=1.
        let maxPixel = max(w, h) * max(1, min(scale, 3))
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
    }

    private func full(_ request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let id = assetID(from: path, suffix: "/full") else {
            return .json(APIErrorBody(error: "bad id"), status: 400)
        }
        guard let asset = await MainActor.run(body: { library.asset(id: id) }) else {
            return .json(APIErrorBody(error: "not found"), status: 404)
        }
        do {
            let data = try await ImageEncoder.jpegFull(for: asset)
            return .jpeg(data)
        } catch {
            return .json(APIErrorBody(error: error.localizedDescription), status: 500)
        }
    }
}
