import AppKit
import QuartzCore

/// The only continuous clock in the app. No timers inside core or rendering.
@MainActor final class ScreenFrameClock: NSObject {
    var onTick: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var previousTime: Double?
    private var maximumRate: Float = 60
    func bind(to screen: NSScreen, rate: Float) {
        stop(); maximumRate = Float(screen.maximumFramesPerSecond)
        link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        setRate(rate)
    }
    func setRate(_ rate: Float) {
        previousTime = nil
        guard let link else { return }
        link.isPaused = rate <= 0
        if rate > 0 {
            let cadence = min(rate, maximumRate)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: cadence, maximum: cadence, preferred: cadence)
        }
    }
    func stop() { link?.invalidate(); link = nil; previousTime = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let previous = previousTime
        self.previousTime = now
        // Set the baseline before invoking the runtime, which may pause/rebind
        // this clock from inside its callback.
        if let previous { onTick?(max(0, now - previous)) }
    }
}
