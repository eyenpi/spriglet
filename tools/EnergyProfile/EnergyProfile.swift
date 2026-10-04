import AppKit
import CompanionCore
import CompanionRendering
import Darwin
import QuartzCore

private enum ProfileError: Error { case usage, allocation, systemCall }

private extension ContinuousClock.Instant {
    var elapsedSeconds: Double {
        let elapsed = duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

private struct Options {
    let native: Bool
    let duration: Double
    let lowPower: Bool
    let rate: Float?
    let controls: Bool
    init(_ arguments: [String]) throws {
        guard arguments.count >= 2, ["--native", "--workload"].contains(arguments[0]),
              let duration = Double(arguments[1]), duration.isFinite, duration >= 1, duration <= 86_400 else {
            throw ProfileError.usage
        }
        native = arguments[0] == "--native"; self.duration = duration
        var lowPower = false, controls = false, rate: Float?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--low-power": lowPower = true
            case "--controls": controls = true
            case "--rate":
                index += 1
                guard index < arguments.count, let value = Float(arguments[index]),
                      value.isFinite, value >= 1, value <= 60 else { throw ProfileError.usage }
                rate = value
            default: throw ProfileError.usage
            }
            index += 1
        }
        guard !controls || (native && !lowPower && rate == nil) else { throw ProfileError.usage }
        self.lowPower = lowPower; self.rate = rate; self.controls = controls
    }
    func cadence(for snapshot: CompanionSnapshot) -> Float {
        var conditions = RuntimeConditions()
        conditions.lowPower = lowPower
        return rate ?? conditions.frameRate(presence: snapshot.presence, phase: snapshot.phase)
    }
}

/// Constant-size counters. Sampling never retains per-frame objects or images.
@MainActor private final class Measurements {
    private let start = ContinuousClock.now
    private var previousWall = 0.0
    private var previousCPU = 0.0
    private var previousFrames = 0
    private var previousDraws = 0
    private var previousDrawTime = 0.0
    var frames = 0
    private var draws = 0
    private var drawTime = 0.0
    init() throws {
        previousCPU = try cpuTime()
        print("wall_seconds,simulation_seconds,frames,draws,draws_per_second,cpu_percent,mean_draw_ms,resident_bytes,footprint_bytes,live_malloc_bytes,live_malloc_blocks")
        fflush(stdout)
    }
    func drew(in seconds: Double) { draws += 1; drawTime += seconds }
    func sample(simulationTime: Double) throws {
        let now = start.elapsedSeconds, cpu = try cpuTime(), elapsed = now - previousWall
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ProfileError.systemCall }
        var malloc = malloc_statistics_t()
        malloc_zone_statistics(nil, &malloc)
        let intervalDraws = draws - previousDraws
        let meanDraw = intervalDraws > 0 ? (drawTime - previousDrawTime) / Double(intervalDraws) * 1000 : 0
        print(String(format: "%.3f,%.3f,%d,%d,%.3f,%.3f,%.4f,%llu,%llu,%llu,%u",
                     now, simulationTime, frames - previousFrames, intervalDraws,
                     Double(intervalDraws) / elapsed, (cpu - previousCPU) / elapsed * 100, meanDraw,
                     info.resident_size, info.phys_footprint, UInt64(malloc.size_in_use), malloc.blocks_in_use))
        fflush(stdout)
        previousWall = now; previousCPU = cpu; previousFrames = frames
        previousDraws = draws; previousDrawTime = drawTime
    }
    private func cpuTime() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProfileError.systemCall }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

