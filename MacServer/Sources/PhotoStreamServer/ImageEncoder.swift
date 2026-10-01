import AppKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum ImageEncodeError: Error {
    case noData
    case encodeFailed
}

enum ImageEncoder {
    static func jpegThumbnail(for asset: PHAsset, maxPixel: Int) async throws -> Data {
        let image = try await requestNSImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFill,
            deliveryMode: .highQualityFormat,
            resizeMode: .fast
        )
        guard let cgImage = cgImage(from: image) else { throw ImageEncodeError.noData }
        return try jpegData(from: cgImage, quality: 0.67, maxPixel: maxPixel)
    }

    static func jpegFull(for asset: PHAsset) async throws -> Data {
        let image = try await requestNSImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            deliveryMode: .highQualityFormat,
            resizeMode: .none
        )
        guard let cgImage = cgImage(from: image) else { throw ImageEncodeError.noData }
        let maxEdge = max(asset.pixelWidth, asset.pixelHeight, 1)
        let cap = min(maxEdge, 8192)
        return try jpegData(from: cgImage, quality: 0.92, maxPixel: cap)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func requestNSImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode
    ) async throws -> NSImage {
        let cgImage = try await requestCGImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            deliveryMode: deliveryMode,
            resizeMode: resizeMode
        )
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func requestCGImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        resizeMode: PHImageRequestOptionsResizeMode
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = deliveryMode
            options.resizeMode = resizeMode
            options.version = .current

            var finished = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

                if cancelled {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: ImageEncodeError.noData)
                    }
                    return
                }
                if let error {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if deliveryMode == .highQualityFormat && degraded {
                    return
                }
                guard let image else {
                    if !degraded, !finished {
                        finished = true
                        continuation.resume(throwing: ImageEncodeError.noData)
                    }
                    return
                }
                var rect = CGRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: ImageEncodeError.noData)
                    }
                    return
                }
                if !finished {
                    finished = true
                    continuation.resume(returning: cgImage)
                }
            }
        }
    }

    private static func jpegData(from image: CGImage, quality: CGFloat, maxPixel: Int) throws -> Data {
        let scaled = scale(image, maxPixel: maxPixel)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodeError.encodeFailed
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncodeError.encodeFailed
        }
        return data as Data
    }

    private static func scale(_ image: CGImage, maxPixel: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxPixel, maxPixel > 0 else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let tw = max(1, Int(CGFloat(w) * scale))
        let th = max(1, Int(CGFloat(h) * scale))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: tw,
            height: th,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }
}
