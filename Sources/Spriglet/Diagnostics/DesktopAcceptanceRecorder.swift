import AppKit
import CryptoKit

/// Opt-in acceptance evidence from the real app. This never observes global
/// keyboard/mouse input, changes a system setting, or synthesizes an event.
@MainActor
final class DesktopAcceptanceRecorder {
    private let runtime: PetRuntime
    private let output: URL
    private let started = Date()
    private let executableSHA256: String?
    private var events: [Event] = []
    private var previous: Snapshot?
    private var tokens: [NotificationCenter.ObservationToken] = []
    private var samplingTask: Task<Void, Never>?
    private var truncated = false
    private var writeFailed = false

    static var outputURL: URL? {
        guard CommandLine.arguments.contains("--desktop-acceptance") else { return nil }
        // Stay inside the app sandbox. The test runner can copy this report
        // afterward; no broad file entitlement or security-scoped grant is needed.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("SprigletDesktopAcceptance", isDirectory: true)
            .appendingPathComponent("current.json")
    }

    init(runtime: PetRuntime, output: URL) {
        self.runtime = runtime
        self.output = output
        executableSHA256 = Bundle.main.executableURL.flatMap { try? Data(contentsOf: $0) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    func start() {
        let location = "Desktop acceptance report: \(output.path)\n"
        FileHandle.standardError.write(Data(location.utf8))
        runtime.desktop.onInputEvent = { [weak self] name in self?.record("input.\(name)") }
        observeWorkspace()
        record("started")
        // Sampling exists only in this explicit diagnostic mode. It records
        // changes, not idle ticks, and must not be used for energy measurements.
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.record("state-changed", onlyIfChanged: true)
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        runtime.desktop.onInputEvent = nil
        tokens.removeAll()
        record("stopped")
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.DidActivateApplicationMessage.self) { [weak self] _ in
            self?.record("workspace.application-activated")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ActiveSpaceDidChangeMessage.self) { [weak self] _ in
            await self?.record("workspace.active-space-changed")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.WillSleepMessage.self) { [weak self] _ in
            self?.record("workspace.will-sleep")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.DidWakeMessage.self) { [weak self] _ in
            self?.record("workspace.did-wake")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ScreensDidSleepMessage.self) { [weak self] _ in
            await self?.record("workspace.screens-did-sleep")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.ScreensDidWakeMessage.self) { [weak self] _ in
            await self?.record("workspace.screens-did-wake")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.SessionDidResignActiveMessage.self) { [weak self] _ in
            self?.record("workspace.session-resigned-active")
        })
        tokens.append(center.addObserver(of: workspace, for: NSWorkspace.SessionDidBecomeActiveMessage.self) { [weak self] _ in
            self?.record("workspace.session-became-active")
        })
        tokens.append(NotificationCenter.default.addObserver(of: NSApplication.shared, for: AcceptanceScreensChanged.self) { [weak self] _ in
            self?.record("application.screen-parameters-changed")
        })
    }

    private func record(_ reason: String, onlyIfChanged: Bool = false) {
        guard events.count < 2_000 else {
            if !truncated { truncated = true; write() }
            samplingTask?.cancel()
            return
        }
        let state = snapshot()
        guard !onlyIfChanged || state != previous else { return }
        previous = state
        events.append(Event(time: Date(), reason: reason, state: state))
        write()
    }

