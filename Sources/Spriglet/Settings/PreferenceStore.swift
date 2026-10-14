import Foundation

/// A dedicated namespace leaves retired companion preferences untouched.
/// Decode fields independently so a bad or future value cannot discard other choices.
@MainActor final class PreferenceStore {
    static let storageKey = "mallow.preferences.v2"
    private static let legacyStorageKey = "mallow.preferences.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Migrate once when the current schema is absent; retain v1 for rollback.
    func load() -> CompanionPreferences {
        if defaults.object(forKey: Self.storageKey) == nil,
           let legacy = defaults.dictionary(forKey: Self.legacyStorageKey) {
            var migrated = decode(legacy)
            // The old Medium was also the default; v1 cannot distinguish it
            // from an explicit choice. Start the new lineup at its new default.
            migrated.characterSize = .medium
            save(migrated)
            return migrated
        }
        return decode(defaults.dictionary(forKey: Self.storageKey) ?? [:])
    }

    private func decode(_ values: [String: Any]) -> CompanionPreferences {
        var preferences = CompanionPreferences()
        if let value = values["characterSize"] as? String, let size = CharacterSize(rawValue: value) {
            preferences.characterSize = size
        }
        if let value = values["movementIntensity"] as? String, let intensity = MovementIntensity(rawValue: value) {
            preferences.movementIntensity = intensity
        }
        if let value = values["homeLocation"] as? String, let location = HomeLocation(rawValue: value) {
            preferences.homeLocation = location
        }
        if let value = values["homeDisplayID"] as? String, let id = UUID(uuidString: value) {
            preferences.homeDisplayID = id.uuidString
        }
        return preferences
    }

    func save(_ preferences: CompanionPreferences) {
        var values = ["characterSize": preferences.characterSize.rawValue,
                      "movementIntensity": preferences.movementIntensity.rawValue,
                      "homeLocation": preferences.homeLocation.rawValue]
        values["homeDisplayID"] = preferences.homeDisplayID
        defaults.set(values, forKey: Self.storageKey)
    }
}
