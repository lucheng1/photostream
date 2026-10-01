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
    /// Duration in seconds for videos; 0 for photos.
    public var duration: Double

    public init(
        id: String,
        createdAt: Date,
        mediaType: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        duration: Double = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.duration = duration
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
    /// `photos` (System Photo Library) or `folder` (configured Mac folder).
    public var mode: String

    public init(token: String, mode: String = "photos") {
        self.token = token
        self.mode = mode
    }
}

public enum StreamMode: String, Codable, Sendable {
    case photos
    case folder
}

public struct TimelineBucket: Codable, Sendable, Identifiable {
    public var id: String { "\(year)-\(month)" }
    public var year: Int
    public var month: Int
    public var startIndex: Int
    public var count: Int

    public init(year: Int, month: Int, startIndex: Int, count: Int) {
        self.year = year
        self.month = month
        self.startIndex = startIndex
        self.count = count
    }
}

public struct TimelineYear: Codable, Sendable, Identifiable {
    public var id: Int { year }
    public var year: Int
    public var startIndex: Int
    public var count: Int

    public init(year: Int, startIndex: Int, count: Int) {
        self.year = year
        self.startIndex = startIndex
        self.count = count
    }
}

public struct TimelineResponse: Codable, Sendable {
    public var buckets: [TimelineBucket]
    public var years: [TimelineYear]
    public var totalCount: Int

    public init(buckets: [TimelineBucket], years: [TimelineYear], totalCount: Int) {
        self.buckets = buckets
        self.years = years
        self.totalCount = totalCount
    }
}

public struct APIErrorBody: Codable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}
