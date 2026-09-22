import CoreGraphics
import Foundation

/// Insets expressed without an AppKit dependency so a screen snapshot can cross
/// the platform boundary as a value.
public struct HabitatInsets: Equatable, Sendable {
    public let top: CGFloat
    public let left: CGFloat
    public let bottom: CGFloat
    public let right: CGFloat

    public init?(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        guard [top, left, bottom, right].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// Immutable current geometry for one screen. Callers rebuild it from the
/// current platform screen list; it deliberately retains no `NSScreen`.
public struct HabitatScreenSnapshot: Equatable, Sendable {
    public let displayID: UUID
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaInsets: HabitatInsets
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?
    public let backingScale: CGFloat
    public let isMain: Bool

    public init?(
        displayID: UUID,
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: HabitatInsets,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil,
        backingScale: CGFloat,
        isMain: Bool = false
    ) {
        guard Self.isNonEmptyFiniteRect(frame), Self.isNonEmptyFiniteRect(visibleFrame),
              frame.contains(visibleFrame), backingScale.isFinite, backingScale > 0,
              safeAreaInsets.top + safeAreaInsets.bottom <= frame.height,
              safeAreaInsets.left + safeAreaInsets.right <= frame.width
        else { return nil }
        guard let left = Self.normalizedAuxiliaryArea(auxiliaryTopLeftArea, within: frame),
              let right = Self.normalizedAuxiliaryArea(auxiliaryTopRightArea, within: frame)
        else { return nil }
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.auxiliaryTopLeftArea = left
        self.auxiliaryTopRightArea = right
        self.backingScale = backingScale
        self.isMain = isMain
    }

    /// Insets occupied by Dock and menu-bar regions inferred conservatively
    /// from AppKit's frame and visible frame, never guessed as exact controls.
    public var dockAndMenuInsets: HabitatInsets {
        HabitatInsets(
            top: max(0, frame.maxY - visibleFrame.maxY),
            left: max(0, visibleFrame.minX - frame.minX),
            bottom: max(0, visibleFrame.minY - frame.minY),
            right: max(0, frame.maxX - visibleFrame.maxX)
        )!
    }

    private static func normalizedAuxiliaryArea(_ area: CGRect?, within frame: CGRect) -> CGRect?? {
        guard let area else { return .some(nil) }
        guard isFiniteRect(area), frame.contains(area) else { return nil }
        guard area.width > 0, area.height > 0 else { return .some(nil) }
        return .some(area)
    }

    fileprivate static func isFiniteRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.width >= 0 && rect.height >= 0
    }

    fileprivate static func isNonEmptyFiniteRect(_ rect: CGRect) -> Bool {
        isFiniteRect(rect) && rect.width > 0 && rect.height > 0
    }
}

public enum HabitatSurfaceKind: String, CaseIterable, Hashable, Sendable {
    case floor
    case topShelf
    case notchLeft
    case notchRight
    case wallLeft
    case wallRight
}

public enum HabitatAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

/// A one-dimensional supporting line in global AppKit screen coordinates.
public struct HabitatOrientedInterval: Equatable, Sendable {
    public let axis: HabitatAxis
    public let fixedCoordinate: CGFloat
    public let start: CGFloat
    public let end: CGFloat

    public init?(axis: HabitatAxis, fixedCoordinate: CGFloat, start: CGFloat, end: CGFloat) {
        guard [fixedCoordinate, start, end].allSatisfy(\.isFinite), end > start else { return nil }
        self.axis = axis
        self.fixedCoordinate = fixedCoordinate
        self.start = start
        self.end = end
    }

    public var length: CGFloat { end - start }

    public func point(at progress: CGFloat) -> CGPoint? {
        guard progress.isFinite, (0...1).contains(progress) else { return nil }
        let coordinate = start + length * progress
        guard coordinate.isFinite else { return nil }
        switch axis {
        case .horizontal: return CGPoint(x: coordinate, y: fixedCoordinate)
        case .vertical: return CGPoint(x: fixedCoordinate, y: coordinate)
        }
    }
}

/// Cardinal normals avoid malformed or non-unit surface vectors.
public enum HabitatSurfaceNormal: Equatable, Sendable {
    case up
    case down
    case left
    case right

