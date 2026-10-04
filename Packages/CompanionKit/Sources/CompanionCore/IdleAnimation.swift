import Foundation

/// Session-owned natural rhythms. Quiet moments only author pose targets; they
/// never move the body, change presence, or request a gesture. Simulation time
/// and a supplied seed make every rhythm reproducible across display cadences.
struct IdleAnimation: Sendable {
    private(set) var pose = CharacterPose()
    private var random: IdleRandom
    private var breathPhase = 0.0
    private var breathDuration: Double
    private var breathDepth: Double
    private var blinkDelay: Double
    private var blink: Blink?
    private var momentDelay = 0.0
    private var moment: QuietMoment?
    private var wasQuiet = false

    init(seed: UInt64) {
        var random = IdleRandom(state: seed)
        breathDuration = random.value(in: 3.8...6.2)
        breathDepth = random.value(in: 0.009...0.014)
        blinkDelay = random.value(in: 1.8...4.5)
        self.random = random
    }

    /// Recovery starts from the resting face, without replaying missed moments
    /// or rewinding the session's random sequence.
    mutating func reset() {
        pose = CharacterPose(); breathPhase = 0
        breathDuration = random.value(in: 3.8...6.2)
        breathDepth = random.value(in: 0.009...0.014)
        blink = nil; blinkDelay = random.value(in: 1.8...4.5)
        moment = nil; wasQuiet = false
    }

    mutating func step(_ dt: Double, quiet: Bool, policy: MotionPolicy) {
        advanceBlink(dt)
        breathPhase += dt / breathDuration
        if breathPhase >= 1 {
            breathPhase -= 1
            breathDuration = random.value(in: 3.8...6.2)
            breathDepth = random.value(in: 0.009...0.014)
        }
        pose = CharacterPose()
        pose.eyes = blink?.openness ?? 1
        if policy == .full { pose.height += sin(breathPhase * 2 * .pi) * breathDepth }

        if quiet && policy == .full {
            if !wasQuiet { momentDelay = random.value(in: 18...38) }
            advanceMoment(dt)
            if let moment {
                let weight = moment.weight
                pose.look = moment.look.x * weight; pose.lookY = moment.look.y * weight
                pose.height -= moment.compression * weight
                pose.lean = moment.lean * weight
            }
            wasQuiet = true
        } else {
            // Interaction takes priority. A fresh quiet interval is required
            // afterwards, so leaving hover never triggers overdue idle work.
            moment = nil; wasQuiet = false
        }
        pose.width = 1 / pose.height
    }

    private mutating func advanceBlink(_ dt: Double) {
        if var blink {
            blink.age += dt
            if blink.age >= blink.duration {
                self.blink = nil; blinkDelay = random.value(in: 3.2...7.8)
            } else { self.blink = blink }
        } else {
            blinkDelay -= dt
            if blinkDelay <= 0 {
                blink = Blink(closing: random.value(in: 0.045...0.07),
                              held: random.value(in: 0.09...0.13),
                              opening: random.value(in: 0.085...0.13),
                              repeatPause: random.value(in: 0...1) < 0.16 ? random.value(in: 0.12...0.2) : nil)
            }
        }
    }

    private mutating func advanceMoment(_ dt: Double) {
        if var moment {
            moment.age += dt
            if moment.age >= moment.duration {
                self.moment = nil; momentDelay = random.value(in: 18...38)
            } else { self.moment = moment }
        } else {
            momentDelay -= dt
            if momentDelay <= 0 {
                let direction = random.value(in: 0...1) < 0.5 ? -1.0 : 1.0
                if random.value(in: 0...1) < 0.75 {
                    moment = QuietMoment(duration: random.value(in: 3.5...5.5),
                                         look: Point(x: direction * random.value(in: 1.2...2.4), y: random.value(in: -0.8...0.6)))
                } else {
                    moment = QuietMoment(duration: random.value(in: 6...9),
                                         compression: random.value(in: 0.004...0.009),
                                         lean: direction * random.value(in: 0.004...0.01))
                }
            }
        }
    }
}

private struct Blink: Sendable {
    var age = 0.0
    let closing: Double
    let held: Double
    let opening: Double
    let repeatPause: Double?
    private var singleDuration: Double { closing + held + opening }
    var duration: Double { singleDuration + (repeatPause.map { $0 + singleDuration } ?? 0) }
    var openness: Double {
        var age = age
        if let repeatPause, age >= singleDuration { age -= singleDuration + repeatPause }
        if age < 0 { return 1 }
        if age < closing { return 1 - age / closing }
        if age < closing + held { return 0 }
        return clamp((age - closing - held) / opening, 0, 1)
    }
}

private struct QuietMoment: Sendable {
    var age = 0.0
    let duration: Double
    var look = Point.zero
    var compression = 0.0
    var lean = 0.0
    var weight: Double {
        // Slow entry, a brief pause, then a longer return to the curious peek.
        let ramp = clamp(min(age / (duration * 0.3), (duration - age) / (duration * 0.45)), 0, 1)
        return ramp * ramp * (3 - 2 * ramp)
    }
}

/// SplitMix64 keeps randomness local and supports every seed, including zero.
private struct IdleRandom: Sendable {
    var state: UInt64
    mutating func value(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E3779B97F4A7C15
        var bits = state
        bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
        bits ^= bits >> 31
        let unit = Double(bits >> 11) / 9_007_199_254_740_992
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
