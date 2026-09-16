import CoreGraphics
import Foundation
import ImageIO
import SprigletCore

/// Images and a small alpha mask cross to the main actor after decoding.
nonisolated struct SampleDecodedFrame: Sendable {
    let image: CGImage
    let alpha: Data
    let maskSize: Int

    func contains(x: Double, y: Double) -> Bool {
        guard (0..<1).contains(x), (0..<1).contains(y) else { return false }
        let column = min(maskSize - 1, Int(x * Double(maskSize)))
        let row = min(maskSize - 1, Int((1 - y) * Double(maskSize)))
        // Only the solid character is interactive; soft fur edges and the
        // semitransparent ground shadow should not enlarge the drag target.
        return alpha[row * maskSize + column] > 224
    }
}

nonisolated enum SampleImageDecoder {
    @concurrent
    static func decode(url: URL, canvas: SampleSize) async throws -> SampleDecodedFrame {
        try Task.checkCancellation()
        return try decodeImmediately(url: url, canvas: canvas)
    }

    /// Only the two static poses use the synchronous path at construction.
    static func decodeImmediately(url: URL, canvas: SampleSize) throws -> SampleDecodedFrame {
        let image = try decodeImage(url: url, canvas: canvas)
        let size = 64
        var mask = [UInt8](repeating: 0, count: size * size * 4)
        let success = mask.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard success else { throw SampleManifestError.invalid("Could not prepare character hit testing.") }
        return SampleDecodedFrame(image: image, alpha: Data(stride(from: 3, to: mask.count, by: 4).map { mask[$0] }), maskSize: size)
    }

    /// Inspect dimensions before requesting an eager pixel decode. Cropped rig
    /// layers share this loader without allocating unnecessary hit-test masks.
    static func decodeImage(url: URL, canvas: SampleSize) throws -> CGImage {
        guard canvas.width.isFinite, canvas.height.isFinite,
              (1...2_048).contains(canvas.width), (1...2_048).contains(canvas.height),
              canvas.width.rounded() == canvas.width, canvas.height.rounded() == canvas.height,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == Int(canvas.width),
              (metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == Int(canvas.height),
              (metadata[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
              ] as CFDictionary),
              image.width == Int(canvas.width), image.height == Int(canvas.height) else {
            throw SampleManifestError.invalid("Missing or invalid character frame: \(url.lastPathComponent).")
        }
        return image
    }
}
