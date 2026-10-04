import Foundation

/// Only dismissal is persisted. Playback and character state stay in memory.
@MainActor final class IntroductionPreferences {
    private let defaults: UserDefaults
    private let key = "hasDismissedMallowIntroduction"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var shouldPresentOnLaunch: Bool { !defaults.bool(forKey: key) }
    func recordDismissal() { defaults.set(true, forKey: key) }
}
