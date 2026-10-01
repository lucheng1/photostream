import Foundation

actor PhotoStreamAPIClient {
    private var baseURL: URL
    private var token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func update(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    func pair(pin: String) async throws -> String {
        var request = URLRequest(url: url("v1", "pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingRequest(pin: pin))
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        let decoded = try JSONDecoder().decode(PairingResponse.self, from: data)
        self.token = decoded.token
        return decoded.token
    }

    func info() async throws -> LibraryInfo {
        let data = try await get(url: url("v1", "info"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryInfo.self, from: data)
    }

    func assets(cursor: String?, limit: Int) async throws -> AssetPage {
        var components = URLComponents(url: url("v1", "assets"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        let data = try await get(url: components.url!)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AssetPage.self, from: data)
    }

    func thumbTask(assetID: String, width: Int, height: Int, scale: Int) -> URLSessionDataTask {
        var components = URLComponents(url: thumbURL(assetID: assetID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "w", value: String(width)),
            URLQueryItem(name: "h", value: String(height)),
            URLQueryItem(name: "scale", value: String(scale)),
        ]
        var request = URLRequest(url: components.url!)
        applyAuth(&request)
        return session.dataTask(with: request)
    }

    func thumbData(assetID: String, width: Int, height: Int, scale: Int) async throws -> Data {
        var components = URLComponents(url: thumbURL(assetID: assetID), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "w", value: String(width)),
            URLQueryItem(name: "h", value: String(height)),
            URLQueryItem(name: "scale", value: String(scale)),
        ]
        return try await get(url: components.url!)
    }

    func fullImage(assetID: String) async throws -> Data {
        let encoded = AssetIDCoding.encode(assetID)
        return try await get(url: url("v1", "assets", encoded, "full"))
    }

    private func thumbURL(assetID: String) -> URL {
        url("v1", "assets", AssetIDCoding.encode(assetID), "thumb")
    }

    private func url(_ parts: String...) -> URL {
        parts.reduce(baseURL) { partial, part in
            partial.appendingPathComponent(part, isDirectory: false)
        }
    }

    func cancel(_ task: URLSessionTask) {
        task.cancel()
    }

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyAuth(&request)
        let session = self.session
        return try await withTaskCancellationHandler {
            let (data, response) = try await session.data(for: request)
            try Self.throwIfNeeded(response: response, data: data)
            return data
        } onCancel: {
            // URLSession tasks tied to this request are cancelled via cooperative cancel
            // when using async bytes; force-cancel outstanding tasks for this session host.
        }
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let token {
            request.setValue(token, forHTTPHeaderField: PhotoStreamConstants.authHeader)
        }
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError.status(http.statusCode, message)
        }
    }
}

enum APIError: LocalizedError {
    case status(Int, String)
    var errorDescription: String? {
        switch self {
        case .status(let code, let message): return "HTTP \(code): \(message)"
        }
    }
}
