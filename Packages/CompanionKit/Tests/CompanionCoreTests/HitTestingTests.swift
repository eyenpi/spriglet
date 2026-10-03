import Foundation
import Testing
@testable import CompanionCore

@Suite("Visible character picking") struct HitTestingTests {
    @Test("Transparent bounding-box corners cannot hover, activate or start a grab")
    func transparentCorners() {
        var engine = CompanionEngine(scene: .preview)
        let bounds = engine.snapshot.hitBounds
        let corners = [Point(x: bounds.minX + 1, y: bounds.minY + 1), Point(x: bounds.maxX - 1, y: bounds.minY + 1),
                       Point(x: bounds.minX + 1, y: bounds.maxY - 1), Point(x: bounds.maxX - 1, y: bounds.maxY - 1)]
        for point in corners {
            #expect(bounds.contains(point))
            #expect(!engine.snapshot.contains(point))
            engine.send(.pointerMoved(point)); advance(&engine, seconds: 0.6)
            #expect(abs(engine.snapshot.openness - 0.6) < 0.001)
            engine.send(.pointerPressed(point))
            #expect(!engine.hasPointerCapture)
            engine.send(.pointerDragged(point + Point(x: 30, y: 20)))
            engine.send(.pointerReleased(point))
            #expect(engine.snapshot.presence == .peek && engine.snapshot.phase == .hanging)
        }
    }
    @Test("The transformed body, feet and palms are interactive", arguments: [0.45, 1.0, 1.8])
    func transformedSilhouette(scale: Double) {
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: 720, height: 420),
                                  home: Rect(x: 260, y: 0, width: 200, height: 54), floor: 365, scale: scale)
        var pose = CharacterPose()
        pose.height = 1.3; pose.width = 1 / pose.height; pose.lean = -0.12; pose.arm = 0.9
        pose.walk = 0.8; pose.gaitPhase = 0.75; pose.facing = 0.65
        let frame = CompanionSnapshot(scene: scene, presence: .playing, phase: .held, pose: pose,
                                      feet: Point(x: 360, y: 270), windowAnchor: Point(x: 360, y: 270),
                                      rotation: 0.4, openness: 1, homeGrip: 0, time: 0, gesture: nil, canCatch: false)
        let geometry = frame.geometry
        #expect(frame.contains(geometry.root.apply(geometry.body.apply(Point(x: 0, y: -40)))))
        // A shoulder-height corner is outside the curved crown, even after rotation.
        #expect(!frame.contains(geometry.root.apply(geometry.body.apply(Point(x: -60, y: -78)))))
        for foot in geometry.feet { #expect(frame.contains(geometry.root.apply(foot.center))) }
        for hand in geometry.hands { #expect(frame.contains(hand.palm.center)) }
        #expect(!frame.contains(Point(x: .infinity, y: 200)))
    }
    @Test("Housing and off-display pixels cannot be picked")
    func occlusion() {
        let frame = CompanionEngine(scene: .preview).snapshot
        let hidden = Point(x: frame.feet.x, y: frame.scene.home.maxY - 4)
        #expect(frame.geometry.contains(hidden))
        #expect(!frame.contains(hidden))
        #expect(!frame.contains(Point(x: frame.feet.x, y: -1)))
    }
    @Test("A valid grab stays captured outside the silhouette and ends on release")
    func forgivingCapture() {
        var engine = CompanionEngine(scene: .preview)
        let start = engine.snapshot.hitBounds.center, outside = Point(x: 650, y: 310)
        engine.send(.pointerPressed(start)); engine.send(.pointerDragged(outside))
        #expect(!engine.snapshot.contains(outside))
        #expect(engine.isDragging && engine.hasPointerCapture)
        engine.send(.outsidePressed)
        #expect(engine.snapshot.phase == .held)
        engine.send(.pointerReleased(outside))
        #expect(!engine.hasPointerCapture && engine.snapshot.phase == .falling)
    }
}
