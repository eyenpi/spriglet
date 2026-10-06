import AppKit
import CompanionCore

/// Native integration acceptance using the Mac's current display arrangement.
/// Pointer coordinates are delivered through the production host callback so
/// this checks real AppKit panels, display measurements, runtime dispatch and
/// disposable persistence without synthesizing or posting OS mouse events.
@MainActor enum MultiMonitorValidation {
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
