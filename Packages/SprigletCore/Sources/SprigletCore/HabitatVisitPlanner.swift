import Foundation

/// Content-owned identifiers for one finite portal visit. Keeping these names in
/// data prevents the planner from acquiring a fixed clip enum as the animation
/// library grows.
public struct HabitatVisitContent: Equatable, Sendable {
    public let floorExitIntentID: String
    public let ledgeEntryIntentID: String
    public let edgeLookIntentID: String
    public let dangleIntentID: String
    public let pullUpIntentID: String
    public let ledgeExitIntentID: String
    public let floorReentryIntentID: String
    public let hiddenPoseID: String
    public let ledgePoseID: String
    public let hangingPoseID: String
    public let floorPoseID: String
    public let fullyHiddenEventID: String
    public let settledMarkerID: String

    public init?(
        floorExitIntentID: String,
        ledgeEntryIntentID: String,
        edgeLookIntentID: String,
        dangleIntentID: String,
        pullUpIntentID: String,
        ledgeExitIntentID: String,
        floorReentryIntentID: String,
        hiddenPoseID: String,
        ledgePoseID: String,
        hangingPoseID: String,
        floorPoseID: String,
        fullyHiddenEventID: String,
        settledMarkerID: String
    ) {
        let values = [
            floorExitIntentID, ledgeEntryIntentID, edgeLookIntentID,
            dangleIntentID, pullUpIntentID, ledgeExitIntentID,
            floorReentryIntentID, hiddenPoseID, ledgePoseID, hangingPoseID,
            floorPoseID, fullyHiddenEventID, settledMarkerID
        ]
        guard values.allSatisfy(Self.isValidIdentifier), Set(values.prefix(7)).count == 7,
              hiddenPoseID != ledgePoseID, hiddenPoseID != floorPoseID,
              ledgePoseID != hangingPoseID, ledgePoseID != floorPoseID,
              hangingPoseID != floorPoseID,
              fullyHiddenEventID != settledMarkerID
        else { return nil }
        self.floorExitIntentID = floorExitIntentID
        self.ledgeEntryIntentID = ledgeEntryIntentID
        self.edgeLookIntentID = edgeLookIntentID
        self.dangleIntentID = dangleIntentID
        self.pullUpIntentID = pullUpIntentID
        self.ledgeExitIntentID = ledgeExitIntentID
        self.floorReentryIntentID = floorReentryIntentID
        self.hiddenPoseID = hiddenPoseID
        self.ledgePoseID = ledgePoseID
        self.hangingPoseID = hangingPoseID
        self.floorPoseID = floorPoseID
        self.fullyHiddenEventID = fullyHiddenEventID
        self.settledMarkerID = settledMarkerID
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
    }
}

/// A topology-checked round trip between the current floor and one upper
/// habitat. Both directions require explicit zero-root, fully-hidden portals.
public struct HabitatVisitPlan: Equatable, Sendable {
    public let source: HabitatSurfaceIdentifier
    public let destination: HabitatSurfaceIdentifier
    public let sourceExitPortalID: String
    public let destinationEntryPortalID: String
    public let destinationExitPortalID: String
    public let sourceEntryPortalID: String
    public let content: HabitatVisitContent

    public init?(
        topology: HabitatTopology,
        source: HabitatSurfaceIdentifier,
        destination: HabitatSurfaceIdentifier,
        sourceExitPortalID: String,
        destinationEntryPortalID: String,
        destinationExitPortalID: String,
        sourceEntryPortalID: String,
        content: HabitatVisitContent
    ) {
        guard source.kind == .floor,
              [.topShelf, .notchLeft, .notchRight].contains(destination.kind),
              topology.permitsInterHabitatRelocation(
                from: source, exitPortalID: sourceExitPortalID,
                to: destination, entryPortalID: destinationEntryPortalID
              ),
              topology.permitsInterHabitatRelocation(
                from: destination, exitPortalID: destinationExitPortalID,
                to: source, entryPortalID: sourceEntryPortalID
              )
        else { return nil }
        self.source = source
        self.destination = destination
        self.sourceExitPortalID = sourceExitPortalID
        self.destinationEntryPortalID = destinationEntryPortalID
        self.destinationExitPortalID = destinationExitPortalID
        self.sourceEntryPortalID = sourceEntryPortalID
        self.content = content
    }
}

/// A renderer marker reduced to the content facts the pure planner needs. The
/// AppKit coordinator separately validates the exact clip endpoint and marker
/// kind before constructing this value.
public struct HabitatVisitMarkerFact: Equatable, Sendable {
    public let id: String
    public let poseID: String

    public init(id: String, poseID: String) {
        self.id = id
        self.poseID = poseID
    }
}

public enum HabitatVisitEffect: Equatable, Sendable {
    case playIntent(String)
    case relocateToDestination(HabitatSurfaceIdentifier)
    case restoreFloor(HabitatSurfaceIdentifier)
    case completed
}

