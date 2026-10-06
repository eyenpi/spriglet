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
        let originalPanel = sourcePanel
        let originalView = sourceView
        let hostIdentity = ObjectIdentifier(sourcePanel)
        let viewIdentity = ObjectIdentifier(sourceView)
        let sourceStart = try visiblePoint(in: sourceView.snapshot)
        host.onInput?(.pointerPressed(sourceStart))
        try LifecycleValidation.require(!sourcePanel.ignoresMouseEvents,
                                        "Native panel did not capture the pointer press")
        let sourceGlobal = source.globalPoint(scene: sourceStart)
        host.onPointerInput?(.dragged(Point(x: sourceGlobal.x + 12, y: sourceGlobal.y)))
        try LifecycleValidation.require(sourceView.snapshot.phase == .held,
                                        "Pointer movement did not begin a held drag")
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

        host.onPointerInput?(.released(drop))
        try LifecycleValidation.require(LifecycleValidation.visiblePanel() === originalPanel,
                                        "Successful drop recreated the native panel")
        let persisted = store.load()
        try LifecycleValidation.require(persisted.homeDisplayID == destination.persistentID,
                                        "Successful cross-display release did not save the destination UUID")
        try LifecycleValidation.require(persisted.characterSize == originalPreferences.characterSize
                                        && persisted.movementIntensity == originalPreferences.movementIntensity
                                        && persisted.homeLocation == originalPreferences.homeLocation,
                                        "Cross-display release changed unrelated preferences")
        try LifecycleValidation.require(originalView.snapshot.scene == destination.scene,
                                        "Transferred engine did not retain destination scene geometry")
        try LifecycleValidation.require(originalPanel.ignoresMouseEvents,
                                        "Release retained whole-panel pointer capture")

        // A second same-display drag cancelled before release must not write
        // preferences or replace either native object.
        let sameDisplayStart = try visiblePoint(in: originalView.snapshot)
        host.onInput?(.pointerPressed(sameDisplayStart))
        host.onInput?(.pointerDragged(destination.scenePoint(global: Point(x: destination.frame.midX + 12, y: destination.frame.midY))))
        host.onInput?(.cancelInteraction)
        try LifecycleValidation.require(store.load() == persisted,
                                        "Cancelled same-display drag changed persisted preferences")
        try LifecycleValidation.require(LifecycleValidation.visiblePanel() === originalPanel
                                        && ObjectIdentifier(originalPanel.contentView!) == viewIdentity,
                                        "Cancelled drag replaced native panel or view")

        let reloaded = PreferenceStore(defaults: defaults).load()
        try LifecycleValidation.require(reloaded.homeDisplayID == destination.persistentID,
                                        "Destination UUID did not survive preference-store reload")
        print("Multi-display native integration passed: connectedScreens=\(measured.count), logicalDisplays=\(logical.count), native panel/view identity, global-point transfer, capture, successful UUID persistence, unrelated preference preservation, cancellation and reload. Pointer events were injected through the production host callback; this does not verify physical mouse delivery or seam travel.")
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
