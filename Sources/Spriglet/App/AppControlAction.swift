/// Shared native controls emit values; the app delegate owns their effects.
enum AppControlAction: Int, CaseIterable {
    case toggleVisibility, togglePause, bringHome, toggleLaunchAtLogin, openLoginItemsSettings, settings, introduction, help, quit
}
