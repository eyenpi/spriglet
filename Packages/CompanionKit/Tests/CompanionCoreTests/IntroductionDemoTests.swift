import Testing
@testable import CompanionCore

@Suite("Introduction demonstrations") struct IntroductionDemoTests {
    private func advance(_ demo: inout IntroductionDemo, to seconds: Double, fps: Double = 60) {
        let frames = Int((seconds - demo.elapsed) * fps + 0.000001)
        for _ in 0..<max(0, frames) { demo.advance(by: 1 / fps) }
    }
    @Test("Hover reacts without inviting or grabbing")
    func hover() {
        var demo = IntroductionDemo(step: .hover)
        advance(&demo, to: 2.8)
        #expect(demo.snapshot.presence == .peek && demo.snapshot.phase == .hanging)
        #expect(demo.snapshot.openness > 0.65 && !demo.pressed)
        advance(&demo, to: 4.8)
        #expect(demo.snapshot.openness < 0.61)
    }
    @Test("Invitation uses a complete click and opens the character")
    func invite() {
        var demo = IntroductionDemo(step: .invite)
        advance(&demo, to: 1.1)
        #expect(demo.pressed)
        advance(&demo, to: 2.8)
        #expect(!demo.pressed && demo.snapshot.presence == .engaged)
        #expect(demo.snapshot.openness > 0.99 && demo.snapshot.gesture == .hello)
    }
    @Test("Dragging leaves catch range and releasing lands")
    func drag() {
        var demo = IntroductionDemo(step: .drag)
        advance(&demo, to: 2.8)
        #expect(demo.pressed && demo.snapshot.phase == .held && !demo.snapshot.canCatch)
        advance(&demo, to: 4.8)
        #expect(!demo.pressed && demo.snapshot.phase == .grounded)
        #expect(abs(demo.snapshot.feet.y - IntroductionDemo.scene.floor) < 0.1)
    }
    @Test("Catching shows readiness before releasing into a real catch")
    func catchHome() {
        var demo = IntroductionDemo(step: .catchHome), away = IntroductionDemo(step: .drag)
        advance(&demo, to: 2.8); advance(&away, to: 2.8)
        #expect(demo.pressed && demo.snapshot.canCatch && demo.snapshot.phase == .held)
        #expect(demo.snapshot.pose.lookY < away.snapshot.pose.lookY - 3)
        advance(&demo, to: 3.3)
        #expect(!demo.pressed && demo.snapshot.phase == .catching)
        advance(&demo, to: 4.8)
        #expect(demo.snapshot.phase == .hanging && demo.snapshot.presence == .peek)
    }
    @Test("An outside click returns the landed character to a quiet home")
    func returnHome() {
        var demo = IntroductionDemo(step: .returnHome)
        advance(&demo, to: 2.7)
        #expect(demo.snapshot.phase == .grounded)
        advance(&demo, to: 2.9)
        #expect(demo.pressed && demo.snapshot.presence == .peek)
        #expect(demo.snapshot.phase == .preparingJump || demo.snapshot.phase == .jumping)
        advance(&demo, to: 4.8)
        #expect(demo.snapshot.phase == .hanging && demo.snapshot.openness < 0.61)
    }
    @Test("Host cadence does not change scripted input or looped physics", arguments: IntroductionStep.allCases)
    func cadence(step: IntroductionStep) {
        var slow = IntroductionDemo(step: step), fast = IntroductionDemo(step: step)
        for _ in 0..<126 { slow.advance(by: 1 / 15) }
        for _ in 0..<504 { fast.advance(by: 1 / 60) }
        #expect(slow.elapsed == fast.elapsed && slow.pointer == fast.pointer && slow.pressed == fast.pressed)
        #expect(slow.snapshot.feet == fast.snapshot.feet && slow.snapshot.pose == fast.snapshot.pose)
        #expect(slow.snapshot.phase == fast.snapshot.phase && slow.snapshot.presence == fast.snapshot.presence)
    }
    @Test("Loop and step changes discard any prior grab", arguments: IntroductionStep.allCases)
    func restart(step: IntroductionStep) {
        let initial = IntroductionDemo(step: step)
        var loop = initial
        for _ in 0..<300 { loop.advance(by: 1 / 60) }
        #expect(loop.elapsed == 0 && !loop.pressed)
        #expect(loop.snapshot.feet == initial.snapshot.feet && loop.snapshot.pose == initial.snapshot.pose)
        let fresh = IntroductionDemo(step: .hover)
        #expect(fresh.snapshot.presence == .peek && !fresh.pressed)
    }
    @Test("Reduce Motion shows useful stills and never animates", arguments: IntroductionStep.allCases)
    func reducedMotion(step: IntroductionStep) {
        var demo = IntroductionDemo(step: step, motionPolicy: .reduced)
        let frame = demo.snapshot, pointer = demo.pointer, elapsed = demo.elapsed
        demo.advance(by: 100); demo.advance(by: .infinity)
        #expect(demo.snapshot.time == frame.time && demo.snapshot.pose == frame.pose)
        #expect(demo.pointer == pointer && demo.elapsed == elapsed)
        switch step {
        case .hover: #expect(frame.presence == .peek)
        case .invite: #expect(frame.presence == .engaged && frame.openness > 0.99)
        case .drag: #expect(frame.phase == .held && !frame.canCatch)
        case .catchHome: #expect(frame.phase == .held && frame.canCatch)
        case .returnHome: #expect(frame.phase == .hanging && frame.presence == .peek)
        }
    }
    @Test("Invalid time is ignored and a host stall has bounded catch-up")
    func elapsedValidation() {
        var demo = IntroductionDemo(step: .drag)
        for elapsed in [0, -1, Double.nan, .infinity] { demo.advance(by: elapsed) }
        #expect(demo.elapsed == 0)
        demo.advance(by: 3600)
        #expect(demo.elapsed > 0 && demo.elapsed <= SimulationTuning.maximumCatchUp + 0.000001)
        #expect(demo.snapshot.feet.isFinite)
    }
}