    public var vector: CGPoint {
        switch self {
        case .up: CGPoint(x: 0, y: 1)
        case .down: CGPoint(x: 0, y: -1)
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        }
    }
}

public enum HabitatInteractivePolicy: Equatable, Sendable {
    /// Ordinary authored hit regions may be active while the pet is visible.
    case authoredHitRegion
    /// A portal is interactive only in an authored visible, supported state.
    case supportedVisibleHitRegion
    /// Geometry exists for future capability matching but cannot be selected.
    case disabled
}

public enum HabitatCapability: Hashable, Sendable {
    case ledgePortalTraversal
    case wallTraversal
}

public struct HabitatCapabilityRequirements: Equatable, Sendable {
    public let allOf: Set<HabitatCapability>

    public init(_ allOf: Set<HabitatCapability> = []) { self.allOf = allOf }

    public func isSatisfied(by capabilities: Set<HabitatCapability>) -> Bool {
        allOf.isSubset(of: capabilities)
    }
}

public struct HabitatSurfaceIdentifier: Hashable, Sendable {
    public let displayID: UUID
    public let kind: HabitatSurfaceKind

    public init(displayID: UUID, kind: HabitatSurfaceKind) {
        self.displayID = displayID
        self.kind = kind
    }
}

public enum HabitatGeometryAvailability: Equatable, Sendable {
    case selectable
    case unselectableOverlappingDisplay
}

public enum HabitatPortalDirection: Equatable, Sendable {
    case entry
    case exit
}

public enum HabitatPortalMarker: Equatable, Sendable {
    /// The only marker at which a host may move a window between habitats.
    case fullyHidden
}

/// An explicit portal endpoint. Its zero local root translation prevents the
/// host from treating a local animation as cross-habitat window movement.
public struct HabitatPortal: Equatable, Sendable {
    public let id: String
    public let direction: HabitatPortalDirection
    public let requiredMarker: HabitatPortalMarker
    public let localRootTranslation: CGPoint
    public let connectedSurfaceKinds: Set<HabitatSurfaceKind>

    public init?(
        id: String,
        direction: HabitatPortalDirection,
        requiredMarker: HabitatPortalMarker = .fullyHidden,
        localRootTranslation: CGPoint = .zero,
        connectedSurfaceKinds: Set<HabitatSurfaceKind>
    ) {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              localRootTranslation.x.isFinite, localRootTranslation.y.isFinite,
              localRootTranslation == .zero, !connectedSurfaceKinds.isEmpty
        else { return nil }
        self.id = id
        self.direction = direction
        self.requiredMarker = requiredMarker
        self.localRootTranslation = localRootTranslation
        self.connectedSurfaceKinds = connectedSurfaceKinds
    }
}

/// The measured portal window contract for Acorn's local ledge clips.
public struct HabitatPortalArtGeometry: Equatable, Sendable {
    public let portalWindowSize: CGSize
    public let gripOffsetFromWindowTop: CGFloat
    public let requiredHeadClearance: CGFloat

    public init?(
        portalWindowSize: CGSize,
        gripOffsetFromWindowTop: CGFloat,
        requiredHeadClearance: CGFloat
    ) {
        guard portalWindowSize.width.isFinite, portalWindowSize.height.isFinite,
              portalWindowSize.width > 0, portalWindowSize.height > 0,
              gripOffsetFromWindowTop.isFinite, requiredHeadClearance.isFinite,
              gripOffsetFromWindowTop >= requiredHeadClearance, requiredHeadClearance >= 0
        else { return nil }
        self.portalWindowSize = portalWindowSize
        self.gripOffsetFromWindowTop = gripOffsetFromWindowTop
        self.requiredHeadClearance = requiredHeadClearance
    }

    /// Acorn's 448-pixel source canvas at the 96-point Standard scale.
    public static let acornStandard = HabitatPortalArtGeometry(
        portalWindowSize: CGSize(width: 96, height: 96),
        gripOffsetFromWindowTop: 259.616 / 448 * 96,
        requiredHeadClearance: 46
    )!

