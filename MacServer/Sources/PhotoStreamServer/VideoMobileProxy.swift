import AVFoundation
import CryptoKit
import Foundation
import PhotoStreamShared

/// On-demand mobile proxy for cellular / non-Wi‑Fi streaming.
///
/// Target ~2.5 Mbps HEVC at ≤1080p for cellular / 5G (phone screens tolerate
/// this well; smaller files mean less buffer fill and faster first encode).
/// Prefers `ffmpeg` + VideoToolbox; falls back to AVAssetExportSession.
enum VideoMobileProxy {
    /// ~2.5 Mbps video — lean 1080p HEVC for 5G / Tailscale.
    static let targetVideoBitRate = 2_500_000
    static let maxEdge = 1920
    static let audioBitRate = 128_000

    private static let jobs = MobileProxyJobs()

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoStreamMobileProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func shortDigest(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(for sourceURL: URL) async throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(sourceURL.path)|\(size)|\(mtime)|\(targetVideoBitRate)|\(maxEdge)"
        let digest = shortDigest(key)
        let out = cacheDirectory.appendingPathComponent("m1080-\(digest)").appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: out.path) {
            return out
        }

        return try await jobs.run(key: digest) {
            if FileManager.default.fileExists(atPath: out.path) {
                return out
            }
            if let ffmpeg = Self.ffmpegPath() {
                do {
                    try await Self.transcodeWithFFmpeg(source: sourceURL, destination: out, ffmpeg: ffmpeg)
                    return out
                } catch {
                    // Fall through to AVFoundation.
                }
            }
            try await Self.transcodeWithAVFoundation(source: sourceURL, destination: out)
            return out
        }
    }

    private static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func transcodeWithFFmpeg(source: URL, destination: URL, ffmpeg: String) async throws {
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vf = "scale='min(\(maxEdge),iw)':'-2':force_original_aspect_ratio=decrease"
        // Map the first AAC/stereo track explicitly — iPhone MOVs also carry APAC
        // spatial audio that some players won't use over progressive HTTP.
        let hevcArgs = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-vf", vf,
            "-c:v", "hevc_videotoolbox",
            "-b:v", "\(targetVideoBitRate)",
            "-maxrate", "\(Int(Double(targetVideoBitRate) * 1.2))",
            "-bufsize", "\(targetVideoBitRate * 2)",
            "-tag:v", "hvc1",
            "-c:a", "aac",
            "-b:a", "\(audioBitRate)",
            "-ac", "2",
            "-ar", "48000",
            "-movflags", "+faststart",
            tmp.path,
        ]

        var status = try await runProcess(ffmpeg, args: hevcArgs)
        if status != 0 {
            let h264Args = [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", source.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-vf", "\(vf),format=yuv420p",
                "-c:v", "h264_videotoolbox",
                "-b:v", "3000000",
                "-maxrate", "3600000",
                "-bufsize", "6000000",
                "-c:a", "aac",
                "-b:a", "\(audioBitRate)",
                "-ac", "2",
                "-ar", "48000",
                "-movflags", "+faststart",
                tmp.path,
            ]
            status = try await runProcess(ffmpeg, args: h264Args)
        }
        guard status == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            throw VideoExportError.exportFailed
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    private static func runProcess(_ launchPath: String, args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Reliable fallback when ffmpeg isn't installed. 1080p export + fast-start.
    private static func transcodeWithAVFoundation(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let preset =
            AVAssetExportSession.allExportPresets().contains(AVAssetExportPreset1920x1080)
            ? AVAssetExportPreset1920x1080
            : AVAssetExportPreset1280x720
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExportError.exportFailed
        }

        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }

        session.outputURL = tmp
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed, FileManager.default.fileExists(atPath: tmp.path) else {
            throw session.error ?? VideoExportError.exportFailed
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}

actor MobileProxyJobs {
    private var inflight: [String: Task<URL, Error>] = [:]

    func run(key: String, work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task { try await work() }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }
}
