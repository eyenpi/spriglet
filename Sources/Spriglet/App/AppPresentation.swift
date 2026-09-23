import Foundation

@MainActor
final class AppPresentation {
    static let welcomeCompletionKey = "dev.spriglet.welcomeCompleted"
    private var presentedInitial = false

    static var isProbe: Bool { CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--soak") }
    static var isTemporary: Bool {
        let flags: Set<String> = ["--welcome-review", "--sample-review", "--desktop-acceptance", "--settings-review", "--everyday-review", "--topbar-review", "--diagnostics"]
        return CommandLine.arguments.contains { flags.contains($0) }
    }
    var developerToolsAvailable: Bool {
        #if DEBUG
        true
        #else
        CommandLine.arguments.contains("--diagnostics")
        #endif
    }

    /// A single owner handles launch, even if macOS constructs several menu labels.
    func presentInitial(settings: () -> Void, window: (String) -> Void) {
        guard !presentedInitial else { return }
        presentedInitial = true
        guard !Self.isProbe else { return }
        let arguments = CommandLine.arguments
        if arguments.contains("--topbar-review") { return }
        if arguments.contains("--diagnostics") { window("diagnostics") }
        else if arguments.contains("--welcome-review") { window("welcome") }
        else if arguments.contains(where: { ["--settings", "--controls", "--settings-review", "--everyday-review", "--sample-review", "--desktop-acceptance"].contains($0) }) {
            settings()
        } else if !UserDefaults.standard.bool(forKey: Self.welcomeCompletionKey) { window("welcome") }
    }
}
