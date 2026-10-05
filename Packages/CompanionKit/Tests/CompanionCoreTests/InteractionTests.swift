import Foundation
import Testing
@testable import CompanionCore

func advance(_ engine: inout CompanionEngine, seconds: Double, fps: Double = 60) {
    for _ in 0..<Int((seconds * fps).rounded()) { engine.advance(by: 1 / fps) }
}
func tap(_ engine: inout CompanionEngine) {
    let p = engine.snapshot.hitBounds.center
    engine.send(.pointerPressed(p)); engine.send(.pointerReleased(p))
}
func drag(_ engine: inout CompanionEngine, to point: Point) {
    engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
    for _ in 0..<30 { engine.send(.pointerDragged(point)); engine.advance(by: 1 / 60.0) }
    engine.send(.pointerReleased(point))
}

@Suite("Character interactions") struct InteractionTests {
    @Test("Named gestures choose a predictable reaction without pointer input",
          arguments: [CompanionCommand.greet, .swing, .stretch])
    func namedGesture(command: CompanionCommand) {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.command(command)); advance(&engine, seconds: 0.3)
        let expected: CharacterGesture = command == .greet ? .hello : command == .swing ? .swing : .stretch
        #expect(engine.snapshot.presence == .engaged && engine.snapshot.gesture == expected)
        #expect(!engine.hasPointerCapture)
        if command == .greet { #expect(engine.snapshot.pose.arm > 0.2) }
        if command == .swing { #expect(abs(engine.snapshot.rotation) > 0.01) }
        if command == .stretch { #expect(engine.snapshot.pose.height > 1) }
    }
    @Test("Rest is a visible face, even after a long idle", arguments: [12.0, 30, 60, 120])
    func persistentPeek(fps: Double) {
        var engine = CompanionEngine(scene: .preview)
        advance(&engine, seconds: 120, fps: fps)
        #expect(engine.snapshot.presence == .peek)
        #expect(abs(engine.snapshot.openness - 0.6) < 0.001)
        #expect(engine.snapshot.hitBounds.height > 25)
        #expect(engine.snapshot.gesture == nil)
    }
    @Test("Hover acknowledges without taking over the screen")
    func hover() {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        advance(&engine, seconds: 0.25)
        #expect(abs(engine.snapshot.openness - 0.6) < 0.001)
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.presence == .peek)
        #expect(abs(engine.snapshot.openness - 0.66) < 0.001)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        advance(&engine, seconds: 1)
        #expect(abs(engine.snapshot.openness - 0.6) < 0.001)
    }
    @Test("Touch invites, another touch swings, outside click returns to peek")
    func touchAndDismiss() {
        var engine = CompanionEngine(scene: .preview)
        tap(&engine); advance(&engine, seconds: 1)
        #expect(engine.snapshot.presence == .engaged && engine.snapshot.gesture == .hello)
        #expect(engine.snapshot.openness > 0.99)
        tap(&engine); advance(&engine, seconds: 0.2)
        #expect(engine.snapshot.gesture == .swing)
        #expect(abs(engine.snapshot.rotation) > 0.01)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        engine.send(.outsidePressed); advance(&engine, seconds: 2)
        #expect(engine.snapshot.presence == .peek && abs(engine.snapshot.openness - 0.6) < 0.001)
    }
    @Test("Interaction lasts while the pointer is there and settles after leaving")
    func attention() {
        var engine = CompanionEngine(scene: .preview)
        tap(&engine)
        engine.send(.pointerMoved(engine.snapshot.hitBounds.center))
        advance(&engine, seconds: 30)
        #expect(engine.snapshot.presence == .engaged)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        advance(&engine, seconds: 3)
        #expect(engine.snapshot.presence == .peek)
    }
    @Test("Only the visible body is interactive")
    func clickThrough() {
        let frame = CompanionEngine(scene: .preview).snapshot
        #expect(frame.contains(frame.hitBounds.center))
        #expect(!frame.contains(Point(x: frame.hitBounds.midX + 100, y: frame.hitBounds.midY)))
        #expect(!frame.contains(Point(x: frame.scene.home.midX, y: frame.scene.home.maxY - 1)))
        #expect(!frame.contains(Point(x: .nan, y: 1)))
    }
    @Test("A press with small jitter remains a touch, not a drag")
    func jitter() {
        var engine = CompanionEngine(scene: .preview)
        let p = engine.snapshot.hitBounds.center
        engine.send(.pointerPressed(p)); engine.send(.pointerDragged(p + Point(x: 1, y: 1)))
        #expect(!engine.isDragging)
        engine.send(.pointerReleased(p))
        #expect(engine.snapshot.presence == .engaged)
    }
    @Test("Outside clicks cannot interrupt an active grab")
    func capture() {
        var engine = CompanionEngine(scene: .preview)
        engine.send(.pointerPressed(engine.snapshot.hitBounds.center))
        engine.send(.pointerDragged(Point(x: 500, y: 150)))
        engine.send(.outsidePressed)
        #expect(engine.snapshot.phase == .held && engine.hasPointerCapture)
    }
    @Test("Nonfinite input and elapsed time cannot poison the session")
    func invalidInputs() {
        var engine = CompanionEngine(scene: .preview)
        let initial = engine.snapshot
        engine.send(.pointerPressed(Point(x: .infinity, y: .nan)))
        engine.send(.pointerMoved(Point(x: .nan, y: 20)))
        engine.advance(by: .nan); engine.advance(by: .infinity); engine.advance(by: -1)
        #expect(engine.time == 0)
        #expect(engine.snapshot.feet == initial.feet && !engine.hasPointerCapture)
    }
    @Test("A long host stall has bounded catch-up")
    func stall() {
        var engine = CompanionEngine(scene: .preview)
        engine.advance(by: 3600)
        #expect(abs(engine.time - 0.25) < 0.000001)
    }
}
