import AppKit
import CompanionCore

/// Owns platform observations and releases every token on stop. Callbacks carry
/// semantic changes, never application contents or global keyboard events.
@MainActor final class DesktopEnvironment {
    var onDisplayChanged: ((DisplayContext) -> Void)?
    var onConditionsChanged: ((RuntimeConditions) -> Void)?
    var onOutsidePressed: (() -> Void)?
    var onReturnHome: (() -> Void)?
    private var conditions = RuntimeConditions()
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var globalMouse: Any?
    private var localKeys: Any?
    private var running = false
    func start() {
        guard !running else { return }; running = true
        refreshDisplay(); refreshConditions()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { $0.refreshDisplay() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.conditions.displayAwake = false; $0.publishConditions() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.conditions.displayAwake = true; $0.publishConditions() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.conditions.sessionActive = false; $0.publishConditions() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.conditions.sessionActive = true; $0.publishConditions() }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: workspace) { $0.refreshConditions() }
        observe(.NSProcessInfoPowerStateDidChange, center: .default) { $0.refreshConditions() }
        observe(ProcessInfo.thermalStateDidChangeNotification, center: .default) { $0.refreshConditions() }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in guard let self, self.running else { return }; self.onOutsidePressed?() }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onReturnHome?(); return nil }
            return event
        }
    }
    func stop() {
        guard running else { return }; running = false
        for (center, token) in notifications { center.removeObserver(token) }; notifications.removeAll()
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }; globalMouse = nil
        if let localKeys { NSEvent.removeMonitor(localKeys) }; localKeys = nil
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor @Sendable (DesktopEnvironment) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.running else { return }; action(self) }
        }
        notifications.append((center, token))
    }
    private func refreshDisplay() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        onDisplayChanged?(DisplayContext(screen: screen))
    }
    private func refreshConditions() {
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
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
