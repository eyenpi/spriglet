import Foundation
import Testing
@testable import CompanionCore

@Suite("Quiet personality") struct IdleAnimationTests {
    @Test("An afternoon has bounded, separated moments and irregular visible blinks", arguments: [UInt64(0), 0x4D414C4C4F57, .max])
    func afternoon(seed: UInt64) {
        var idle = IdleAnimation(seed: seed)
        var blinkStarts: [Double] = [], momentStarts: [Double] = [], momentEnds: [Double] = []
        var wasClosed = false, wasMoving = false, quietSteps = 0, glances = 0, settles = 0
        var bounded = true, continuous = true, previous = CharacterPose()
        let steps = 3 * 60 * 60 * 120
        for index in 0..<steps {
            idle.step(SimulationTuning.step, quiet: true, policy: .full)
            let pose = idle.pose, time = Double(index + 1) / 120
            let closed = pose.eyes < 0.12
            if closed && !wasClosed { blinkStarts.append(time) }
            wasClosed = closed
            let moving = abs(pose.look) > 0.000001 || abs(pose.lean) > 0.000001
            if moving && !wasMoving {
                momentStarts.append(time)
                if abs(pose.look) > 0.000001 { glances += 1 } else { settles += 1 }
            }
            if !moving && wasMoving { momentEnds.append(time) }
            if !moving { quietSteps += 1 }
            wasMoving = moving
            bounded = bounded && (0.977...1.0141).contains(pose.height) && abs(pose.look) <= 2.4
                && abs(pose.lookY) <= 0.8 && abs(pose.lean) <= 0.01 && (0...1).contains(pose.eyes)
                && abs(pose.width * pose.height - 1) < 0.000001
                && pose.arm == 0 && pose.walk == 0
            continuous = continuous && abs(pose.height - previous.height) < 0.0003
                && abs(pose.look - previous.look) < 0.03 && abs(pose.lean - previous.lean) < 0.0001
            previous = pose
        }
        let blinkIntervals = zip(blinkStarts, blinkStarts.dropFirst()).map { $1 - $0 }
        let ordinaryIntervals = blinkIntervals.filter { $0 > 1 }
        let momentGaps = zip(momentEnds, momentStarts.dropFirst()).map { $1 - $0 }
        let momentDurations = zip(momentStarts, momentEnds).map { $1 - $0 }
        #expect(bounded && continuous)
        #expect(blinkStarts.count > 1200 && blinkStarts.count < 2800)
        #expect(ordinaryIntervals.allSatisfy { (3.2...8.7).contains($0) })
        #expect(Set(ordinaryIntervals.map { Int($0 * 100) }).count > 100)
        #expect(blinkIntervals.contains { (0.3...0.6).contains($0) })
        #expect(momentGaps.allSatisfy { (17.9...38.1).contains($0) })
        #expect(momentDurations.allSatisfy { (3.4...9.1).contains($0) })
        #expect(glances > 100 && settles > 30 && settles < glances)
        #expect(Double(quietSteps) / Double(steps) > 0.75)
    }

    @Test("Breathing changes pace and depth without a repeating sway")
    func breathing() {
        var idle = IdleAnimation(seed: 42)
        var cycleStarts: [Double] = [], peaks: [Double] = []
        var previousHeight = 1.0, peak = 1.0
        for index in 0..<120 * 180 {
            idle.step(SimulationTuning.step, quiet: false, policy: .full)
            peak = max(peak, idle.pose.height)
            if idle.pose.height >= 1 && previousHeight < 1 {
                cycleStarts.append(Double(index + 1) / 120); peaks.append(peak); peak = 1
            }
            previousHeight = idle.pose.height
        }
        let durations = zip(cycleStarts, cycleStarts.dropFirst()).map { $1 - $0 }
        #expect(durations.allSatisfy { (3.79...6.21).contains($0) })
        #expect(Set(durations.map { Int($0 * 100) }).count > 20)
        #expect((peaks.max() ?? 0) - (peaks.min() ?? 0) > 0.003)
        #expect(idle.pose.lean == 0 && idle.pose.look == 0 && idle.pose.lookY == 0)
    }

    @Test("Interactions cancel a quiet moment and require a fresh pause afterwards")
    func interruption() {
        var idle = IdleAnimation(seed: 42)
        var foundMoment = false
        for _ in 0..<120 * 120 {
            idle.step(SimulationTuning.step, quiet: true, policy: .full)
            if abs(idle.pose.look) > 0.1 || abs(idle.pose.lean) > 0.001 { foundMoment = true; break }
        }
        #expect(foundMoment)
        var suppressed = true
        for _ in 0..<120 * 600 {
            idle.step(SimulationTuning.step, quiet: false, policy: .full)
            suppressed = suppressed && idle.pose.look == 0 && idle.pose.lookY == 0 && idle.pose.lean == 0
        }
        for _ in 0..<120 * 17 {
            idle.step(SimulationTuning.step, quiet: true, policy: .full)
            suppressed = suppressed && idle.pose.look == 0 && idle.pose.lookY == 0 && idle.pose.lean == 0
        }
        #expect(suppressed)
    }

    @Test("Reduce Motion retains varied blinking and suppresses decorative movement")
    func reducedMotion() {
        var idle = IdleAnimation(seed: 42)
        var didBlink = false, still = true
        for _ in 0..<120 * 120 {
            idle.step(SimulationTuning.step, quiet: true, policy: .reduced)
            didBlink = didBlink || idle.pose.eyes < 0.12
            still = still && idle.pose.height == 1 && idle.pose.width == 1 && idle.pose.look == 0
                && idle.pose.lookY == 0 && idle.pose.lean == 0
        }
        #expect(still && didBlink)
        for _ in 0..<120 * 17 { idle.step(SimulationTuning.step, quiet: true, policy: .full) }
        #expect(idle.pose.look == 0 && idle.pose.lean == 0)
    }

