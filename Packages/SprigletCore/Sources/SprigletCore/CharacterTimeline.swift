import Foundation

/// The generic timeline intentionally preserves the existing snapshot shape so
/// renderers can migrate without changing atomic image/root callbacks.
public typealias CharacterTimelineSnapshot = SampleTimelineSnapshot

/// One authored signal reached by the exact committed image/root pair.
/// A pose is present only when that frame is an actual clip endpoint.
public struct CharacterPlaybackMarker: Equatable, Sendable {
    public enum Kind: Int, Equatable, Sendable {
        case interruption
        case semanticEvent
    }

    public let kind: Kind
    public let id: String
    public let poseID: String?
    public let clipID: CharacterClipID
    public let clipFrameIndex: Int
    public let timelineFrameIndex: Int

    public init(
        kind: Kind,
        id: String,
        poseID: String?,
        clipID: CharacterClipID,
        clipFrameIndex: Int,
        timelineFrameIndex: Int
    ) {
        self.kind = kind
        self.id = id
        self.poseID = poseID
        self.clipID = clipID
        self.clipFrameIndex = clipFrameIndex
        self.timelineFrameIndex = timelineFrameIndex
    }
}

/// A finite timeline with one cumulative time boundary per authored frame.
/// Clips may use different frame rates; no display-rate clock is implied.
public struct CharacterTimeline: Sendable {
    private struct Entry: Sendable {
        let startTime: TimeInterval
        let snapshot: CharacterTimelineSnapshot
        let markers: [CharacterPlaybackMarker]
        let safeInterruption: CharacterPlaybackMarker?
    }

    public let duration: TimeInterval
    public let maximumFramesPerSecond: Double
    public let startPoseID: String
    public let endPoseID: String
    public var frameCount: Int { entries.count }
    public var rootOffsets: [SamplePoint] { entries.map(\.snapshot.rootOffsetPoints) }
    private let entries: [Entry]
    private let safeInterruptionIndices: [Int]

    public init(package: CharacterPackage, plan: CharacterAnimationPlan) throws {
        try package.validate()
        guard !plan.clipIDs.isEmpty, plan.clipIDs.count <= 32,
              package.poses[plan.startPoseID] != nil,
              package.poses[plan.endPoseID] != nil else {
            throw CharacterPackageError.invalid("Invalid or empty character timeline plan.")
        }

        let plannedClips = try plan.clipIDs.map { rawClipID -> (CharacterClipID, CharacterPackage.Clip) in
            guard let clipID = CharacterClipID(rawValue: rawClipID),
                  let clip = package.clips[rawClipID] else {
                throw CharacterPackageError.invalid("Character timeline references a missing clip.")
            }
            return (clipID, clip)
        }
        let commonFrameRate = Set(plannedClips.map(\.1.framesPerSecond)).count == 1
            ? plannedClips[0].1.framesPerSecond
            : nil
        maximumFramesPerSecond = plannedClips.map(\.1.framesPerSecond).max() ?? 0
        startPoseID = plan.startPoseID
        endPoseID = plan.endPoseID

        var result: [Entry] = []
        var segmentBase: TimeInterval = 0
        var base = SamplePoint.zero
        var poseID = plan.startPoseID
        for (clipID, clip) in plannedClips {
            let interruptionMarkersByFrame = Dictionary(grouping: clip.interruptionMarkers, by: \.frameIndex)
            let semanticEventsByFrame = Dictionary(grouping: clip.semanticEvents, by: \.frameIndex)
            guard clip.startPoseID == poseID else {
                throw CharacterPackageError.invalid("Discontinuous character timeline plan.")
            }
            for (clipFrameIndex, frame) in clip.frames.enumerated() {
                let startTime = if let commonFrameRate {
                    Double(result.count) / commonFrameRate
                } else {
                    segmentBase + Double(clipFrameIndex) / clip.framesPerSecond
                }
                let timelineFrameIndex = result.count
                let poseID: String? = if clip.frames.count == 1 {
                    clip.startPoseID == clip.endPoseID ? clip.startPoseID : nil
                } else if clipFrameIndex == 0 {
                    clip.startPoseID
                } else if clipFrameIndex == clip.frames.count - 1 {
                    clip.endPoseID
                } else {
                    nil
                }
                let interruptionMarkers = (interruptionMarkersByFrame[clipFrameIndex] ?? [])
                    .map {
                        CharacterPlaybackMarker(
                            kind: .interruption, id: $0.id, poseID: poseID, clipID: clipID,
                            clipFrameIndex: clipFrameIndex, timelineFrameIndex: timelineFrameIndex
                        )
                    }
                let semanticEvents = (semanticEventsByFrame[clipFrameIndex] ?? [])
                    .map {
                        CharacterPlaybackMarker(
                            kind: .semanticEvent, id: $0.id, poseID: poseID, clipID: clipID,
                            clipFrameIndex: clipFrameIndex, timelineFrameIndex: timelineFrameIndex
                        )
                    }
                let markers = (interruptionMarkers + semanticEvents).sorted {
                    $0.kind.rawValue == $1.kind.rawValue
                        ? $0.id < $1.id
                        : $0.kind.rawValue < $1.kind.rawValue
                }
                result.append(Entry(
                    startTime: startTime,
                    snapshot: CharacterTimelineSnapshot(
                        clip: clipID,
                        clipFrameIndex: clipFrameIndex,
                        timelineFrameIndex: timelineFrameIndex,
                        file: frame.file,
                        rootOffsetPoints: SamplePoint(
                            x: base.x + frame.rootOffsetPoints.x,
                            y: base.y + frame.rootOffsetPoints.y
                        ),
                        isComplete: false
                    ),
                    markers: markers,
                    safeInterruption: markers.first {
                        $0.kind == .interruption && $0.id == "safeToRedirect" && $0.poseID != nil
                    }
                ))
            }
            segmentBase += Double(clip.frames.count) / clip.framesPerSecond
            if let lastOffset = clip.frames.last?.rootOffsetPoints {
                base = SamplePoint(x: base.x + lastOffset.x, y: base.y + lastOffset.y)
            }
            poseID = clip.endPoseID
        }
        let resolvedDuration = if let commonFrameRate {
            Double(result.count) / commonFrameRate
        } else {
            segmentBase
        }
        guard poseID == plan.endPoseID, !result.isEmpty, resolvedDuration.isFinite else {
            throw CharacterPackageError.invalid("Character timeline does not reach its planned pose.")
        }
        entries = result
        safeInterruptionIndices = result.indices.filter { result[$0].safeInterruption != nil }
        duration = resolvedDuration
    }