@MainActor private func workload(_ options: Options) throws {
    var engine = CompanionEngine(scene: .preview)
    let renderer = MallowRenderer(), metrics = try Measurements()
    // Reuse the small 2x panel-sized surface. Each frame has its own autorelease
    // pool, as AppKit's event loop does; PNG encoding is outside this measurement.
    guard let surface = CGContext(data: nil, width: Int(WindowGeometry.width * 2), height: Int(WindowGeometry.height * 2),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProfileError.allocation }
    let graphics = NSGraphicsContext(cgContext: surface, flipped: true)
    let display = engine.snapshot.scene.bounds
    let window = WindowGeometry.desiredFrame(feet: engine.snapshot.windowAnchor, display: display)
    let drawingOrigin = WindowGeometry.drawingOrigin(window: window, display: display)
    surface.translateBy(x: 0, y: WindowGeometry.height * 2); surface.scaleBy(x: 2, y: -2)
    surface.translateBy(x: drawingOrigin.x, y: drawingOrigin.y)
    let rate = Double(options.cadence(for: engine.snapshot)), count = Int(options.duration * rate)
    for index in 0..<count {
        autoreleasepool {
            engine.advance(by: 1 / rate)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            surface.clear(CGRect(x: -drawingOrigin.x, y: -drawingOrigin.y, width: WindowGeometry.width, height: WindowGeometry.height))
            let started = CACurrentMediaTime(); renderer.draw(engine.snapshot)
            metrics.drew(in: CACurrentMediaTime() - started); metrics.frames += 1
            NSGraphicsContext.restoreGraphicsState()
        }
        if (index + 1) % Int(rate * 60) == 0 { try metrics.sample(simulationTime: engine.time) }
    }
    try metrics.sample(simulationTime: engine.time)
}

/// A finite native session shares the real panel, view and screen-bound clock.
/// It deliberately leaves input out so mouse activity cannot skew idle results.
@MainActor private final class NativeSession: NSObject, NSApplicationDelegate {
    private let options: Options
    private let host = CompanionWindowHost()
    private let clock = ScreenFrameClock()
    private var engine: CompanionEngine?
    private var metrics: Measurements?
    private var sampleTimer: Timer?
    private var began: ContinuousClock.Instant?
    private var nextSample = 0.0
    init(options: Options) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let screen = NSScreen.main else { throw ProfileError.systemCall }
            let context = DisplayContext(screen: screen), scene = context.scene
            // Place the measured companion beside the real one, without touching
            // the user's running app. Geometry and backing scale otherwise match.
            let home = Rect(x: max(0, scene.home.minX - 240), y: scene.home.minY, width: scene.home.width, height: scene.home.height)
            let engine = CompanionEngine(scene: SceneGeometry(bounds: scene.bounds, home: home, floor: scene.floor,
                                                             scale: scene.scale, hasHardwareNotch: scene.hasHardwareNotch))
            self.engine = engine
            let metrics = try Measurements(); self.metrics = metrics
            host.onDraw = { [weak metrics] seconds in metrics?.drew(in: seconds) }
            host.attach(context: context, snapshot: engine.snapshot)
            host.setVisible(true)
            clock.onTick = { [weak self] elapsed in
                guard let self else { return }
                self.engine?.advance(by: elapsed)
                self.metrics?.frames += 1
                if let snapshot = self.engine?.snapshot {
                    self.host.update(snapshot: snapshot, capturesPointer: false, pointer: Point(x: -1000, y: -1000))
                }
            }
            began = .now; nextSample = min(10, options.duration)
            clock.bind(to: screen, rate: options.cadence(for: engine.snapshot))
            sampleTimer = Timer.scheduledTimer(timeInterval: min(1, options.duration), target: self,
                                              selector: #selector(sample), userInfo: nil, repeats: true)
        } catch { fail(error) }
    }
    @objc private func sample() {
        guard let began else { return }
        let now = began.elapsedSeconds
        guard now >= nextSample || now >= options.duration else { return }
        do { try metrics?.sample(simulationTime: engine?.time ?? 0) } catch { fail(error); return }
        nextSample = now + 10
        if now >= options.duration { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        sampleTimer?.invalidate(); sampleTimer = nil
        clock.stop(); host.close(); engine = nil
    }
    private func fail(_ error: Error) {
        FileHandle.standardError.write(Data("Energy profile failed: \(error)\n".utf8))
        sampleTimer?.invalidate(); clock.stop(); host.close(); exit(1)
    }
}

