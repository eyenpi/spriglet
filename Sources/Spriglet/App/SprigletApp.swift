import SwiftUI

@main
struct SprigletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("dev.spriglet.welcomeCompleted") private var welcomeCompleted = false
    @State private var presentingWelcome: Bool

    init() {
        let arguments = CommandLine.arguments
        let suppressed = arguments.contains("--probe") || arguments.contains("--soak")
        let forcedWelcome = arguments.contains("--welcome-review")
        let forcedControls = arguments.contains("--controls") || arguments.contains("--sample-review")
        _presentingWelcome = State(initialValue: !suppressed && (forcedWelcome || (!forcedControls && !UserDefaults.standard.bool(forKey: "dev.spriglet.welcomeCompleted"))))
    }

    var body: some Scene {
        MenuBarExtra("Spriglet", systemImage: "leaf.fill") {
            PetMenu(runtime: delegate.runtime, presentingWelcome: $presentingWelcome)
        }
        Window("Spriglet Controls", id: "prototype") {
            PrototypeView(runtime: delegate.runtime, presentingWelcome: $presentingWelcome)
        }
        .defaultSize(width: 480, height: 740)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(shouldPresentWindow ? .presented : .suppressed)
    }

    private var shouldPresentWindow: Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--probe") || arguments.contains("--soak") {
            return false
        }
        if arguments.contains("--controls") || arguments.contains("--sample-review") || arguments.contains("--welcome-review") {
            return true
        }
        return !welcomeCompleted
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = PetRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}
