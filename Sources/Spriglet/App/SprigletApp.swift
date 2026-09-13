import SwiftUI

@main
struct SprigletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Spriglet", systemImage: "leaf.fill") {
            PetMenu(runtime: delegate.runtime)
        }
        Window("Spriglet Prototype", id: "prototype") {
            PrototypeView(runtime: delegate.runtime)
        }
        .defaultSize(width: 480, height: 740)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--controls") ? .presented : .suppressed)
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