/// A finite, marker-driven visit. It has no clock and cannot produce a host
/// relocation until the authored fully-hidden endpoint has been observed.
public struct HabitatVisitPlanner: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case leavingFloor(cancelRequested: Bool)
        case enteringLedge(cancelRequested: Bool)
        case edgeLook(cancelRequested: Bool)
        case dangle(cancelRequested: Bool)
        case pullUp(cancelRequested: Bool)
        case leavingLedge
        case enteringFloor
    }

    public private(set) var phase: Phase = .idle
    public private(set) var plan: HabitatVisitPlan?

    public init() {}

    @discardableResult
    public mutating func begin(_ plan: HabitatVisitPlan) -> [HabitatVisitEffect] {
        guard phase == .idle else { return [] }
        self.plan = plan
        phase = .leavingFloor(cancelRequested: false)
        return [.playIntent(plan.content.floorExitIntentID)]
    }

    /// Requests the shortest authored return. A ledge clip may finish at its
    /// next safe endpoint before the renderer accepts the exit intent.
    public mutating func cancel() -> [HabitatVisitEffect] {
        guard plan != nil else { return [] }
        switch phase {
        case .idle, .leavingLedge, .enteringFloor:
            return []
        case .leavingFloor:
            phase = .leavingFloor(cancelRequested: true)
            return []
        case .enteringLedge:
            phase = .enteringLedge(cancelRequested: true)
            return []
        case .edgeLook:
            phase = .edgeLook(cancelRequested: true)
            return []
        case .dangle:
            phase = .dangle(cancelRequested: true)
            return []
        case .pullUp:
            phase = .pullUp(cancelRequested: true)
            return []
        }
    }

    public mutating func receive(_ marker: HabitatVisitMarkerFact) -> [HabitatVisitEffect] {
        guard let plan else { return [] }
        let content = plan.content
        switch phase {
        case let .leavingFloor(cancelRequested):
            guard marker.id == content.fullyHiddenEventID,
                  marker.poseID == content.hiddenPoseID else { return [] }
            phase = .enteringFloor
            if cancelRequested {
                return [
                    .restoreFloor(plan.source),
                    .playIntent(content.floorReentryIntentID)
                ]
            }
            phase = .enteringLedge(cancelRequested: false)
            return [
                .relocateToDestination(plan.destination),
                .playIntent(content.ledgeEntryIntentID)
            ]

        case let .enteringLedge(cancelRequested):
            guard marker.id == content.settledMarkerID,
                  marker.poseID == content.ledgePoseID else { return [] }
            if cancelRequested {
                phase = .leavingLedge
                return [.playIntent(content.ledgeExitIntentID)]
            }
            phase = .edgeLook(cancelRequested: false)
            return [.playIntent(content.edgeLookIntentID)]

        case let .edgeLook(cancelRequested):
            guard marker.id == content.settledMarkerID,
                  marker.poseID == content.ledgePoseID else { return [] }
            if cancelRequested {
                phase = .leavingLedge
                return [.playIntent(content.ledgeExitIntentID)]
            }
            phase = .dangle(cancelRequested: false)
            return [.playIntent(content.dangleIntentID)]

        case let .dangle(cancelRequested):
            guard marker.id == content.settledMarkerID,
                  marker.poseID == content.hangingPoseID else { return [] }
            if cancelRequested {
                phase = .pullUp(cancelRequested: true)
                return [.playIntent(content.pullUpIntentID)]
            }
            phase = .pullUp(cancelRequested: false)
            return [.playIntent(content.pullUpIntentID)]

        case .pullUp:
            guard marker.id == content.settledMarkerID,
                  marker.poseID == content.ledgePoseID else { return [] }
            phase = .leavingLedge
            return [.playIntent(content.ledgeExitIntentID)]

        case .leavingLedge:
            guard marker.id == content.fullyHiddenEventID,
                  marker.poseID == content.hiddenPoseID else { return [] }
            phase = .enteringFloor
            return [
                .restoreFloor(plan.source),
                .playIntent(content.floorReentryIntentID)
            ]

        case .enteringFloor:
            guard marker.id == content.settledMarkerID,
                  marker.poseID == content.floorPoseID else { return [] }
            phase = .idle
            self.plan = nil
            return [.completed]

        case .idle:
            return []
        }
    }

    /// Re-enters the shortest authored return from a renderer-proven stationary
    /// endpoint after the next requested intent was rejected. This never emits
    /// a relocation and cannot invent a pose that was not observed.
    public mutating func recover(from marker: HabitatVisitMarkerFact) -> [HabitatVisitEffect] {
        guard let plan else { return [] }
        let content = plan.content
        guard marker.id == content.settledMarkerID else { return [] }
        switch marker.poseID {
        case content.ledgePoseID:
            phase = .leavingLedge
            return [.playIntent(content.ledgeExitIntentID)]
        case content.hangingPoseID:
            phase = .pullUp(cancelRequested: true)
            return [.playIntent(content.pullUpIntentID)]
        case content.floorPoseID:
            phase = .idle
            self.plan = nil
            return [.completed]
        default:
            return []
        }
    }

    /// Fail-closed cleanup for a host or renderer rejection. This does not
    /// authorize movement; the coordinator must restore only while hidden or
    /// retain the visit until an authored hidden marker arrives.
    public mutating func reset() {
        phase = .idle
        plan = nil
    }
}