    public init(package: CharacterPackage, clips: [CharacterClipID]) throws {
        try package.validate()
        guard !clips.isEmpty, clips.count <= 32,
              let first = package.clips[clips[0].rawValue],
              let last = package.clips[clips[clips.count - 1].rawValue] else {
            throw CharacterPackageError.invalid("Invalid or empty character clip playlist.")
        }
        try self.init(
            package: package,
            plan: CharacterAnimationPlan(
                requestedIntentID: "playlist",
                resolvedIntentID: "playlist",
                startPoseID: first.startPoseID,
                endPoseID: last.endPoseID,
                clipIDs: clips.map(\.rawValue)
            )
        )
    }

    public init(
        package: CharacterPackage,
        intentID: String,
        from poseID: String,
        context: CharacterPlaybackContext = CharacterPlaybackContext()
    ) throws {
        try self.init(
            package: package,
            plan: package.plan(for: intentID, from: poseID, context: context)
        )
    }

    public func snapshot(at elapsed: TimeInterval) -> CharacterTimelineSnapshot {
        let time = elapsed.isNaN ? 0 : max(0, elapsed)
        guard time < duration else { return completedSnapshot() }

        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].startTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return snapshot(atFrame: max(0, lower - 1))
    }

    public func snapshot(atFrame requestedIndex: Int) -> CharacterTimelineSnapshot {
        let complete = requestedIndex >= entries.count
        let index = min(entries.count - 1, max(0, requestedIndex))
        let snapshot = entries[index].snapshot
        return CharacterTimelineSnapshot(
            clip: snapshot.clip,
            clipFrameIndex: snapshot.clipFrameIndex,
            timelineFrameIndex: index,
            file: snapshot.file,
            rootOffsetPoints: snapshot.rootOffsetPoints,
            isComplete: complete
        )
    }

    public func markers(atFrame requestedIndex: Int) -> [CharacterPlaybackMarker] {
        guard entries.indices.contains(requestedIndex) else { return [] }
        return entries[requestedIndex].markers
    }

    public func startTime(atFrame requestedIndex: Int) -> TimeInterval? {
        guard entries.indices.contains(requestedIndex) else { return nil }
        return entries[requestedIndex].startTime
    }

    public func safeInterruption(atFrame requestedIndex: Int) -> CharacterPlaybackMarker? {
        guard entries.indices.contains(requestedIndex) else { return nil }
        return entries[requestedIndex].safeInterruption
    }

    public func nextSafeInterruption(afterFrame frameIndex: Int) -> CharacterPlaybackMarker? {
        guard frameIndex < entries.count - 1, !safeInterruptionIndices.isEmpty else { return nil }
        var lower = 0
        var upper = safeInterruptionIndices.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if safeInterruptionIndices[middle] <= frameIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < safeInterruptionIndices.count else { return nil }
        return entries[safeInterruptionIndices[lower]].safeInterruption
    }

    private func completedSnapshot() -> CharacterTimelineSnapshot {
        snapshot(atFrame: entries.count)
    }
}
