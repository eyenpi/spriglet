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
    init(_ arguments: [String]) throws {
        guard arguments.count >= 2, ["--native", "--workload"].contains(arguments[0]),
              let duration = Double(arguments[1]), duration.isFinite, duration >= 1, duration <= 86_400 else {
            throw ProfileError.usage
        }
        native = arguments[0] == "--native"; self.duration = duration
        var lowPower = false, rate: Float?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--low-power": lowPower = true
            case "--rate":
                index += 1
                guard index < arguments.count, let value = Float(arguments[index]),
                      value.isFinite, value >= 1, value <= 60 else { throw ProfileError.usage }
                rate = value
            default: throw ProfileError.usage
            }
            index += 1
        }
        self.lowPower = lowPower; self.rate = rate
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
    let windowOrigin = WindowGeometry.desiredOrigin(feet: engine.snapshot.windowAnchor, display: display)
    let window = Rect(x: windowOrigin.x, y: windowOrigin.y, width: WindowGeometry.width, height: WindowGeometry.height)
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

@main private enum EnergyProfile {
    @MainActor static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            if options.native {
                let session = NativeSession(options: options); app.delegate = session
                withExtendedLifetime(session) { app.run() }
            } else { try workload(options) }
        } catch {
            FileHandle.standardError.write(Data("Usage: companion-energy --native WALL_SECONDS | --workload SIMULATED_SECONDS [--low-power] [--rate FPS]\nError: \(error)\n".utf8))
            exit(2)
        }
    }
}
