import AppIntents

/// Phrases can include only entity or enum parameters, so Siri asks for the question.
nonisolated struct SprigletAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCompanionIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Chat with \(.applicationName)"
            ],
            shortTitle: "Ask",
            systemImageName: "leaf"
        )
    }
}