    public static func acorn(scale: CGFloat) -> HabitatPortalArtGeometry? {
        guard scale.isFinite, scale > 0 else { return nil }
        return HabitatPortalArtGeometry(
            portalWindowSize: CGSize(width: 96 * scale, height: 96 * scale),
            gripOffsetFromWindowTop: 259.616 / 448 * 96 * scale,
            requiredHeadClearance: 46 * scale
        )
    }
}

/// A value-only habitat surface. `safeVisualBounds` constrains the entire pet
/// window, so a top portal never enters the visible frame's protected strip.
public struct HabitatSurface: Equatable, Sendable {
    public let id: HabitatSurfaceIdentifier
    public let interval: HabitatOrientedInterval
    public let normal: HabitatSurfaceNormal
    public let safeVisualBounds: CGRect
    public let interactivePolicy: HabitatInteractivePolicy
    public let entryPortals: [HabitatPortal]
    public let exitPortals: [HabitatPortal]
    public let capabilityRequirements: HabitatCapabilityRequirements
    public let availability: HabitatGeometryAvailability

    public func isSelectable(using capabilities: Set<HabitatCapability>) -> Bool {
        availability == .selectable
            && interactivePolicy != .disabled
            && capabilityRequirements.isSatisfied(by: capabilities)
    }
}

/// Fresh, validated output from the geometry boundary. It permits disjoint and
/// negative-origin display layouts, while keeping mirrored/overlapping displays
/// present but unselectable instead of discarding the complete topology.
public struct HabitatTopology: Equatable, Sendable {
    public let displays: [HabitatScreenSnapshot]
    public let surfaces: [HabitatSurface]
    public let artGeometry: HabitatPortalArtGeometry

    public init?(
        displays: [HabitatScreenSnapshot],
        artGeometry: HabitatPortalArtGeometry = .acornStandard
    ) {
        guard !displays.isEmpty,
              Set(displays.map(\.displayID)).count == displays.count
        else { return nil }
        self.displays = displays
        self.artGeometry = artGeometry
        surfaces = displays.flatMap { display in
            HabitatTopology.surfaces(
                for: display,
                availability: HabitatTopology.availability(of: display, in: displays),
                art: artGeometry
            )
        }
    }

    /// Relocation is legal only between explicit opposite endpoints at their
    /// fully hidden marker, with zero local root translation on both sides.
    public func permitsInterHabitatRelocation(
        from source: HabitatSurfaceIdentifier,
        exitPortalID: String,
        to destination: HabitatSurfaceIdentifier,
        entryPortalID: String
    ) -> Bool {
        guard source != destination,
              let sourceSurface = surfaces.first(where: { $0.id == source }),
              let destinationSurface = surfaces.first(where: { $0.id == destination }),
              let exit = sourceSurface.exitPortals.first(where: { $0.id == exitPortalID }),
              let entry = destinationSurface.entryPortals.first(where: { $0.id == entryPortalID })
        else { return false }
        return exit.requiredMarker == .fullyHidden
            && entry.requiredMarker == .fullyHidden
            && exit.localRootTranslation == .zero
            && entry.localRootTranslation == .zero
            && exit.connectedSurfaceKinds.contains(destination.kind)
            && entry.connectedSurfaceKinds.contains(source.kind)
    }

    private static func availability(
        of display: HabitatScreenSnapshot,
        in displays: [HabitatScreenSnapshot]
    ) -> HabitatGeometryAvailability {
        for other in displays where other.displayID != display.displayID && display.frame.intersects(other.frame) {
            if display.frame == other.frame {
                if other.isMain && !display.isMain { return .unselectableOverlappingDisplay }
                if !other.isMain && display.isMain { continue }
            }
            // A partial overlap is ambiguous. Equal-frame mirrors retain only
            // the main display; ties conservatively leave both unselectable.
            return .unselectableOverlappingDisplay
        }
        return .selectable
    }