    @Test("Recovery clears pending expressions without a catch-up blink or moment", arguments: [false, true])
    func recovery(duringBlink: Bool) {
        var idle = IdleAnimation(seed: 42)
        var foundExpression = false
        for _ in 0..<120 * 120 {
            idle.step(SimulationTuning.step, quiet: true, policy: .full)
            if duringBlink ? idle.pose.eyes < 0.12 : abs(idle.pose.look) > 0.1 {
                foundExpression = true; break
            }
        }
        #expect(foundExpression)
        idle.reset()
        #expect(idle.pose == CharacterPose())
        var quiet = true
        for _ in 0..<120 * 1 {
            idle.step(SimulationTuning.step, quiet: true, policy: .full)
            quiet = quiet && idle.pose.eyes == 1 && idle.pose.look == 0 && idle.pose.lean == 0
        }
        #expect(quiet)
    }

    @Test("Nearby pointer attention defers quiet moments and keeps the responsive gaze")
    func nearbyAttention() {
        var engine = CompanionEngine(scene: .preview, idleSeed: 42)
        engine.send(.pointerMoved(engine.snapshot.feet + Point(x: 80, y: 40)))
        advance(&engine, seconds: 2)
        var responsive = true
        for _ in 0..<1200 {
            engine.advance(by: 1 / 20.0)
            responsive = responsive && abs(engine.snapshot.pose.look - 80 / 35.0) < 0.001
                && engine.snapshot.pose.lean == 0 && engine.snapshot.openness == 0.6
        }
        #expect(responsive)
        engine.send(.pointerMoved(Point(x: -1000, y: -1000)))
        advance(&engine, seconds: 17)
        #expect(abs(engine.snapshot.pose.look) < 0.001 && engine.snapshot.pose.lean == 0)
    }

    @Test("Blinks remain visible at both resting cadences across session seeds", arguments: [UInt64(0), 42, .max], [15.0, 20.0])
    func visibleBlinks(seed: UInt64, fps: Double) {
        var reference = CompanionEngine(scene: .preview, idleSeed: seed), sampled = reference
        var inBlink = false, sawClosedFrame = false, missedBlinks = 0, blinks = 0
        for _ in 0..<Int(fps * 120) {
            var closedInInterval = false
            for _ in 0..<Int(120 / fps) {
                reference.advance(by: SimulationTuning.step)
                closedInInterval = closedInInterval || reference.snapshot.pose.eyes < 0.12
            }
            sampled.advance(by: 1 / fps)
            if closedInInterval {
                inBlink = true
                sawClosedFrame = sawClosedFrame || sampled.snapshot.pose.eyes < 0.12
            } else if inBlink {
                blinks += 1
                if !sawClosedFrame { missedBlinks += 1 }
                inBlink = false; sawClosedFrame = false
            }
        }
        #expect(blinks >= 15 && missedBlinks == 0)
    }

    @Test("Seeded idle poses match across host cadences and preserve the default peek", arguments: [15.0, 20.0, 30.0, 60.0])
    func cadence(fps: Double) {
        var reference = CompanionEngine(scene: .preview, idleSeed: 42), candidate = reference
        var matched = true, resting = true
        for _ in 0..<180 {
            advance(&reference, seconds: 1, fps: 120)
            advance(&candidate, seconds: 1, fps: fps)
            let frame = candidate.snapshot
            matched = matched && frame.pose == reference.snapshot.pose && frame.feet == reference.snapshot.feet
            resting = resting && frame.presence == .peek && frame.phase == .hanging && frame.gesture == nil
                && frame.openness == 0.6 && frame.rotation == 0 && frame.hitBounds.height > 25
        }
        #expect(matched && resting)
    }

    @Test("Distinct session seeds vary the idle without changing home or interaction")
    func seeds() {
        var first = CompanionEngine(scene: .preview, idleSeed: 0)
        var second = CompanionEngine(scene: .preview, idleSeed: .max)
        advance(&first, seconds: 30); advance(&second, seconds: 30)
        #expect(first.snapshot.pose != second.snapshot.pose)
        #expect(first.snapshot.feet == second.snapshot.feet && first.snapshot.openness == second.snapshot.openness)
        tap(&first); tap(&second)
        #expect(first.snapshot.presence == .engaged && second.snapshot.presence == .engaged)
        #expect(first.snapshot.gesture == .hello && second.snapshot.gesture == .hello)
    }

    @Test("Grabbing during a glance retains the visible pose and catch feedback wins")
    func grabDuringGlance() {
        var engine = CompanionEngine(scene: .preview, idleSeed: 42)
        var foundGlance = false
        for _ in 0..<120 * 120 {
            engine.advance(by: SimulationTuning.step)
            if abs(engine.snapshot.pose.look) > 1 { foundGlance = true; break }
        }
        #expect(foundGlance)
        let before = engine.snapshot, pointer = before.hitBounds.center
        engine.send(.pointerPressed(pointer)); engine.send(.pointerDragged(pointer + Point(x: 6, y: 0)))
        #expect(engine.snapshot.pose == before.pose && engine.snapshot.feet == before.feet)
        advance(&engine, seconds: 1)
        #expect(engine.snapshot.phase == .held && engine.snapshot.canCatch)
        #expect(engine.snapshot.pose.lookY < before.pose.lookY - 2)
    }
}
