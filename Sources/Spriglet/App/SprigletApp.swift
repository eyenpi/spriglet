import SwiftUI

@main
struct SprigletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PetMenu(runtime: delegate.runtime, presentation: delegate.presentation)
        } label: {
            SprigletMenuLabel(runtime: delegate.runtime, presentation: delegate.presentation)
        }
        Settings {
            SprigletSettingsView(runtime: delegate.runtime, login: delegate.login)
        }
        .windowResizability(.contentSize)
        .commands { CompanionCommands(runtime: delegate.runtime, presentation: delegate.presentation) }
        Window("Welcome to Spriglet", id: "welcome") {
            WelcomeView(runtime: delegate.runtime)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Window("Developer Diagnostics", id: "diagnostics") {
            if delegate.presentation.developerToolsAvailable {
                DiagnosticsView(runtime: delegate.runtime)
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = PetRuntime()
    let login = LoginItemService()
    let presentation = AppPresentation()
    private var acceptanceRecorder: DesktopAcceptanceRecorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
        if let output = DesktopAcceptanceRecorder.outputURL {
            acceptanceRecorder = DesktopAcceptanceRecorder(runtime: runtime, output: output)
            acceptanceRecorder?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        acceptanceRecorder?.stop()
        runtime.stop()
    }
}
