import Foundation

/// The user's local choices, separate from temporary runtime suspension reasons.
public struct PetPreferences: Codable, Equatable, Sendable {
    public var isHidden: Bool
    public var isPaused: Bool
    public var clickThrough: Bool
    public var allSpaces: Bool
    public var autonomousBehavior: Bool

    public init(
        isHidden: Bool = false,
        isPaused: Bool = false,
        clickThrough: Bool = false,
        allSpaces: Bool = true,
        autonomousBehavior: Bool = true
    ) {
        self.isHidden = isHidden
        self.isPaused = isPaused
        self.clickThrough = clickThrough
        self.allSpaces = allSpaces
        self.autonomousBehavior = autonomousBehavior
    }
}

/// Stores one versioned settings payload in the app's defaults domain.
///
/// Loading never changes persisted data. An unreadable or unsupported payload
/// returns safe defaults and remains available for a future app version to read.
@MainActor
public final class PetPreferencesStore {
    static let storageKey = "dev.spriglet.preferences"
    private static let currentVersion = 1

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PetPreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            return PetPreferences()
        }
        return payload.preferences
    }

    public func save(_ preferences: PetPreferences) {
        let payload = Payload(version: Self.currentVersion, preferences: preferences)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // UserDefaults updates its cache immediately and persists asynchronously.
        // It does not need synchronize(), a flush timer, or direct file access.
        defaults.set(data, forKey: Self.storageKey)
    }

    private struct Payload: Codable {
        let version: Int
        let preferences: PetPreferences
    }
}
