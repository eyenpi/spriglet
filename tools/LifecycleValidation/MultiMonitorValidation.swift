import AppKit
import CompanionCore

/// Native integration acceptance using the Mac's current display arrangement.
/// Pointer coordinates are delivered through the production host callback so
/// this checks real AppKit panels, display measurements, runtime dispatch and
/// disposable persistence without synthesizing or posting OS mouse events.
@MainActor enum MultiMonitorValidation {
    static func framesWithinNativeTolerance(_ actual: Rect, _ expected: Rect) -> Bool {
        let tolerance = 1e-8
        return abs(actual.minX - expected.minX) <= tolerance
            && abs(actual.minY - expected.minY) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
    }
    static func pointsWithinNativeTolerance(_ actual: Point, _ expected: Point) -> Bool {
        abs(actual.x - expected.x) <= 1e-8 && abs(actual.y - expected.y) <= 1e-8
    }
    static func verifyFrameComparisonTolerance() throws {
        let expected = Rect(x: 528.0000000000009, y: 982, width: 176, height: 144)
        let appKitRounded = Rect(x: 528, y: 982, width: 176, height: 144)
        let beyondTolerance = Rect(x: expected.x + 2e-8, y: expected.y,
                                   width: expected.width, height: expected.height)
        guard framesWithinNativeTolerance(appKitRounded, expected),
              !framesWithinNativeTolerance(beyondTolerance, expected) else {
            throw Failure.message("Frame comparison must accept the observed subpixel rounding and reject 2e-8pt")
        }
        print("Window-free native comparison passed: 9.1e-13pt delta accepted, 2e-8pt rejected, tolerance=1e-8pt.")
    }
    static func runPlacementFrame() throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX < 0 && $0.frame.minY > 0 }) else {
            throw Failure.message("No measured upper-left display is connected; placement fixture did not run")
        }
        let context = DisplayContext(screen: screen).placingHome(size: .small, location: .automatic)
        let suite = "dev.spriglet.lifecycle-validation.placement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        _ = PreferenceStore(defaults: defaults).load()
        defer { defaults.removePersistentDomain(forName: suite) }

        var engine = CompanionEngine(scene: context.scene, idleSeed: 7)
        let initial = engine.snapshot, hit = engine.snapshot.hitBounds
        guard let press = stride(from: hit.minY, through: hit.maxY, by: 1).flatMap({ y in
            stride(from: hit.minX, through: hit.maxX, by: 1).map { Point(x: $0, y: y) }
        }).first(where: initial.contains) else {
            throw Failure.message("Frozen production engine snapshot had no hit point")
        }
        engine.send(.pointerPressed(press))
        let target = Point(x: 616 - context.frame.minX, y: context.frame.maxY - 994)
        let endpoint = press + (target - initial.feet)
        engine.send(.pointerDragged(endpoint))
        for _ in 0..<120 { engine.advance(by: 1 / 60.0) }
        engine.send(.pointerReleased(endpoint))
        for _ in 0..<120 { engine.advance(by: 1 / 60.0) }
        let snapshot = engine.snapshot
        guard snapshot.phase != .held, !engine.hasPointerCapture, snapshot.dragGeometry == nil else {
            throw Failure.message("Frozen snapshot retained capture or transfer state: \(snapshot.phase)")
        }
        let requested = WindowGeometry.desiredFrame(feet: snapshot.windowAnchor, display: context.frame,
                                                    scale: snapshot.scene.scale, visibleBounds: snapshot.hitBounds)
        let contained = WindowGeometry.containedFrame(requested, in: context.frame)
        guard requested != contained else {
            throw Failure.message("Production frozen frame did not exercise R→C: R=\(requested), D=\(context.frame)")
        }

        let host = CompanionWindowHost()
        defer { host.close() }
        host.attach(context: context, snapshot: snapshot)
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == AppText.companionName }),
              let view = panel.contentView as? CompanionView else {
            throw Failure.message("Production panel/view was not registered after attach")
        }
        let identity = ObjectIdentifier(panel), windowID = panel.windowNumber
        func rect(_ frame: NSRect) -> Rect { Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure.message(message) }
        }
        func recordFrame(_ stage: String, requested expected: Rect, capturesPointer: Bool) {
            let actual = rect(panel.frame), origin = view.drawingOrigin
            let local = NSPoint(x: snapshot.feet.x + origin.x, y: snapshot.feet.y + origin.y)
            let inWindow = view.convert(local, to: nil)
            let onScreen = panel.convertPoint(toScreen: inWindow)
            let back = view.convert(panel.convertPoint(fromScreen: onScreen), from: nil)
            let global = Point(x: actual.minX + snapshot.feet.x + origin.x,
                               y: actual.maxY - snapshot.feet.y - origin.y)
            let expectedGlobal = Point(x: context.frame.minX + snapshot.feet.x,
                                       y: context.frame.maxY - snapshot.feet.y)
            let delta = Point(x: actual.x - expected.x, y: actual.y - expected.y)
            let line = "PLACEMENT_FRAME stage=\(stage) R=\(requested) C=\(contained) expectedStage=\(expected) D=\(context.frame) A=\(actual) "
                + "A_equals_expected=\(actual == expected) A_within_1e-8=\(Self.framesWithinNativeTolerance(actual, expected)) A_delta=\(delta) A_inside_D=\(actual.minX >= context.frame.minX && actual.maxX <= context.frame.maxX && actual.minY >= context.frame.minY && actual.maxY <= context.frame.maxY) "
                + "screenID=\(context.id) panelScreen=\(String(describing: panel.screen?.frame)) phase=\(snapshot.phase) capturesPointer=\(capturesPointer) dragGeometryNil=\(snapshot.dragGeometry == nil) "
                + "panelID=\(panel.windowNumber) panelFrame=\(panel.frame) contentFrame=\(String(describing: panel.contentView?.frame)) viewFrame=\(view.frame) backingScale=\(panel.backingScaleFactor) origin=\(origin) "
                + "feetScene=\(snapshot.feet) feetGlobal=\(global) expectedFeetGlobal=\(expectedGlobal) nativeRoundTrip=\(back)"
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            try? FileHandle.standardOutput.synchronize()
        }
        func checkCoordinates(panelMustBelongToSelectedDisplay: Bool) throws {
            let actual = rect(panel.frame), origin = view.drawingOrigin
            try require(view.frame.width == WindowGeometry.width * context.scene.scale
                        && view.frame.height == WindowGeometry.height * context.scene.scale,
                        "Native view dimensions changed during R/C transitions")
            try require(view.context.hasSameLayout(as: context),
                        "Active logical display or character scene changed during R/C transitions")
            guard let actualScreen = panel.screen else {
                throw Failure.message("Panel has no screen affiliation during R/C transitions")
            }
            let actualBackingScale = panel.backingScaleFactor
            try require(actualBackingScale.isFinite && actualBackingScale > 0
                        && abs(actualBackingScale - actualScreen.backingScaleFactor) <= 1e-8,
                        "Panel backing scale does not match its actual AppKit screen")
            if panelMustBelongToSelectedDisplay {
                try require(actual.minX >= context.frame.minX && actual.maxX <= context.frame.maxX
                            && actual.minY >= context.frame.minY && actual.maxY <= context.frame.maxY,
                            "Contained C frame is outside the selected logical display")
                try require(DisplayContext(screen: actualScreen).isSameLogicalDisplay(as: context)
                            && actualScreen.frame == screen.frame
                            && abs(actualBackingScale - screen.backingScaleFactor) <= 1e-8,
                            "Contained C frame is not affiliated with the selected display/backing scale")
            }
            let backingProbe = view.convertToBacking(NSRect(x: 0, y: 0, width: 10, height: 10))
            try require(abs(backingProbe.width - 10 * actualBackingScale) <= 1e-8
                        && abs(backingProbe.height - 10 * actualBackingScale) <= 1e-8,
                        "View backing conversion disagrees with the panel's actual screen scale")
            for point in [snapshot.feet, snapshot.geometry.bounds.center] {
                let global = Point(x: actual.minX + point.x + origin.x,
                                   y: actual.maxY - point.y - origin.y)
                try require(Self.pointsWithinNativeTolerance(
                    global, Point(x: context.frame.minX + point.x, y: context.frame.maxY - point.y)),
                            "Actual-frame compensation changed a global scene point")
            }
            let local = NSPoint(x: snapshot.feet.x + origin.x, y: snapshot.feet.y + origin.y)
            let inWindow = view.convert(local, to: nil)
            let screenPoint = panel.convertPoint(toScreen: inWindow)
            let backInView = view.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
            try require(abs(backInView.x - local.x) <= 1e-8 && abs(backInView.y - local.y) <= 1e-8,
                        "Native screen event coordinate round trip changed a scene point")
            try require(panel.windowNumber == windowID && ObjectIdentifier(panel) == identity,
                        "R/C transition replaced the native panel")
            let accessibility = view.accessibilityFrame()
            try require(abs(accessibility.minX - (context.frame.minX + snapshot.hitBounds.minX)) <= 1e-8
                        && abs(accessibility.maxY - (context.frame.maxY - snapshot.hitBounds.minY)) <= 1e-8,
                        "Accessibility frame changed with panel placement")
        }

        recordFrame("eligible-C", requested: contained, capturesPointer: false)
        try require(Self.framesWithinNativeTolerance(rect(panel.frame), contained),
                    "Initial eligible native frame was not expected C: actual=\(rect(panel.frame)), R=\(requested), C=\(contained), D=\(context.frame)")
        try checkCoordinates(panelMustBelongToSelectedDisplay: true)
        host.update(snapshot: snapshot, capturesPointer: true, pointer: target)
        recordFrame("capture-R", requested: requested, capturesPointer: true)
        try require(Self.framesWithinNativeTolerance(rect(panel.frame), requested), "Pointer capture did not restore original R")
        try require(!panel.ignoresMouseEvents, "Captured fixture panel became click-through")
        try checkCoordinates(panelMustBelongToSelectedDisplay: false)
        host.update(snapshot: snapshot, capturesPointer: false, pointer: Point(x: -1000, y: -1000))
        recordFrame("retired-C", requested: contained, capturesPointer: false)
        try require(Self.framesWithinNativeTolerance(rect(panel.frame), contained), "Capture retirement did not select C immediately")
        try require(panel.ignoresMouseEvents, "Unheld fixture panel stopped being click-through")
        try checkCoordinates(panelMustBelongToSelectedDisplay: true)
        try require(panel.screen?.frame == screen.frame, "Panel screen disagrees with the active display")
        print("Placement native frame fixture passed: panelID=\(windowID), screen=\(screen.frame), activeDisplay=\(context.frame), backingScale=\(panel.backingScaleFactor), R=\(requested), C=\(contained), actualC=\(rect(panel.frame)), view=\(view.frame), origin=\(view.drawingOrigin), feetGlobal=(616,994), samePanel=true. Injected no mouse events; native composition remains unverified.")
    }

    static func run() throws {
        let measured = NSScreen.screens.map(DisplayContext.init(screen:))
        var logical: [DisplayContext] = []
        for context in measured {
            if let index = logical.firstIndex(where: { $0.logicalID == context.logicalID }) {
                if context.id == context.logicalID { logical[index] = context }
            } else { logical.append(context) }
        }
        guard logical.count >= 2 else {
            throw Failure.message("Requires at least two connected logical displays; found \(logical.count). No display settings were changed.")
        }
        for context in logical {
            let global = Point(x: context.frame.midX, y: context.frame.midY)
            let local = context.scenePoint(global: global)
            guard abs(local.x - context.frame.width / 2) < 0.001,
                  abs(local.y - context.frame.height / 2) < 0.001 else { throw Failure.coordinateMismatch }
        }
        let suite = "dev.spriglet.lifecycle-validation.multimonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        let originalPreferences = store.load()
        let host = CompanionWindowHost()
        let environment = DesktopEnvironment(displays: { measured })
        let runtime = CompanionRuntime(environment: environment, host: host, preferenceStore: store,
                                       leftButtonIsDown: { true },
                                       pointerLocation: { .zero })
        defer { runtime.stop() }
        runtime.start()

        let sourcePanel = try LifecycleValidation.visiblePanel()
        let sourceView = sourcePanel.contentView as! CompanionView
        let source = sourceView.context
        guard let destination = logical.first(where: { !$0.isSameLogicalDisplay(as: source) }) else {
            throw Failure.message("Could not choose a distinct destination display")
        }
        try beginDrag(host: host, view: sourceView, context: source)
        try LifecycleValidation.require(!sourcePanel.ignoresMouseEvents,
                                        "Native panel did not capture the pointer press")
        try LifecycleValidation.require(sourceView.snapshot.phase == .held,
                                        "Pointer movement did not begin a held drag")
        let originalPanel = sourcePanel
        let originalView = sourceView
        let hostIdentity = ObjectIdentifier(sourcePanel)
        let viewIdentity = ObjectIdentifier(sourceView)
        let drop = Point(x: destination.frame.midX, y: destination.frame.midY)
        host.onPointerInput?(.dragged(drop))
        try LifecycleValidation.require(LifecycleValidation.visiblePanel() === originalPanel,
                                        "Cross-display drag replaced the native panel")
        try LifecycleValidation.require(ObjectIdentifier(LifecycleValidation.visiblePanel()) == hostIdentity,
                                        "Cross-display drag changed native host identity")
        try LifecycleValidation.require(ObjectIdentifier(LifecycleValidation.visiblePanel().contentView!) == viewIdentity,
                                        "Cross-display drag replaced the native view")
        try LifecycleValidation.require(originalView.context.isSameLogicalDisplay(as: destination),
                                        "Global pointer coordinate did not retarget to the destination display")
        try LifecycleValidation.require(originalView.snapshot.phase == .held && !originalPanel.ignoresMouseEvents,
                                        "Display transfer lost active pointer capture")
        try LifecycleValidation.require(store.load() == originalPreferences,
                                        "Home display persisted before a successful release")

        // Cancel after provisional A→B transfer. Preferences remain the
        // authority, including an Automatic nil UUID, and the runtime returns
        // to the initial saved-home context without retaining capture.
        host.onInput?(.cancelInteraction)
        let cancelledPanel = try LifecycleValidation.visiblePanel()
        let cancelledView = cancelledPanel.contentView as! CompanionView
        try LifecycleValidation.require(cancelledView.context.isSameLogicalDisplay(as: source),
                                        "Cancelling a provisional transfer did not restore the authoritative home display")
        try LifecycleValidation.require(cancelledPanel.ignoresMouseEvents && cancelledView.snapshot.phase != .held,
                                        "Cancelling a provisional transfer retained pointer capture")
        try LifecycleValidation.require(store.load() == originalPreferences
                                        && runtime.preferences == originalPreferences,
                                        "Cancelling a provisional transfer changed the saved home UUID or unrelated preferences")

        // Cross A→B→A before mouse-up. Returning to the origin is an ordinary
        // same-display release and must preserve Automatic rather than saving
        // A's current UUID.
        let roundTripPanel = try LifecycleValidation.visiblePanel()
        let roundTripView = roundTripPanel.contentView as! CompanionView
        try beginDrag(host: host, view: roundTripView, context: source)
        host.onPointerInput?(.dragged(drop))
        try LifecycleValidation.require(roundTripView.context.isSameLogicalDisplay(as: destination),
                                        "A→B round-trip did not provisionally transfer to B")
        let returnPoint = Point(x: source.frame.midX, y: source.frame.midY)
        host.onPointerInput?(.dragged(returnPoint))
        try LifecycleValidation.require(roundTripView.context.isSameLogicalDisplay(as: source),
                                        "A→B→A drag did not transfer back to its origin")
        try LifecycleValidation.require(roundTripView.snapshot.phase == .held
                                        && !roundTripPanel.ignoresMouseEvents,
                                        "Returning to the origin lost active drag capture")
        try LifecycleValidation.require(store.load() == originalPreferences,
                                        "Provisional A→B→A transfer mutated Automatic or unrelated preferences")
        host.onPointerInput?(.released(returnPoint))
        try LifecycleValidation.require(store.load() == originalPreferences,
                                        "Same-origin release converted Automatic to an explicit display")
        try LifecycleValidation.require(roundTripPanel.ignoresMouseEvents,
                                        "Same-origin release retained pointer capture")

        try beginDrag(host: host, view: roundTripView, context: source)
        host.onPointerInput?(.dragged(drop))
        try LifecycleValidation.require(roundTripView.context.isSameLogicalDisplay(as: destination)
                                        && store.load() == originalPreferences,
                                        "Successful-drop fixture did not remain provisional before mouse-up")
        host.onPointerInput?(.released(drop))
        let releasePanel = try LifecycleValidation.visiblePanel()
        try LifecycleValidation.require(releasePanel === roundTripPanel,
                                        "Successful drop recreated the native panel")
        let persisted = store.load()
        try LifecycleValidation.require(persisted.homeDisplayID == destination.persistentID,
                                        "Successful cross-display release did not save the destination UUID")
        try LifecycleValidation.require(persisted.characterSize == originalPreferences.characterSize
                                        && persisted.movementIntensity == originalPreferences.movementIntensity
                                        && persisted.homeLocation == originalPreferences.homeLocation,
                                        "Cross-display release changed unrelated preferences")
        let releasedView = releasePanel.contentView as! CompanionView
        try LifecycleValidation.require(releasedView.snapshot.scene == destination.scene,
                                        "Transferred engine did not retain destination scene geometry")
        try LifecycleValidation.require(releasePanel.ignoresMouseEvents,
                                        "Release retained whole-panel pointer capture")

        // Now Home is an explicit saved UUID. A provisional transfer away
        // followed by cancellation must restore this exact UUID/context.
        let savedHome = store.load()
        try beginDrag(host: host, view: releasedView, context: destination)
        let originDrop = Point(x: source.frame.midX, y: source.frame.midY)
        host.onPointerInput?(.dragged(originDrop))
        try LifecycleValidation.require(releasedView.context.isSameLogicalDisplay(as: source)
                                        && store.load() == savedHome,
                                        "Explicit saved-home UUID changed before a cross-display release")
        host.onInput?(.cancelInteraction)
        let explicitHomePanel = try LifecycleValidation.visiblePanel()
        let explicitHomeView = explicitHomePanel.contentView as! CompanionView
        try LifecycleValidation.require(explicitHomeView.context.isSameLogicalDisplay(as: destination),
                                        "Cancellation failed to restore the explicitly saved Home display")
        try LifecycleValidation.require(store.load() == savedHome,
                                        "Cancellation changed an explicit saved-home UUID or unrelated preference")
        try LifecycleValidation.require(explicitHomePanel.ignoresMouseEvents
                                        && explicitHomeView.snapshot.phase != .held,
                                        "Explicit-home cancellation retained pointer capture")

        let reloaded = PreferenceStore(defaults: defaults).load()
        try LifecycleValidation.require(reloaded == savedHome
                                        && reloaded.homeDisplayID == destination.persistentID,
                                        "Destination UUID did not survive preference-store reload")
        print("Multi-display native integration passed: connectedScreens=\(measured.count), logicalDisplays=\(logical.count), native panel/view identity, global-point transfer, cancel after provisional transfer, A→B→A Automatic preservation, explicit saved-home restoration, successful UUID persistence, unrelated preference preservation and reload. Pointer events were injected through the production host callback; this does not verify physical mouse delivery or seam travel.")
    }
    private static func beginDrag(host: CompanionWindowHost, view: CompanionView,
                                  context: DisplayContext) throws {
        let start = try visiblePoint(in: view.snapshot)
        host.onInput?(.pointerPressed(start))
        let global = context.globalPoint(scene: start)
        host.onPointerInput?(.dragged(Point(x: global.x + 12, y: global.y)))
    }
    private static func visiblePoint(in snapshot: CompanionSnapshot) throws -> Point {
        let bounds = snapshot.hitBounds
        for y in stride(from: bounds.minY, through: bounds.maxY, by: 2) {
            for x in stride(from: bounds.minX, through: bounds.maxX, by: 2) {
                let point = Point(x: x, y: y)
                if snapshot.contains(point) { return point }
            }
        }
        throw Failure.message("Current display snapshot has no visible hit target")
    }
    private enum Failure: Error, CustomStringConvertible {
        case coordinateMismatch
        case message(String)
        var description: String {
            switch self {
            case .coordinateMismatch: "Display center did not round-trip between global and local coordinates"
            case .message(let text): text
            }
        }
    }
}
