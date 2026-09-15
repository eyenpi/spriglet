import CoreGraphics
import Foundation

/// Relative size choices. The asset manifest owns its standard canvas size.
public enum PetDisplaySize: String, CaseIterable, Codable, Sendable {
    case small, standard, large

    public var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        }
    }

    public var pointSize: Double {
        switch self {
        case .small: 168
        case .standard: 224
        case .large: 280
        }
    }

    public var scale: Double { pointSize / 224 }
    public var size: CGSize { CGSize(width: pointSize, height: pointSize) }

    public func size(for authored: SampleSize) -> CGSize {
        CGSize(width: authored.width * scale, height: authored.height * scale)
    }

    /// Derives playback coordinates without changing image paths, pixels, or
    /// frame timing. Both trajectory fitting and presentation use this value.
    /// Source metadata remains available separately for asset verification.
    public func scaledManifest(_ source: SproutSampleManifest) throws -> SproutSampleManifest {
        try source.validate()
        guard source.displaySizePoints.width == source.displaySizePoints.height,
              source.canvasPixels.width == source.canvasPixels.height else {
            throw SampleManifestError.invalid("Character size choices require a square authored canvas.")
        }
        let factor = scale
        let result = SproutSampleManifest(
            schemaVersion: source.schemaVersion,
            canvasPixels: source.canvasPixels,
            displaySizePoints: SampleSize(width: source.displaySizePoints.width * factor,
                                          height: source.displaySizePoints.height * factor),
            framesPerSecond: source.framesPerSecond,
            groundAnchorPixels: source.groundAnchorPixels,
            restFrame: source.restFrame,
            sleepFrame: source.sleepFrame,
            clips: source.clips.mapValues { clip in
                .init(frames: clip.frames.map { frame in
                    .init(file: frame.file, rootOffsetPoints: .init(
                        x: frame.rootOffsetPoints.x * factor,
                        y: frame.rootOffsetPoints.y * factor
                    ))
                })
            }
        )
        try result.validate()
        return result
    }

    /// Preserves the effective canvas bottom-center until a display edge
    /// requires clamping. Feet and the baked shadow scale inside that canvas;
    /// this does not claim to preserve their distance from the bottom edge.
    public func bottomCenterOrigin(
        resizing frame: CGRect, within visibleFrame: CGRect, margin: CGFloat = 12
    ) -> CGPoint {
        precondition(frame.origin.x.isFinite && frame.origin.y.isFinite
                     && frame.width.isFinite && frame.height.isFinite
                     && frame.width >= 0 && frame.height >= 0,
                     "Current character frame must be finite with nonnegative dimensions")
        return PetPlacement.clampedOrigin(
            CGPoint(x: frame.midX - size.width / 2, y: frame.minY),
            windowSize: size, visibleFrame: visibleFrame, margin: margin
        )
    }
}
