import AppKit
import Darwin
import SpriteKit
import SprigletCore

/// --headless creates only hidden native windows. The default mode deliberately
/// shows disposable nonactivating panels; a developer must launch it explicitly.
@main
enum RendererLifecycleCheck {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let runner = LifecycleRunner(headless: CommandLine.arguments.contains("--headless"))
        app.delegate = runner
        app.setActivationPolicy(runner.headless ? .prohibited : .accessory)
        withExtendedLifetime(runner) { app.run() }
    }
}

private struct RendererSnapshot: Codable, Equatable {
    let sceneUpdates: UInt64
    let renderCallbacks: UInt64
    let animating: Bool
    let sleeping: Bool
    let action: PetAction?
    let visible: Bool
    let appActive: Bool

    @MainActor
    init(_ renderer: PetRenderView) {
        sceneUpdates = renderer.sceneUpdateCount
        renderCallbacks = renderer.viewRenderCallbackCount
        animating = renderer.isAnimating
        sleeping = renderer.isSleeping
        action = renderer.currentAction
        visible = renderer.window?.occlusionState.contains(.visible) == true
        appActive = NSApp.isActive
    }

    func hasSameCallbacks(as other: Self) -> Bool {
        sceneUpdates == other.sceneUpdates && renderCallbacks == other.renderCallbacks
    }
}

private struct LifecycleResult: Codable {
    let name: String
    let passed: Bool
    let detail: String
    var before: RendererSnapshot?
    var after: RendererSnapshot?
}

@MainActor
private final class LifecycleRunner: NSObject, NSApplicationDelegate {
    let headless: Bool
    private var panels: [NSPanel] = []
    private var results: [LifecycleResult] = []

    init(headless: Bool) { self.headless = headless }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func run() async {
        checkCancelledInteraction()
        do {
            let (hiddenPanel, hiddenPet) = makeHost()
            hiddenPet.setSuspended(true)
            try await Task.sleep(for: .milliseconds(400))
            let hiddenStart = RendererSnapshot(hiddenPet)
            try await Task.sleep(for: .milliseconds(500))
            let hiddenEnd = RendererSnapshot(hiddenPet)
            record("hidden paused has no initial update", hiddenEnd.sceneUpdates == 0 && !hiddenEnd.animating && !hiddenEnd.visible,
                   "Host was constructed but never ordered onscreen.", after: hiddenEnd)
            record("hidden paused callbacks stay settled", hiddenEnd.hasSameCallbacks(as: hiddenStart),
                   "Two snapshots 500 ms apart; no continuous warm-up rendering.", before: hiddenStart, after: hiddenEnd)

            if !headless {
                let (coldPanel, coldPet) = makeHost()
                coldPet.setSuspended(true)
                coldPanel.orderFrontRegardless()
                try await Task.sleep(for: .seconds(1))
                let coldShown = RendererSnapshot(coldPet)
                record("cold paused first presentation", coldShown.visible && coldShown.sceneUpdates == 1 && !coldShown.animating && !coldShown.sleeping && coldShown.action == nil,
                       "A new visible paused host receives exactly one neutral scene update.", after: coldShown)
                try await Task.sleep(for: .milliseconds(750))
                let coldSettled = RendererSnapshot(coldPet)
                record("cold paused callbacks settle", coldSettled.hasSameCallbacks(as: coldShown),
                       "No continuing scene or render-delegate callbacks after initial presentation.", before: coldShown, after: coldSettled)
                coldPanel.orderOut(nil)

                hiddenPanel.orderFrontRegardless()
                try await Task.sleep(for: .seconds(1))
                let firstShow = RendererSnapshot(hiddenPet)
                record("hidden paused first show presents", firstShow.visible && firstShow.sceneUpdates == 1 && !firstShow.animating && firstShow.action == nil,
                       "Showing the previously hidden host does not require resuming animation.", before: hiddenEnd, after: firstShow)
                try await Task.sleep(for: .milliseconds(750))
                let shownSettled = RendererSnapshot(hiddenPet)
                record("shown paused callbacks settle", shownSettled.hasSameCallbacks(as: firstShow),
                       "The initial static presentation consumes no continuing callback loop.", before: firstShow, after: shownSettled)

                hiddenPet.setSuspended(false)
                try await Task.sleep(for: .milliseconds(400))
                let reactionStart = RendererSnapshot(hiddenPet)
                hiddenPet.play(.react)
                try await Task.sleep(for: .milliseconds(160))
                let reacting = RendererSnapshot(hiddenPet)
                record("reaction was active before pause", reacting.animating && reacting.sceneUpdates > reactionStart.sceneUpdates,
                       "The pause check interrupts real active scene work.", before: reactionStart, after: reacting)
                hiddenPet.setSuspended(true)
                let paused = RendererSnapshot(hiddenPet)
                try await Task.sleep(for: .milliseconds(750))
                let pausedSettled = RendererSnapshot(hiddenPet)
                record("existing reaction pauses immediately", !pausedSettled.animating && pausedSettled.action == nil && pausedSettled.hasSameCallbacks(as: paused),
                       "An already-presented renderer gets no extra scene frame when paused.", before: paused, after: pausedSettled)
                hiddenPet.setSuspended(false)
                try await Task.sleep(for: .milliseconds(750))
                let resumed = RendererSnapshot(hiddenPet)
                record("resume restores static neutral", !resumed.animating && !resumed.sleeping && resumed.action == nil && resumed.sceneUpdates > pausedSettled.sceneUpdates && !hasActions(hiddenPet),
                       "Cancelled animation does not restart; reset is applied in the next scene update.", before: pausedSettled, after: resumed)
                try await Task.sleep(for: .milliseconds(500))
                let resumedSettled = RendererSnapshot(hiddenPet)
                record("resumed neutral callbacks settle", resumedSettled.hasSameCallbacks(as: resumed),
                       "The resumed neutral pose becomes static again.", before: resumed, after: resumedSettled)
            }
        } catch {
            record("check completed without interruption", false, String(describing: error))
        }
        finish()
    }

