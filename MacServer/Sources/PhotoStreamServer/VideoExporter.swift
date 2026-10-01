import AVFoundation
import Foundation
import Photos

enum VideoExportError: Error {
    case noResource
    case exportFailed
}

enum VideoExporter {
    /// Export a Photos library video for HTTP delivery.
    static func data(for asset: PHAsset) async throws -> (Data, String) {
        guard asset.mediaType == .video else { throw VideoExportError.noResource }

        let resources = PHAssetResource.assetResources(for: asset)
        let resource =
            resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .pairedVideo })

        if let resource {
            let ext = resource.originalFilename.split(separator: ".").last.map(String.init)?.lowercased() ?? "mov"
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
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
            defer { try? FileManager.default.removeItem(at: out) }
            let data = try Data(contentsOf: out, options: [.mappedIfSafe])
            return (data, mimeType(forExtension: ext))
        }

        // Fallback: request file URL via AVAsset export.
        return try await exportViaAVAsset(asset)
    }

    private static func exportViaAVAsset(_ phAsset: PHAsset) async throws -> (Data, String) {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset.url)
                    return
                }
                continuation.resume(throwing: VideoExportError.noResource)
            }
        }

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return (data, mimeType(forExtension: url.pathExtension.lowercased()))
        }
        throw VideoExportError.exportFailed
    }

    static func data(fileURL: URL) throws -> (Data, String) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return (data, mimeType(forExtension: fileURL.pathExtension.lowercased()))
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
        // Sync path used during folder scan; deprecated APIs are fine here.
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
