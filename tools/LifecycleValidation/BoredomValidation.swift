import AppKit
import CompanionCore

@MainActor enum BoredomValidation {
    static func run(screen: NSScreen) throws {
        let suite = "dev.spriglet.boredom-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = DisplayContext(screen: screen)
        let environment = DesktopEnvironment(displays: { [context] })
        let clock = ScreenFrameClock(), host = CompanionWindowHost()
        var pointer = Point(x: -1000, y: -1000)
        let runtime = CompanionRuntime(environment: environment, clock: clock, host: host,
                                       preferenceStore: PreferenceStore(defaults: defaults),
                                       boredomTiming: BoredomTiming(threshold: 1, cooldown: 2), idleSeed: 42,
                                       leftButtonIsDown: { true }, pointerLocation: { pointer })
        runtime.start()
        defer { runtime.stop() }
        // Semantic conditions isolate behavior from the test Mac's current supply.
        var conditions = RuntimeConditions()
        environment.onConditionsChanged?(conditions)
        let panel = try LifecycleValidation.visiblePanel()
        func frame() -> CompanionSnapshot { LifecycleValidation.view(panel).snapshot }
        func advance(_ seconds: Double) {
            for _ in 0..<Int(seconds * 20) { clock.onTick?(0.05) }
        }
        advance(1.2)
        try LifecycleValidation.require(frame().idleMoment != nil, "Runtime did not perform the Core idle request")
        try LifecycleValidation.require(frame().presence == .peek && frame().phase == .hanging, "Idle changed interaction or physics phase")
        let point = frame().hitBounds.center
        pointer = context.globalPoint(scene: point)
        clock.onTick?(0.05)
        try LifecycleValidation.require(frame().idleMoment == nil, "Hover did not interrupt the moment")
        host.onInput?(.pointerPressed(frame().hitBounds.center))
        host.onInput?(.pointerDragged(point + Point(x: 30, y: 30)))
        clock.onTick?(0.05)
        try LifecycleValidation.require(frame().phase == .held, "Idle interruption broke native drag capture")
        host.onInput?(.pointerReleased(point + Point(x: 30, y: 30)))
        runtime.perform(.returnHome)
        pointer = Point(x: -1000, y: -1000)
        advance(4)
        try LifecycleValidation.require(frame().idleMoment != nil, "Fresh quiet period did not resume idle scheduling")
        conditions.onBattery = true; environment.onConditionsChanged?(conditions)
        try LifecycleValidation.require(frame().idleMoment == nil, "Switching to battery did not stop idle")
        advance(10)
        try LifecycleValidation.require(frame().idleMoment == nil, "Battery launched an idle moment")
        conditions.onBattery = false; conditions.lowPower = true; environment.onConditionsChanged?(conditions)
        advance(10)
        try LifecycleValidation.require(frame().idleMoment == nil, "Low Power Mode launched an idle moment")
        conditions.lowPower = false; environment.onConditionsChanged?(conditions)
        advance(1.2)
        try LifecycleValidation.require(frame().idleMoment != nil, "AC recovery did not start after a fresh threshold")
        runtime.setPaused(true)
        let frozen = frame().time
        advance(20)
        try LifecycleValidation.require(frame().time == frozen, "Pause advanced the boredom clock")
        runtime.setPaused(false)
        runtime.setVisible(false); advance(20); runtime.setVisible(true)
        try LifecycleValidation.require(frame().idleMoment == nil, "Hide/recovery retained idle work")
        try LifecycleValidation.assertHome(panel)
        print("Native boredom routing passed: hover, drag, battery/Low Power gates, pause and recovery.")
    }
}