    private func makeHost() -> (NSPanel, PetRenderView) {
        let renderer = PetRenderView(frame: NSRect(x: 0, y: 0, width: 192, height: 192))
        let panel = CheckPanel(contentRect: renderer.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Renderer lifecycle validation"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.disableSnapshotRestoration()
        panel.contentView = renderer
        if !headless { panel.center() }
        panels.append(panel)
        return (panel, renderer)
    }

    private func hasActions(_ renderer: PetRenderView) -> Bool {
        guard let scene = renderer.subviews.compactMap({ $0 as? SKView }).first?.scene else { return true }
        func containsActions(_ node: SKNode) -> Bool {
            node.hasActions() || node.children.contains(where: containsActions)
        }
        return containsActions(scene)
    }

    /// Direct responder calls test our cleanup contract. Nothing is posted to
    /// NSApplication, WindowServer, an event tap, or another process.
    private func checkCancelledInteraction() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 192))
        let input = PetInteractionView(contentView: content, hitTest: { _ in true })
        let panel = CheckPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = input
        panels.append(panel)
        var changes: [Bool] = []
        var clicks = 0
        var drags = 0
        var dragEnds = 0
        input.onUserInteractionChanged = { changes.append($0) }
        input.onClicked = { clicks += 1 }
        input.onDragged = { _, _ in drags += 1 }
        input.onDragEnded = { dragEnds += 1 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown, NSPoint(x: 60, y: 60)),
              let dragged = event(.leftMouseDragged, NSPoint(x: 80, y: 80)),
              let up = event(.leftMouseUp, NSPoint(x: 80, y: 80)) else {
            record("constructed input events", false, "AppKit returned nil while constructing local event objects.")
            return
        }
        input.mouseDown(with: down)
        input.mouseCancelled(with: down)
        input.mouseUp(with: up)
        record("cancelled press clears interaction", changes == [true, false] && clicks == 0,
               "Cancellation followed by a late mouse-up produces no click; direct handler invocation only.")
        changes.removeAll()
        input.mouseDown(with: down)
        input.mouseDragged(with: dragged)
        input.mouseCancelled(with: dragged)
        input.mouseUp(with: up)
        record("cancelled drag clears interaction", changes == [true, false] && drags == 1 && clicks == 0 && dragEnds == 0,
               "Cancelled drag is not committed by a late mouse-up; direct handler invocation only.")
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String, before: RendererSnapshot? = nil, after: RendererSnapshot? = nil) {
        results.append(LifecycleResult(name: name, passed: passed, detail: detail, before: before, after: after))
    }

    private func finish() -> Never {
        for panel in panels { panel.orderOut(nil) }
        struct Report: Codable {
            let mode: String
            let scope: String
            let results: [LifecycleResult]
        }
        let report = Report(
            mode: headless ? "headless" : "native-visible",
            scope: headless ? "Hidden own windows and direct responder calls only. Visible first-presentation checks were not run." : "Disposable native windows, callback counts, and direct responder calls. No cross-application physical input or GPU performance claim.",
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { print(String(decoding: try encoder.encode(report), as: UTF8.self)) }
        catch { print("Could not encode lifecycle results: \(error)"); exit(2) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}

@MainActor
private final class CheckPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
