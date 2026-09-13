import CoreGraphics
import Foundation

/// A local placement preference, independent of display arrangement and scale.
///
/// Coordinates describe the window origin's reachable range within the visible
/// frame: zero is left/bottom, one is right/top. A collapsed axis uses its center.
/// The display UUID is used only to restore this app's own window placement.
public struct PetSavedPlacement: Codable, Equatable, Sendable {
    public let displayUUID: UUID
    public let normalizedX: Double
    public let normalizedY: Double

    public init?(displayUUID: UUID, normalizedX: Double, normalizedY: Double) {
        guard normalizedX.isFinite, normalizedY.isFinite,
              (0...1).contains(normalizedX), (0...1).contains(normalizedY) else { return nil }
        self.displayUUID = displayUUID
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let displayUUID = try values.decode(UUID.self, forKey: .displayUUID)
        let normalizedX = try values.decode(Double.self, forKey: .normalizedX)
        let normalizedY = try values.decode(Double.self, forKey: .normalizedY)
        guard let placement = Self(
            displayUUID: displayUUID,
            normalizedX: normalizedX,
            normalizedY: normalizedY
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Saved placement coordinates must be finite and within 0...1."
            ))
        }
        self = placement
    }

    /// Captures a clamped position using current AppKit point coordinates.
    public static func capture(
        displayUUID: UUID,
        origin: CGPoint,
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> Self? {
        guard origin.x.isFinite, origin.y.isFinite,
              let bounds = reachableOrigins(windowSize: windowSize, visibleFrame: visibleFrame, margin: margin)
        else { return nil }
        let clamped = PetPlacement.clampedOrigin(
            origin,
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
        return Self(
            displayUUID: displayUUID,
            normalizedX: normalized(clamped.x, lower: bounds.lower.x, upper: bounds.upper.x),
            normalizedY: normalized(clamped.y, lower: bounds.lower.y, upper: bounds.upper.y)
        )
    }

    /// Reconstructs a safe position after display resolution, layout, or Dock changes.
    public func restoredOrigin(
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint? {
        guard let bounds = Self.reachableOrigins(
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        ) else { return nil }
        let origin = CGPoint(
            x: bounds.lower.x + (bounds.upper.x - bounds.lower.x) * normalizedX,
            y: bounds.lower.y + (bounds.upper.y - bounds.lower.y) * normalizedY
        )
        return PetPlacement.clampedOrigin(
            origin,
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
    }

    /// Chooses the preferred display in a fresh topology snapshot, then a fallback.
    /// Unknown display identities remain eligible fallbacks; no index is persisted.
    public func displayIndex(in availableDisplays: [UUID?], fallbackIndex: Int = 0) -> Int? {
        if let preferred = availableDisplays.firstIndex(where: { $0 == displayUUID }) {
            return preferred
        }
        guard !availableDisplays.isEmpty else { return nil }
        return availableDisplays.indices.contains(fallbackIndex) ? fallbackIndex : 0
    }

    private enum CodingKeys: String, CodingKey {
        case displayUUID, normalizedX, normalizedY
    }

    private static func normalized(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> Double {
        guard upper > lower else { return 0.5 }
        return min(1, max(0, Double((value - lower) / (upper - lower))))
    }

    private static func reachableOrigins(
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat
    ) -> (lower: CGPoint, upper: CGPoint)? {
        guard windowSize.width.isFinite, windowSize.height.isFinite,
              windowSize.width >= 0, windowSize.height >= 0,
              visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
              visibleFrame.size.width.isFinite, visibleFrame.size.height.isFinite,
              visibleFrame.size.width >= 0, visibleFrame.size.height >= 0,
              visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite,
              margin.isFinite, margin >= 0 else { return nil }
        let lower = PetPlacement.clampedOrigin(
            visibleFrame.origin,
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
        let upper = PetPlacement.clampedOrigin(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.maxY),
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
        guard lower.x.isFinite, lower.y.isFinite, upper.x.isFinite, upper.y.isFinite,
              (upper.x - lower.x).isFinite, (upper.y - lower.y).isFinite else { return nil }
        return (lower, upper)
    }
}
