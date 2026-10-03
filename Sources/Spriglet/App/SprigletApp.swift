import AppKit

@main enum SprigletApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let instance: AppInstanceLease
        do {
            guard let lease = try AppInstanceLease.acquire() else { return }
            instance = lease
        } catch {
            fputs("Spriglet could not acquire its instance lock: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((delegate, instance)) { app.run() }
    }
}
