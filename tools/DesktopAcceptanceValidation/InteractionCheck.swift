import AppKit
import CryptoKit
import Darwin
import SprigletCore

/// Constructs hidden native objects and calls their handlers with local events.
/// It neither orders a window onscreen nor injects input into the desktop.
@main
enum InteractionCheck {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = InteractionRunner()
        let report = try runner.run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        if let index = CommandLine.arguments.firstIndex(of: "--output"),
           index + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
        exit(report.passed ? 0 : 1)
    }
}

private struct CheckResult: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct InteractionReport: Encodable {
    let schemaVersion = 1
    let recordedAt = Date()
    let evidenceKind = "constructed-native-handlers"
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let passed: Bool
    let checks: [CheckResult]
    let maximumDragOriginErrorPoints: Double
    let observedEventNames: [String]
    let sourceSHA256: [String: String]
    let limitations = [
        "All test windows remain hidden, with application activation prohibited.",
        "Local NSEvent values are passed directly to app handlers; they are not physical or injected desktop input.",
        "Suspension reasons are exercised directly; this does not reproduce device sleep, wake, locking, or notification delivery.",
        "Boundary coordinates exercise drag arithmetic without changing real display topology; monitor disconnect/reconnect is not simulated hardware evidence.",
        "These checks do not prove cross-process focus, transparent pixel routing, Spaces, full-screen presentation, or WindowServer/GPU output."
    ]
}

@MainActor
private final class InteractionRunner {
    private var checks: [CheckResult] = []
    private var events: [String] = []
    private var maximumDragError = 0.0

