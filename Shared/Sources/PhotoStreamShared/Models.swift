import Foundation

public enum PhotoStreamConstants {
    /// NetService publish type (trailing dot).
    public static let bonjourType = "_photostream._tcp."
    /// NWBrowser browse type (no trailing dot).
    public static let bonjourBrowserType = "_photostream._tcp"
    public static let bonjourDomain = "local."
    public static let apiVersion = "1"
    public static let defaultPort: UInt16 = 8787
    public static let authHeader = "X-PhotoStream-Token"
}

public struct LibraryInfo: Codable, Sendable {
    public var name: String
    public var assetCount: Int
    public var serverVersion: String
    public var hostName: String

    public init(name: String, assetCount: Int, serverVersion: String, hostName: String) {
        self.name = name
        self.assetCount = assetCount
        self.serverVersion = serverVersion
        self.hostName = hostName
    }
}

public enum MediaKind: String, Codable, Sendable {
    case photo
    case video
    case other
}

public struct AssetSummary: Codable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var mediaType: MediaKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isFavorite: Bool

    public init(
        id: String,
        createdAt: Date,
        mediaType: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
    }
}

public struct AssetPage: Codable, Sendable {
    public var items: [AssetSummary]
    public var nextCursor: String?
    public var totalCount: Int

    public init(items: [AssetSummary], nextCursor: String?, totalCount: Int) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

public struct PairingChallenge: Codable, Sendable {
    public var pin: String
    public var port: Int
    public var serviceName: String

    public init(pin: String, port: Int, serviceName: String) {
        self.pin = pin
        self.port = port
        self.serviceName = serviceName
    }
}

public struct PairingRequest: Codable, Sendable {
    public var pin: String

    public init(pin: String) {
        self.pin = pin
    }
}

public struct PairingResponse: Codable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct APIErrorBody: Codable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}