/// Profiles the complete production runtime and its controls in a disposable
/// preference domain. The finite tool owns all sampling and scripted input.
@MainActor private final class ControlsSession: NSObject, NSApplicationDelegate {
    private let options: Options
    private let suite = "dev.spriglet.controls-profile.\(UUID().uuidString)"
    private var controls: AppDelegate?
    private var runtime: CompanionRuntime?
    private let host = CompanionWindowHost()
    private let clock = ScreenFrameClock()
    private var metrics: Measurements?
    private var timer: Timer?
    private var began: ContinuousClock.Instant?
    private var nextSample = 10.0
    private var phase = 0
    private let previousApp = NSWorkspace.shared.frontmostApplication
    init(options: Options) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
        do {
            let metrics = try Measurements(); self.metrics = metrics
            host.onDraw = { [weak metrics] in metrics?.drew(in: $0) }
            let introduction = IntroductionPreferences(defaults: defaults); introduction.recordDismissal()
            let runtime = CompanionRuntime(clock: clock, host: host, introductionPreferences: introduction,
                                           preferenceStore: PreferenceStore(defaults: defaults))
            let controls = AppDelegate(runtime: runtime)
            self.runtime = runtime; self.controls = controls
            controls.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            controls.applicationDidFinishLaunching(notification)
            let runtimeTick = clock.onTick
            clock.onTick = { [weak metrics] elapsed in metrics?.frames += 1; runtimeTick?(elapsed) }
            began = .now
            FileHandle.standardError.write(Data("Controls profile: 30-second phases of idle, Settings, paused, hidden, recovered and repeated controls. System power/motion policy stays live; login registration is only read.\n".utf8))
            timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        } catch { fail(error) }
    }
    @objc private func sample() {
        guard let began else { return }
        let now = began.elapsedSeconds
        if now >= nextSample || now >= options.duration {
            let simulationTime = NSApp.windows.compactMap { ($0.contentView as? CompanionView)?.snapshot.time }.first ?? 0
            do { try metrics?.sample(simulationTime: simulationTime) } catch { fail(error); return }
            nextSample = now + 10
        }
        if now >= options.duration { NSApp.terminate(nil); return }
        let nextPhase = Int(now / 30) % 6
        guard nextPhase != phase else { return }; phase = nextPhase
        switch phase {
        case 0: controls?.perform(.bringHome); runtime?.setPaused(false)
        case 1: controls?.perform(.settings)
        case 2: runtime?.setPaused(true)
        case 3: runtime?.setVisible(false)
        case 4:
            NSApp.windows.first { $0.title == AppText.settingsTitle }?.close()
            controls?.perform(.bringHome); runtime?.setPaused(false)
        default:
            for _ in 0..<20 {
                controls?.perform(.settings)
                NSApp.windows.first { $0.title == AppText.settingsTitle }?.close()
                runtime?.setPaused(true); runtime?.setVisible(false)
                controls?.perform(.bringHome); runtime?.setPaused(false)
            }
        }
        FileHandle.standardError.write(Data("Controls profile phase \(phase) at \(Int(now))s\n".utf8))
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        controls?.applicationWillTerminate(notification); controls = nil; runtime = nil; metrics = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        if let previousApp { NSApp.yieldActivation(to: previousApp); previousApp.activate() }
    }
    private func fail(_ error: Error) {
        FileHandle.standardError.write(Data("Controls profile failed: \(error)\n".utf8))
        applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); exit(1)
    }
}

@main private enum EnergyProfile {
    @MainActor static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            if options.native {
                let session: any NSApplicationDelegate = options.controls ? ControlsSession(options: options) : NativeSession(options: options)
                app.delegate = session
                withExtendedLifetime(session) { app.run() }
            } else { try workload(options) }
        } catch {
            FileHandle.standardError.write(Data("Usage: companion-energy --native WALL_SECONDS [--controls] | --workload SIMULATED_SECONDS [--low-power] [--rate FPS]\nError: \(error)\n".utf8))
            exit(2)
        }
    }
}