    func run() throws -> InteractionReport {
        // Registration defaults live in memory. No user or test preferences are
        // written, and the runtime's hidden startup never orders the panel in.
        let defaults = UserDefaults(suiteName: "dev.spriglet.interaction-check.\(UUID().uuidString)")!
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "preferences": [
                "isHidden": true, "isPaused": false, "clickThrough": false,
                "allSpaces": false, "autonomousBehavior": false
            ]
        ])
        defaults.register(defaults: ["dev.spriglet.preferences": payload])
        let store = PetPreferencesStore(defaults: defaults)
        precondition(store.load().isHidden)
        let runtime = PetRuntime(preferencesStore: store)
        runtime.start()
        defer { runtime.stop() }
        let desktop = runtime.desktop!
        let view = desktop.panel.contentView as! PetInteractionView
        var interacting = false
        var clicks = 0
        var settlements = 0
        let originalInteractionCallback = desktop.onUserInteractionChanged
        desktop.onUserInteractionChanged = { value in
            interacting = value
            originalInteractionCallback?(value)
        }
        desktop.onPetClicked = { clicks += 1 }
        desktop.onPlacementSettled = { _ in settlements += 1 }
        desktop.onInputEvent = { [weak self] event in self?.events.append(event) }
        // Remove the logical hidden suspension while the actual panel remains
        // ordered out, so each tested cause is independently responsible.
        runtime.setSuspension(.hidden, active: false)
        check("sample-assets-loaded", runtime.renderer.assetError == nil,
              "The hidden runtime loaded the actual bundled Acorn character.")

        for reason in [SuspensionReason.systemAsleep, .displayAsleep, .sessionInactive, .userPaused, .thermalPressure] {
            let clicksBefore = clicks
            let settlementsBefore = settlements
            let start = NSPoint(x: desktop.panel.frame.midX, y: desktop.panel.frame.midY)
            view.mouseDown(with: event(.leftMouseDown, screenPoint: start, panel: desktop.panel))
            let heldPress = interacting
            runtime.setSuspension(reason, active: true)
            let pressCancelled = !interacting
            runtime.setSuspension(reason, active: false)
            view.mouseUp(with: event(.leftMouseUp, screenPoint: start, panel: desktop.panel))
            check("\(reason.rawValue)-cancels-held-press", heldPress && pressCancelled && clicks == clicksBefore,
                  "The real runtime suspension path cleared a held press; a later release produced no click.")

            view.mouseDown(with: event(.leftMouseDown, screenPoint: start, panel: desktop.panel))
            let dragged = NSPoint(x: start.x - 20, y: start.y + 8)
            view.mouseDragged(with: event(.leftMouseDragged, screenPoint: dragged, panel: desktop.panel))
            let heldDrag = interacting
            runtime.setSuspension(reason, active: true)
            let dragCancelled = !interacting
            let originAfterCancellation = desktop.effectiveOrigin
            runtime.setSuspension(reason, active: false)
            view.mouseDragged(with: event(.leftMouseDragged,
                                         screenPoint: NSPoint(x: dragged.x + 80, y: dragged.y),
                                         panel: desktop.panel))
            view.mouseUp(with: event(.leftMouseUp, screenPoint: dragged, panel: desktop.panel))
            check("\(reason.rawValue)-cancels-held-drag",
                  heldDrag && dragCancelled && clicks == clicksBefore && settlements == settlementsBefore
                    && near(desktop.effectiveOrigin, originAfterCancellation),
                  "Suspension discarded the drag; late movement/release neither moved nor committed the panel.")
        }

        // This host has a simple local interaction area, isolating drag/window
        // geometry from the bitmap mask. It stays hidden throughout the check.
        let dragHost = PetWindowController(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 224)))
        let dragView = dragHost.panel.contentView as! PetInteractionView
        dragHost.onInputEvent = { [weak self] event in self?.events.append(event) }
        var dragSettlements = 0
        dragHost.onPlacementSettled = { _ in dragSettlements += 1 }
        let screen = NSScreen.screens.first!
        dragHost.panel.setFrameOrigin(NSPoint(x: screen.frame.maxX - 224, y: screen.visibleFrame.midY - 112))
        // Keep a fractional image origin to catch accumulation or lost offsets.
        dragHost.nudge(dx: -0.375, dy: 0.25)
        let preciseStart = dragHost.effectiveOrigin
        let pointerStart = NSPoint(x: preciseStart.x + 112, y: preciseStart.y + 112)
        dragView.mouseDown(with: event(.leftMouseDown, screenPoint: pointerStart, panel: dragHost.panel))
        let boundaryDX = screen.frame.maxX - pointerStart.x
        let deltas = [NSPoint(x: 4, y: 2),
                      NSPoint(x: boundaryDX - 1, y: 3),
                      NSPoint(x: boundaryDX + 1, y: 3),
                      NSPoint(x: boundaryDX + 25, y: -5)]
        for delta in deltas {
            let pointer = NSPoint(x: pointerStart.x + delta.x, y: pointerStart.y + delta.y)
            dragView.mouseDragged(with: event(.leftMouseDragged, screenPoint: pointer, panel: dragHost.panel))
            let expected = CGPoint(x: preciseStart.x + delta.x, y: preciseStart.y + delta.y)
            maximumDragError = max(maximumDragError, distance(dragHost.effectiveOrigin, expected))
        }
        check("drag-retains-pointer-delta-across-boundary", maximumDragError < 0.001,
              "Direct drag handlers retained the original pointer delta and fractional image offset on both sides of a display boundary coordinate.")
        let settlementsBeforeRelease = dragSettlements
        let releaseDelta = deltas.last!
        dragView.mouseUp(with: event(.leftMouseUp,
                                    screenPoint: NSPoint(x: pointerStart.x + releaseDelta.x,
                                                         y: pointerStart.y + releaseDelta.y),
                                    panel: dragHost.panel))
        let finalScreen = dragHost.panel.screen ?? screen
        let finalBounds = PetPlacement.clampedOrigin(dragHost.effectiveOrigin,
                                                     windowSize: dragHost.panel.frame.size,
                                                     visibleFrame: finalScreen.visibleFrame)
        check("drag-clamps-and-commits-on-release",
              near(dragHost.effectiveOrigin, finalBounds) && dragSettlements == settlementsBeforeRelease + 1,
              "Releasing confined the completed placement to a current visible display area and committed it once.")

        let cancelStart = NSPoint(x: dragHost.panel.frame.midX, y: dragHost.panel.frame.midY)
        var directClicks = 0
        dragHost.onPetClicked = { directClicks += 1 }
        dragView.mouseDown(with: event(.leftMouseDown, screenPoint: cancelStart, panel: dragHost.panel))
        dragView.mouseUp(with: event(.leftMouseUp, screenPoint: cancelStart, panel: dragHost.panel))
        dragView.mouseDown(with: event(.leftMouseDown, screenPoint: cancelStart, panel: dragHost.panel))
        dragView.mouseCancelled(with: event(.leftMouseDown, screenPoint: cancelStart, panel: dragHost.panel))
        _ = dragView.accessibilityPerformPress()
        check("click-and-accessibility-press-still-work", directClicks == 2,
              "An ordinary completed press and a separate accessibility press each invoke one click; cancellation invokes none.")

        let eyeHost = TopBarEyesController()
        eyeHost.panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        let eyeStart = NSPoint(x: eyeHost.panel.frame.midX, y: eyeHost.panel.frame.midY)
        var eyeDragBegins = 0
        var eyeDragProgress: [CGPoint] = []
        var eyeDragFinished: CGPoint?
        var eyeClicks = 0
        eyeHost.onDragOut = { _ in eyeDragBegins += 1 }
        eyeHost.onDragProgress = { eyeDragProgress.append($0) }
        eyeHost.onDragFinished = { eyeDragFinished = $0 }
        eyeHost.onReturn = { eyeClicks += 1 }
        eyeHost.eyes.mouseDown(with: event(.leftMouseDown, screenPoint: eyeStart, panel: eyeHost.panel))
        for offset in [20.0, 50.0, 90.0, 130.0] {
            eyeHost.eyes.mouseDragged(with: event(.leftMouseDragged,
                                                 screenPoint: NSPoint(x: eyeStart.x + offset / 2,
                                                                      y: eyeStart.y - offset), panel: eyeHost.panel))
        }
        let eyeRelease = NSPoint(x: eyeStart.x + 65, y: eyeStart.y - 130)
        eyeHost.eyes.mouseUp(with: event(.leftMouseUp, screenPoint: eyeRelease, panel: eyeHost.panel))
        check("top-bar-eyes-track-drag-until-release",
              eyeDragBegins == 1 && eyeDragProgress.count == 3
                && near(eyeDragProgress.last ?? .zero, eyeRelease)
                && near(eyeDragFinished ?? .zero, eyeRelease) && eyeClicks == 0,
              "Dragging out starts once, reports each later pointer position, and finishes at release without becoming a click.")
        eyeHost.eyes.mouseDown(with: event(.leftMouseDown, screenPoint: eyeStart, panel: eyeHost.panel))
        eyeHost.eyes.mouseUp(with: event(.leftMouseUp, screenPoint: eyeStart, panel: eyeHost.panel))
        check("top-bar-eyes-click-returns", eyeClicks == 1 && eyeDragBegins == 1,
              "A separate eye click still requests the desktop return once.")
        let expectedNames: Set<String> = ["mouseDown", "dragBegan", "mouseUp-click", "mouseUp-drag", "mouseCancelled",
                                         "accessibilityPress", "interactionCancelled"]
        check("input-entry-points-distinguishable", expectedNames.isSubset(of: Set(events)),
              "The opt-in callback distinguishes local mouse handlers, cancellation, and accessibility press without coordinates or text.")
        check("no-visible-window-or-activation", !desktop.panel.isVisible && !dragHost.panel.isVisible
                && !eyeHost.panel.isVisible && !NSApp.isActive,
              "All checks completed with every panel ordered out and the application inactive.")

        return InteractionReport(passed: checks.allSatisfy(\.passed), checks: checks,
                                 maximumDragOriginErrorPoints: maximumDragError,
                                 observedEventNames: Array(Set(events)).sorted(), sourceSHA256: try sourceHashes())
    }

    private func event(_ type: NSEvent.EventType, screenPoint: NSPoint, panel: NSPanel) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(CheckResult(name: name, passed: passed, detail: detail))
    }

    private func near(_ left: CGPoint, _ right: CGPoint) -> Bool { distance(left, right) < 0.001 }
    private func distance(_ left: CGPoint, _ right: CGPoint) -> Double {
        max(abs(left.x - right.x), abs(left.y - right.y))
    }

    private func sourceHashes() throws -> [String: String] {
        guard let index = CommandLine.arguments.firstIndex(of: "--source-root"),
              index + 1 < CommandLine.arguments.count else { return [:] }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let paths = ["Sources/Spriglet/Desktop/PetWindowController.swift",
                     "Sources/Spriglet/Desktop/PetInteractionView.swift",
                     "Sources/Spriglet/Desktop/TopBarEyesController.swift",
                     "Sources/Spriglet/App/PetRuntime.swift",
                     "tools/DesktopAcceptanceValidation/InteractionCheck.swift"]
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            return (path, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
    }
}
