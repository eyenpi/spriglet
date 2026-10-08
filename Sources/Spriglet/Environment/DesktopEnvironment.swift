import AppKit
import IOKit.ps
import CompanionCore

/// Owns platform observations and releases every token on stop. Callbacks carry
/// semantic changes, never application contents or global keyboard events.
@MainActor final class DesktopEnvironment: NSObject {
    // loginwindow broadcasts these names; AppKit has no dedicated lock signal.
    // Keep this compatibility detail here, independent of session activation.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    var onLayoutChanged: ((DisplayLayout) -> Void)?
    var onDisplaysChanged: (([HomeDisplay]) -> Void)?
    var onConditionsChanged: ((RuntimeConditions) -> Void)?
    var onRecoveryNeeded: (() -> Void)?
    var onOutsidePressed: (() -> Void)?
    var onEscapePressed: (() -> Void)?
    private let applicationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let displays: () -> [DisplayContext]
    private var preferredDisplayID: CGDirectDisplayID?
    private var homeDisplayID: String?
    private var homeLocation = HomeLocation.automatic
    private var characterSize = CharacterSize.medium
    private var displayInventory: [HomeDisplay] = []
    private var conditions = RuntimeConditions()
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var globalMouse: Any?
    private var localKeys: Any?
    private var running = false
    private var powerSource: CFRunLoopSource?

    init(applicationCenter: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         lockCenter: NotificationCenter = DistributedNotificationCenter.default(),
         displays: @escaping () -> [DisplayContext] = { NSScreen.screens.map { DisplayContext(screen: $0) } }) {
        self.applicationCenter = applicationCenter; self.workspaceCenter = workspaceCenter
        self.lockCenter = lockCenter; self.displays = displays
        super.init()
    }
    func start() {
        guard !running else { return }; running = true
        observe(NSApplication.didChangeScreenParametersNotification, center: applicationCenter) { $0.refreshDisplay() }
        observe(NSWorkspace.willSleepNotification, center: workspaceCenter) { $0.conditions.systemAwake = false; $0.publishConditions() }
        observe(NSWorkspace.didWakeNotification, center: workspaceCenter) { $0.conditions.systemAwake = true; $0.recover() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspaceCenter) { $0.conditions.displayAwake = false; $0.publishConditions() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspaceCenter) { $0.conditions.displayAwake = true; $0.recover() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspaceCenter) { $0.conditions.sessionActive = false; $0.publishConditions() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspaceCenter) { $0.conditions.sessionActive = true; $0.recover() }
        observeLock(Self.screenLocked); observeLock(Self.screenUnlocked)
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspaceCenter) { $0.recover() }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: workspaceCenter) { $0.refreshConditions() }
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let environment = Unmanaged<DesktopEnvironment>.fromOpaque(context).takeUnretainedValue()
                if environment.running { environment.refreshConditions() }
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        observe(.NSProcessInfoPowerStateDidChange, center: applicationCenter) { $0.refreshConditions() }
        observe(ProcessInfo.thermalStateDidChangeNotification, center: applicationCenter) { $0.refreshConditions() }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // AppKit delivers event monitors on the main thread.
            MainActor.assumeIsolated { guard let self, self.running else { return }; self.onOutsidePressed?() }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.running else { return event }
            // Key-capable native windows handle Escape themselves (including
            // dismissing Settings popups); character recovery must not consume it.
            if event.keyCode == 53 && event.window?.canBecomeKey != true { self.onEscapePressed?(); return nil }
            return event
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        conditions.sessionActive = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        let available = displays()
        if let display = available.first { conditions.displayAwake = CGDisplayIsAsleep(display.id) == 0 }
        refreshConditions(); refreshDisplay()
    }
    func stop() {
        guard running else { return }; running = false
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        for (center, token) in notifications { center.removeObserver(token) }; notifications.removeAll()
        lockCenter.removeObserver(self, name: Self.screenLocked, object: nil)
        lockCenter.removeObserver(self, name: Self.screenUnlocked, object: nil)
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }; globalMouse = nil
        if let localKeys { NSEvent.removeMonitor(localKeys) }; localKeys = nil
        preferredDisplayID = nil; conditions = RuntimeConditions()
        displayInventory = []
    }
    func configureHome(_ preferences: CompanionPreferences) {
        if homeDisplayID != preferences.homeDisplayID { preferredDisplayID = nil }
        homeDisplayID = preferences.homeDisplayID
        homeLocation = preferences.homeLocation; characterSize = preferences.characterSize
        if running { refreshDisplay() }
    }
    /// Reopen and lifecycle recovery sample current measurements before resuming.
    func recover() {
        guard running else { return }
        refreshDisplay(); refreshConditions(); onRecoveryNeeded?()
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping @MainActor @Sendable (DesktopEnvironment) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // queue: .main lets us process ordered sleep/lock events synchronously,
            // with no queued Tasks surviving stop/start.
            MainActor.assumeIsolated { guard let self, self.running else { return }; action(self) }
        }
        notifications.append((center, token))
    }
    private func observeLock(_ name: Notification.Name) {
        if let distributed = lockCenter as? DistributedNotificationCenter {
            // Accessory apps normally stay inactive. Default coalescing would
            // delay lock/unlock until activation, so request immediate delivery.
            distributed.addObserver(self, selector: #selector(lockChanged(_:)), name: name,
                                    object: nil, suspensionBehavior: .deliverImmediately)
        } else {
            lockCenter.addObserver(self, selector: #selector(lockChanged(_:)), name: name, object: nil)
        }
    }
    @objc private func lockChanged(_ notification: Notification) {
        guard running else { return }
        conditions.screenUnlocked = notification.name == Self.screenUnlocked
        if conditions.screenUnlocked { recover() } else { publishConditions() }
    }
    private func refreshDisplay() {
        let measured = displays()
        let inventory = measured.compactMap { context -> HomeDisplay? in
            guard UUID(uuidString: context.persistentID) != nil else { return nil }
            return HomeDisplay(id: context.persistentID, name: context.screen.localizedName)
        }
        if inventory != displayInventory { displayInventory = inventory; onDisplaysChanged?(inventory) }
        if preferredDisplayID == nil { preferredDisplayID = measured.first?.id }
        // Mirror members are one logical pointer surface. Prefer the reported master;
        // if it is omitted, retain the first member's measurements as that surface.
        var logical: [DisplayContext] = []
        for context in measured {
            let key = context.logicalID
            if let index = logical.firstIndex(where: { $0.logicalID == key }) {
                if context.id == key { logical[index] = context }
            } else { logical.append(context) }
        }
        let placed = logical.map { $0.placingHome(size: characterSize, location: homeLocation) }
        // NSScreen.main follows keyboard focus. Home instead stays on the initial
        // primary display, falls back while absent and returns when reconnected.
        let selected: DisplayContext?
        if let homeDisplayID,
           let member = measured.first(where: { $0.persistentID == homeDisplayID }),
           let master = placed.first(where: { $0.logicalID == member.logicalID }) {
            selected = master.retainingPersistentID(homeDisplayID)
        } else if homeDisplayID != nil { selected = placed.first }
        else { selected = placed.first { $0.logicalID == (preferredDisplayID ?? 0) } ?? placed.first }
        onLayoutChanged?(DisplayLayout(home: selected, available: placed))
    }
    private func refreshConditions() {
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            conditions.onBattery = source as String != kIOPSACPowerValue
        } else { conditions.onBattery = true } // Unknown supply: conserve power.
        conditions.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        conditions.thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: .normal
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        publishConditions()
    }
    private func publishConditions() { onConditionsChanged?(conditions) }
}