    private func snapshot() -> Snapshot {
        let desktop = runtime.desktop!
        let panel = desktop.panel
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let foreground: String
        switch frontmost {
        case Bundle.main.bundleIdentifier: foreground = "spriglet"
        case "dev.spriglet.DesktopValidation": foreground = "acceptance-receiver"
        default: foreground = "other-application"
        }
        let samples: [(String, CGPoint)] = [
            ("bottom-left-clear", CGPoint(x: 0.01, y: 0.01)),
            ("bottom-right-clear", CGPoint(x: 0.99, y: 0.01)),
            ("top-left-clear", CGPoint(x: 0.01, y: 0.99)),
            ("top-right-clear", CGPoint(x: 0.99, y: 0.99)),
            ("body", CGPoint(x: 0.50, y: 0.45)),
            ("ground-region", CGPoint(x: 0.50, y: 0.105)),
            ("opaque-asymmetric-region", CGPoint(x: 0.28236607142857145, y: 0.4520089285714286)),
            ("clear-asymmetric-region", CGPoint(x: 0.28236607142857145, y: 0.5479910714285714))
        ]
        let routing = samples.map { name, unit in
            let local = CGPoint(x: unit.x * runtime.renderer.bounds.width, y: unit.y * runtime.renderer.bounds.height)
            let windowPoint = runtime.renderer.convert(local, to: nil)
            let screenPoint = panel.convertPoint(toScreen: windowPoint)
            return Routing(name: name, localPoint: [local.x, local.y], screenPoint: [screenPoint.x, screenPoint.y],
                           localBodyHit: runtime.renderer.containsPet(at: local),
                           nativeMouseDownQuerySelectsPet: NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == panel.windowNumber)
        }
        return Snapshot(
            status: runtime.status, foreground: foreground,
            flags: ["panelVisible": panel.isVisible, "panelOnActiveSpace": panel.isOnActiveSpace,
                    "panelOcclusionVisible": panel.occlusionState.contains(.visible),
                    "panelKey": panel.isKeyWindow, "panelMain": panel.isMainWindow,
                    "appActive": NSApp.isActive, "hidden": runtime.isHidden, "paused": runtime.isPaused,
                    "clickThrough": runtime.clickThrough, "allSpaces": runtime.allSpaces,
                    "animating": runtime.renderer.isAnimating, "moving": desktop.isMoving,
                    "displayLinkActive": runtime.renderer.hasActiveDisplayLink,
                    "scheduledBehavior": runtime.hasScheduledBehavior, "assetAvailable": runtime.characterIssue == nil],
            counters: ["submittedFrames": runtime.renderer.submittedFrameCount,
                       "displayLinkCallbacks": runtime.renderer.displayLinkCallbackCount,
                       "movementFrames": desktop.movementTickCount, "automaticActions": runtime.automaticActionCount],
            panelFrame: Self.rect(panel.frame),
            effectiveOrigin: [desktop.effectiveOrigin.x, desktop.effectiveOrigin.y],
            imageLayerOffset: [runtime.renderer.actualImageLayerOffset.x, runtime.renderer.actualImageLayerOffset.y],
            displayName: panel.screen?.localizedName,
            savedHomeIsCurrentDisplay: desktop.savedPlacement.map { $0.displayUUID == desktop.currentPlacement?.displayUUID },
            displays: NSScreen.screens.map { Display(name: $0.localizedName, frame: Self.rect($0.frame),
                                                     visibleFrame: Self.rect($0.visibleFrame), backingScale: $0.backingScaleFactor) },
            routing: routing
        )
    }

    private static func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let report = Report(started: started, executableSHA256: executableSHA256, truncated: truncated, events: events)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch {
            if !writeFailed { print("Desktop acceptance recorder could not write its report.") }
            writeFailed = true
        }
    }

    private struct Report: Encodable {
        let kind = "spriglet-desktop-acceptance-observations"
        let interpretation = "Own-app event receipts and state observations only. Mouse-down window queries predict routing; they do not prove delivery. Human hardware actions and app-targeted automation must be identified separately in the acceptance report. No typed content, global input, other-app identities, serials, display UUIDs, or screenshots are recorded. Diagnostic sampling is enabled; these are not energy measurements."
        let started: Date
        let executableSHA256: String?
        let truncated: Bool
        let events: [Event]
    }
    private struct Event: Encodable { let time: Date; let reason: String; let state: Snapshot }
    private struct Display: Codable, Equatable {
        let name: String; let frame: [Double]; let visibleFrame: [Double]; let backingScale: Double
    }
    private struct Routing: Codable, Equatable {
        let name: String; let localPoint: [Double]; let screenPoint: [Double]
        let localBodyHit: Bool; let nativeMouseDownQuerySelectsPet: Bool
    }
    private struct Snapshot: Encodable, Equatable {
        let status: String; let foreground: String
        let flags: [String: Bool]; let counters: [String: UInt64]
        let panelFrame: [Double]; let effectiveOrigin: [Double]; let imageLayerOffset: [Double]
        let displayName: String?; let savedHomeIsCurrentDisplay: Bool?
        let displays: [Display]; let routing: [Routing]
    }
}

private struct AcceptanceScreensChanged: NotificationCenter.MainActorMessage {
    typealias Subject = NSApplication
    static var name: Notification.Name { NSApplication.didChangeScreenParametersNotification }
    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}
