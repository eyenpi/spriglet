import CoreGraphics
import Foundation

/// Current value geometry for one display. Callers should rebuild this value
/// when screen parameters change rather than retaining platform screen objects.
public struct HabitatDisplayGeometry: Equatable, Sendable {
    public let displayID: UUID
    public let visibleFrame: CGRect

    public init?(displayID: UUID, visibleFrame: CGRect) {
        guard Self.isValid(visibleFrame) else { return nil }
        self.displayID = displayID
        self.visibleFrame = visibleFrame
    }

    fileprivate static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width >= 0 && frame.size.height >= 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }
}

/// A conservative floor on which the current pet window can be placed safely.
public struct PetHabitat: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case floor
    }

    public let displayID: UUID
    public let kind: Kind
    public let visibleFrame: CGRect
    public let windowSize: CGSize
    public let margin: CGFloat
    public let restingOrigin: CGPoint

    fileprivate init(
        display: HabitatDisplayGeometry,
        windowSize: CGSize,
        margin: CGFloat
    ) {
        displayID = display.displayID
        kind = .floor
        visibleFrame = display.visibleFrame
        self.windowSize = windowSize
        self.margin = margin
        restingOrigin = PetPlacement.restingOrigin(
            windowSize: windowSize,
            visibleFrame: display.visibleFrame,
            margin: margin
        )
    }

    /// Returns nil for a malformed proposed point instead of crossing the
    /// preconditioned `PetPlacement` boundary with invalid geometry.
    public func clampedOrigin(_ proposedOrigin: CGPoint) -> CGPoint? {
        guard proposedOrigin.x.isFinite, proposedOrigin.y.isFinite else { return nil }
        return PetPlacement.clampedOrigin(
            proposedOrigin,
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
    }
}

public protocol HabitatProvider: Sendable {
    func habitat(
        for display: HabitatDisplayGeometry,
        windowSize: CGSize,
        margin: CGFloat
    ) -> PetHabitat?
}

/// The initial provider exposes only the existing visible-screen floor and
/// delegates its placement rules to `PetPlacement`.
public struct ConservativeFloorHabitatProvider: HabitatProvider {
    public init() {}

    public func habitat(
        for display: HabitatDisplayGeometry,
        windowSize: CGSize,
        margin: CGFloat = 12
    ) -> PetHabitat? {
        guard windowSize.width.isFinite, windowSize.height.isFinite,
              windowSize.width >= 0, windowSize.height >= 0,
              margin.isFinite, margin >= 0
        else { return nil }

        let habitat = PetHabitat(display: display, windowSize: windowSize, margin: margin)
        guard habitat.restingOrigin.x.isFinite, habitat.restingOrigin.y.isFinite else { return nil }
        return habitat
    }
}
