import CoreGraphics
import Foundation
import SprigletCore
import Testing

private var sizeRepository: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}

private func sizeManifest() throws -> SproutSampleManifest {
    try SproutSampleManifest.decode(Data(contentsOf:
        sizeRepository.appendingPathComponent("Sources/Spriglet/Resources/SproutSample/manifest.json")))
}

private struct SizeContacts: Decodable {
    struct Foot: Decodable { let canvasPixels: SamplePoint; let planted: Bool }
    struct Frame: Decodable { let feet: [String: Foot] }
    struct Clip: Decodable { let frames: [Frame] }
    let clips: [String: Clip]
}

@Suite("Character display size and grounded movement")
struct PetDisplaySizeTests {
    @Test("Sizes retain source pixels and timing while scaling finite trajectories", arguments: PetDisplaySize.allCases)
    func trajectories(choice: PetDisplaySize) throws {
        let source = try sizeManifest()
        let scaled = try choice.scaledManifest(source)
        let expectedPoints: [PetDisplaySize: Double] = [.small: 168, .standard: 224, .large: 280]
        #expect(choice.pointSize == expectedPoints[choice])
        #expect(scaled.displaySizePoints == SampleSize(width: choice.pointSize, height: choice.pointSize))
        #expect(scaled.canvasPixels == source.canvasPixels)
        #expect(scaled.groundAnchorPixels == source.groundAnchorPixels)
        #expect(scaled.restFrame == source.restFrame && scaled.sleepFrame == source.sleepFrame)
        for direction in [SampleClipID.walkLeft, .walkRight] {
            for routine in PetRoutine.allCases {
                for stationary in [false, true] {
                    let clips = routine.clips(direction: direction, stationary: stationary)
                    let original = try SampleTimeline(manifest: source, clips: clips)
                    let timeline = try SampleTimeline(manifest: scaled, clips: clips)
                    #expect(timeline.duration == original.duration && timeline.frameCount == original.frameCount)
                    #expect(timeline.snapshot(at: timeline.duration).rootOffsetPoints == .zero)
                    for index in 0..<timeline.frameCount {
                        let frame = timeline.snapshot(atFrame: index)
                        let authored = original.snapshot(atFrame: index)
                        #expect(frame.file == authored.file && frame.clip == authored.clip)
                        #expect(abs(frame.rootOffsetPoints.x - authored.rootOffsetPoints.x * choice.scale) < 1e-9)
                        #expect(frame.rootOffsetPoints.y == 0)
                    }
                    let excursion = timeline.rootOffsets.map { abs($0.x) }.max() ?? 0
                    let moves = !stationary && (routine == .explore || routine == .firefly)
                    // Blender's recorded endpoint is 78.3999988317 points;
                    // preserve its source tolerance rather than rounding motion.
                    #expect(abs(excursion - (moves ? 78.4 * choice.scale : 0)) < 1e-5 * choice.scale)
                }
            }
            let offsets = try SampleTimeline(manifest: scaled, clips: PetRoutine.explore.clips(direction: direction)).rootOffsets
            let excursion = 78.4 * choice.scale
            let origin = CGPoint(x: -988 + (direction == .walkLeft ? excursion : 0), y: -488)
            let fitting = CGRect(x: -1000, y: -500, width: choice.pointSize + 24 + excursion + 0.001, height: choice.pointSize + 24)
            let fitted = try #require(SampleMotionPlacement.fittingStartOrigin(
                preferredOrigin: origin, windowSize: choice.size, visibleFrame: fitting, offsets: offsets))
            #expect(abs(fitted.x - origin.x) < 1e-9 && abs(fitted.y - origin.y) < 1e-9)
            let narrow = CGRect(x: fitting.minX, y: fitting.minY, width: fitting.width - 0.002, height: fitting.height)
            #expect(SampleMotionPlacement.fittingStartOrigin(
                preferredOrigin: origin, windowSize: choice.size, visibleFrame: narrow, offsets: offsets) == nil)
        }
    }

    @Test("Recorded planted feet remain grounded after bitmap and root scaling", arguments: PetDisplaySize.allCases)
    func plantedContacts(choice: PetDisplaySize) throws {
        let manifest = try choice.scaledManifest(sizeManifest())
        let contacts = try JSONDecoder().decode(SizeContacts.self, from: Data(contentsOf:
            sizeRepository.appendingPathComponent("art/sprout/sample-v01/contact-samples.json")))
        let pointsPerPixel = choice.pointSize / manifest.canvasPixels.width
        for direction in [SampleClipID.walkLeft, .walkRight] {
            let timeline = try SampleTimeline(manifest: manifest, clips: [direction])
            let recorded = try #require(contacts.clips[direction.rawValue])
            #expect(recorded.frames.count == timeline.frameCount)
            for side in ["left", "right"] {
                var first: CGPoint?
                var measuredPairs = 0
                for (index, contact) in recorded.frames.enumerated() {
                    let foot = try #require(contact.feet[side])
                    guard foot.planted else { first = nil; continue }
                    let root = timeline.snapshot(atFrame: index).rootOffsetPoints
                    let point = CGPoint(x: foot.canvasPixels.x * pointsPerPixel + root.x,
                                        y: foot.canvasPixels.y * pointsPerPixel + root.y)
                    if let first {
                        measuredPairs += 1
                        // Same authoring tolerance as source validation, converted
                        // to the displayed point size rather than fixed at 2x.
                        #expect(hypot(point.x - first.x, point.y - first.y) <= 0.05 * pointsPerPixel)
                    } else { first = point }
                }
                #expect(measuredPairs > 0)
            }
        }
    }

    @Test("Firefly path and its scaled glow stay inside each canvas", arguments: PetDisplaySize.allCases)
    func toyGeometry(choice: PetDisplaySize) throws {
        let source = try sizeManifest()
        let scaled = try choice.scaledManifest(source)
        for direction in [SampleClipID.walkLeft, .walkRight] {
            for stationary in [false, true] {
                let timeline = try SampleTimeline(manifest: scaled, clips: PetRoutine.firefly.clips(direction: direction, stationary: stationary))
                var visibleCount = 0
                for index in 0..<timeline.frameCount {
                    let snapshot = timeline.snapshot(atFrame: index)
                    let pose = FireflyMotion.pose(for: snapshot, manifest: scaled, direction: direction, stationary: stationary)
                    let original = FireflyMotion.pose(for: snapshot, manifest: source, direction: direction, stationary: stationary)
                    if let pose, let original {
                        visibleCount += 1
                        #expect(abs(pose.position.x - original.position.x * choice.scale) < 1e-9)
                        #expect(abs(pose.position.y - original.position.y * choice.scale) < 1e-9)
                        #expect(pose.opacity == original.opacity && pose.wingSpread == original.wingSpread)
                        let radius = 14 * choice.scale
                        #expect((radius...(choice.pointSize - radius)).contains(pose.position.x))
                        #expect((radius...(choice.pointSize - radius)).contains(pose.position.y))
                    } else { #expect(pose == nil && original == nil) }
                }
                #expect(visibleCount > 30)
                #expect(FireflyMotion.pose(for: timeline.snapshot(at: timeline.duration), manifest: scaled,
                                          direction: direction, stationary: stationary) == nil)
            }
        }
    }

    @Test("Resizing retains fractional canvas bottom-center and clamps only at an edge", arguments: PetDisplaySize.allCases)
    func anchoring(choice: PetDisplaySize) {
        let visible = CGRect(x: -1000, y: -300, width: 1400, height: 900)
        let original = CGRect(x: -632.375, y: 93.6875, width: 224, height: 224)
        let origin = choice.bottomCenterOrigin(resizing: original, within: visible)
        let resized = CGRect(origin: origin, size: choice.size)
        #expect(resized.midX == original.midX && resized.minY == original.minY)
        #expect(PetDisplaySize.standard.bottomCenterOrigin(resizing: resized, within: visible) == original.origin)

        let edge = CGRect(x: -320, y: 40, width: 640, height: 480)
        let nearLeft = CGRect(x: -300.25, y: 52.125, width: 224, height: 224)
        let atEdge = choice.bottomCenterOrigin(resizing: nearLeft, within: edge)
        #expect(atEdge.x == max(-308, nearLeft.midX - choice.size.width / 2))
        #expect(atEdge.y == nearLeft.minY)
        #expect(edge.contains(CGRect(origin: atEdge, size: choice.size)))
    }
}