    private static func surfaces(
        for display: HabitatScreenSnapshot,
        availability: HabitatGeometryAvailability,
        art: HabitatPortalArtGeometry
    ) -> [HabitatSurface] {
        let visual = display.visibleFrame
        let floor = surface(
            display: display, kind: .floor,
            interval: HabitatOrientedInterval(axis: .horizontal, fixedCoordinate: visual.minY, start: visual.minX, end: visual.maxX)!,
            normal: .up, bounds: visual, interaction: .authoredHitRegion,
            requirements: .init(), availability: availability
        )
        let leftWall = surface(
            display: display, kind: .wallLeft,
            interval: HabitatOrientedInterval(axis: .vertical, fixedCoordinate: visual.minX, start: visual.minY, end: visual.maxY)!,
            normal: .right, bounds: visual, interaction: .disabled,
            requirements: .init([.wallTraversal]), availability: availability
        )
        let rightWall = surface(
            display: display, kind: .wallRight,
            interval: HabitatOrientedInterval(axis: .vertical, fixedCoordinate: visual.maxX, start: visual.minY, end: visual.maxY)!,
            normal: .left, bounds: visual, interaction: .disabled,
            requirements: .init([.wallTraversal]), availability: availability
        )
        let ledges = portalLedges(for: display, art: art, availability: availability)
        return [floor, leftWall, rightWall] + ledges
    }

    private static func portalLedges(
        for display: HabitatScreenSnapshot,
        art: HabitatPortalArtGeometry,
        availability: HabitatGeometryAvailability
    ) -> [HabitatSurface] {
        let visual = display.visibleFrame
        guard visual.height >= art.portalWindowSize.height else { return [] }
        let topBounds = { (range: ClosedRange<CGFloat>) in
            CGRect(
                x: range.lowerBound,
                y: visual.maxY - art.portalWindowSize.height,
                width: range.upperBound - range.lowerBound,
                height: art.portalWindowSize.height
            )
        }
        let candidates: [(HabitatSurfaceKind, ClosedRange<CGFloat>)]
        if let left = display.auxiliaryTopLeftArea,
           let right = display.auxiliaryTopRightArea,
           left.maxX < right.minX {
            candidates = [
                (.notchLeft, left.minX...left.maxX),
                (.notchRight, right.minX...right.maxX)
            ]
        } else {
            let halfWidth = art.portalWindowSize.width / 2
            let center = visual.midX
            candidates = [(.topShelf, (center - halfWidth)...(center + halfWidth))]
        }
        return candidates.compactMap { kind, range in
            guard range.upperBound - range.lowerBound >= art.portalWindowSize.width,
                  let interval = HabitatOrientedInterval(
                    axis: .horizontal,
                    fixedCoordinate: visual.maxY,
                    start: range.lowerBound,
                    end: range.upperBound
                  )
            else { return nil }
            return surface(
                display: display, kind: kind, interval: interval, normal: .down,
                bounds: topBounds(range), interaction: .supportedVisibleHitRegion,
                requirements: .init([.ledgePortalTraversal]), availability: availability
            )
        }
    }

    private static func surface(
        display: HabitatScreenSnapshot,
        kind: HabitatSurfaceKind,
        interval: HabitatOrientedInterval,
        normal: HabitatSurfaceNormal,
        bounds: CGRect,
        interaction: HabitatInteractivePolicy,
        requirements: HabitatCapabilityRequirements,
        availability: HabitatGeometryAvailability
    ) -> HabitatSurface {
        let id = HabitatSurfaceIdentifier(displayID: display.displayID, kind: kind)
        let connections: Set<HabitatSurfaceKind> = {
            switch kind {
            case .floor: [.topShelf, .notchLeft, .notchRight]
            case .topShelf, .notchLeft, .notchRight: [.floor]
            case .wallLeft, .wallRight: []
            }
        }()
        let entries = connections.isEmpty ? [] : [HabitatPortal(
            id: "\(kind.rawValue).entry", direction: .entry, connectedSurfaceKinds: connections
        )!]
        let exits = connections.isEmpty ? [] : [HabitatPortal(
            id: "\(kind.rawValue).exit", direction: .exit, connectedSurfaceKinds: connections
        )!]
        return HabitatSurface(
            id: id, interval: interval, normal: normal, safeVisualBounds: bounds,
            interactivePolicy: interaction, entryPortals: entries, exitPortals: exits,
            capabilityRequirements: requirements, availability: availability
        )
    }
}
