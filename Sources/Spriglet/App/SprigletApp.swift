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
        // The lease elects one owner among overlapping current launches. An
        // already-launched older preview may predate that lease; leave it alone.
        // Ignore unfinished launches so a duplicate that is exiting cannot
        // prevent the lease owner from starting.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching && !$0.isTerminated
           }) { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((delegate, instance)) { app.run() }
    }
}
