import CoreGraphics
import Foundation

/// Frame identity and displacement are one value. A held frame therefore always
/// holds its planted root position; callers must never interpolate the offset.
public struct SampleTimelineSnapshot: Equatable, Sendable {
    public let clip: SampleClipID
    public let clipFrameIndex: Int
    public let timelineFrameIndex: Int
    public let file: String
    public let rootOffsetPoints: SamplePoint
    public let isComplete: Bool
}

public struct SampleTimeline: Sendable {
    public let framesPerSecond: Double
    public var duration: Double { Double(frameCount) / framesPerSecond }
    public var frameCount: Int { frames.count }
    public var rootOffsets: [SamplePoint] { frames.map(\.rootOffsetPoints) }
    private let frames: [SampleTimelineSnapshot]

    public init(manifest: SproutSampleManifest, clips: [SampleClipID]) throws {
        try manifest.validate()
        guard !clips.isEmpty, clips.count <= 16 else { throw SampleManifestError.invalid("Invalid sample playlist.") }
        framesPerSecond = manifest.framesPerSecond
        var result: [SampleTimelineSnapshot] = []
        var base = SamplePoint.zero
        for id in clips {
            guard let clip = manifest.clips[id.rawValue] else { throw SampleManifestError.invalid("Missing sample clip.") }
            for (index, frame) in clip.frames.enumerated() {
                result.append(.init(clip: id, clipFrameIndex: index, timelineFrameIndex: result.count,
                                    file: frame.file,
                                    rootOffsetPoints: .init(x: base.x + frame.rootOffsetPoints.x,
                                                            y: base.y + frame.rootOffsetPoints.y),
                                    isComplete: false))
            }
            if let last = result.last { base = last.rootOffsetPoints }
        }
        frames = result
    }

    public func snapshot(at elapsed: Double) -> SampleTimelineSnapshot {
        let time = elapsed.isNaN ? 0 : max(0, elapsed)
        let complete = time >= duration
        // Check completion before multiplying/casting untrusted elapsed values.
        var index = complete ? frames.count - 1 : min(frames.count - 1, Int((time * framesPerSecond).rounded(.down)))
        if !complete {
            // Multiplication can round 4.1 * 30 one ULP below 123. Compare with
            // the original boundary quotient, preserving its exact nextDown.
            if index + 1 < frames.count, time >= Double(index + 1) / framesPerSecond { index += 1 }
            else if index > 0, time < Double(index) / framesPerSecond { index -= 1 }
        }
        return snapshot(atFrame: complete ? frames.count : index)
    }

    public func snapshot(atFrame requestedIndex: Int) -> SampleTimelineSnapshot {
        let complete = requestedIndex >= frames.count
        let index = min(frames.count - 1, max(0, requestedIndex))
        let frame = frames[index]
        return .init(clip: frame.clip, clipFrameIndex: frame.clipFrameIndex,
                     timelineFrameIndex: index, file: frame.file,
                     rootOffsetPoints: frame.rootOffsetPoints, isComplete: complete)
    }
}

/// Fits the entire authored trajectory before it starts. Clamping each moving
/// frame independently would continue a walking pose against a stationary edge.
public enum SampleMotionPlacement {
    public static func fittingStartOrigin(
        preferredOrigin: CGPoint, windowSize: CGSize, visibleFrame: CGRect,
        offsets: [SamplePoint], margin: CGFloat = 12
    ) -> CGPoint? {
        guard preferredOrigin.x.isFinite, preferredOrigin.y.isFinite,
              windowSize.width.isFinite, windowSize.height.isFinite,
              windowSize.width > 0, windowSize.height > 0,
              visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
              visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.width > 0, visibleFrame.height > 0,
              visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite,
              margin.isFinite, margin >= 0,
              !offsets.isEmpty, offsets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xMargin = min(margin, max(0, (visibleFrame.width - windowSize.width) / 2))
        let yMargin = min(margin, max(0, (visibleFrame.height - windowSize.height) / 2))
        let lowerX = visibleFrame.minX + xMargin - CGFloat(offsets.map(\.x).min()!)
        let upperX = visibleFrame.maxX - xMargin - windowSize.width - CGFloat(offsets.map(\.x).max()!)
        let lowerY = visibleFrame.minY + yMargin - CGFloat(offsets.map(\.y).min()!)
        let upperY = visibleFrame.maxY - yMargin - windowSize.height - CGFloat(offsets.map(\.y).max()!)
        guard lowerX.isFinite, upperX.isFinite, lowerY.isFinite, upperY.isFinite,
              lowerX <= upperX, lowerY <= upperY else { return nil }
        return CGPoint(x: min(upperX, max(lowerX, preferredOrigin.x)),
                       y: min(upperY, max(lowerY, preferredOrigin.y)))
    }
}
