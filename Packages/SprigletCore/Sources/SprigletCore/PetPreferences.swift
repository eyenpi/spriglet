import Foundation

/// The user's local choices, separate from temporary runtime suspension reasons.
public struct PetPreferences: Codable, Equatable, Sendable {
    public var isHidden: Bool
    public var isPaused: Bool
    public var clickThrough: Bool
    public var allSpaces: Bool
    public var autonomousBehavior: Bool
    public var placement: PetSavedPlacement?
    public var profile: PetProfile
    public var interactionMemory: PetInteractionMemory
    public var isParked: Bool
    public var displaySize: PetDisplaySize
    public var activityLevel: PetActivityLevel
    public var soundEnabled: Bool

    public init(
        isHidden: Bool = false,
        isPaused: Bool = false,
        clickThrough: Bool = false,
        allSpaces: Bool = true,
        autonomousBehavior: Bool = true,
        placement: PetSavedPlacement? = nil,
        profile: PetProfile = PetProfile(),
        interactionMemory: PetInteractionMemory = PetInteractionMemory(),
        isParked: Bool = true,
        displaySize: PetDisplaySize = .standard,
        activityLevel: PetActivityLevel = .balanced,
        soundEnabled: Bool = false
    ) {
        self.isHidden = isHidden
        self.isPaused = isPaused
        self.clickThrough = clickThrough
        self.allSpaces = allSpaces
        self.autonomousBehavior = autonomousBehavior
        self.placement = placement
        self.profile = profile
        self.interactionMemory = interactionMemory
        self.isParked = isParked
        self.displaySize = displaySize
        self.activityLevel = activityLevel
        self.soundEnabled = soundEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isHidden = try values.decode(Bool.self, forKey: .isHidden)
        isPaused = try values.decode(Bool.self, forKey: .isPaused)
        clickThrough = try values.decode(Bool.self, forKey: .clickThrough)
        allSpaces = try values.decode(Bool.self, forKey: .allSpaces)
        autonomousBehavior = try values.decode(Bool.self, forKey: .autonomousBehavior)
        // Version 1 has no placement. A damaged optional position must not reset
        // valid choices such as a manual pause or click-through preference.
        placement = try? values.decodeIfPresent(PetSavedPlacement.self, forKey: .placement)
        // Optional state is recovered independently, preserving valid pause and placement.
        profile = (try? values.decode(PetProfile.self, forKey: .profile)) ?? PetProfile()
        interactionMemory = (try? values.decode(PetInteractionMemory.self, forKey: .interactionMemory)) ?? PetInteractionMemory()
        isParked = (try? values.decode(Bool.self, forKey: .isParked)) ?? true
        displaySize = (try? values.decode(PetDisplaySize.self, forKey: .displaySize)) ?? .standard
        activityLevel = (try? values.decode(PetActivityLevel.self, forKey: .activityLevel)) ?? .balanced
        soundEnabled = (try? values.decode(Bool.self, forKey: .soundEnabled)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case isHidden, isPaused, clickThrough, allSpaces, autonomousBehavior, placement
        case profile, interactionMemory, isParked
        case displaySize, activityLevel, soundEnabled
    }
}

/// Stores one versioned settings payload in the app's defaults domain.
///
/// Loading never changes persisted data. Damaged current data can recover from
/// one last-good payload; unsupported future schemas are preserved without downgrade.
@MainActor
public final class PetPreferencesStore {
    static let storageKey = "dev.spriglet.preferences"
    static let backupStorageKey = "dev.spriglet.preferences.lastGood"
    private static let currentVersion = 4
    private static let maximumPayloadBytes = 65_536

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PetPreferences {
        let data = defaults.data(forKey: Self.storageKey)
        // An oversized envelope cannot be inspected safely for a future schema.
        if let data, data.count > Self.maximumPayloadBytes { return PetPreferences() }
        // Inspect a readable version separately: even a future payload with an
        // unfamiliar body must not silently roll back to this version's backup.
        if let data, data.count <= Self.maximumPayloadBytes,
           let envelope = try? JSONDecoder().decode(VersionEnvelope.self, from: data),
           !(1...Self.currentVersion).contains(envelope.version) {
            return PetPreferences()
        }
        guard let payload = Self.supportedPayload(data)
            ?? Self.supportedPayload(defaults.data(forKey: Self.backupStorageKey)) else { return PetPreferences() }
        var preferences = payload.preferences
        if payload.version == 1 {
            preferences.placement = nil
        }
        if payload.version < 3 {
            preferences.profile = PetProfile()
            preferences.interactionMemory = PetInteractionMemory()
            preferences.isParked = true
        }
        if payload.version < 4 {
            preferences.displaySize = .standard
            preferences.activityLevel = .balanced
            preferences.soundEnabled = false
        }
        return preferences
    }

    public func save(_ preferences: PetPreferences) {
        let payload = Payload(version: Self.currentVersion, preferences: preferences)
        guard let data = try? JSONEncoder().encode(payload), data.count <= Self.maximumPayloadBytes else { return }
        let current = defaults.data(forKey: Self.storageKey)
        if Self.supportedPayload(current) != nil, let current {
            defaults.set(current, forKey: Self.backupStorageKey)
        } else if Self.supportedPayload(defaults.data(forKey: Self.backupStorageKey)) == nil {
            // A first save is recoverable too. Subsequent saves preserve the
            // previous valid state before replacing the current payload.
            defaults.set(data, forKey: Self.backupStorageKey)
        }
        // UserDefaults updates its cache immediately and persists asynchronously.
        // It does not need synchronize(), a flush timer, or direct file access.
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Forgetting is also a recovery checkpoint: neither payload may restore the
    /// discarded traces. Other current identity, settings, and home stay intact.
    public func saveClearingRecentMemory(_ preferences: PetPreferences) {
        var cleared = preferences
        cleared.interactionMemory = PetInteractionMemory()
        let payload = Payload(version: Self.currentVersion, preferences: cleared)
        guard let data = try? JSONEncoder().encode(payload), data.count <= Self.maximumPayloadBytes else { return }
        defaults.set(data, forKey: Self.backupStorageKey)
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func supportedPayload(_ data: Data?) -> Payload? {
        guard let data, data.count <= maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1...currentVersion).contains(payload.version) else { return nil }
        return payload
    }

    private struct VersionEnvelope: Decodable { let version: Int }

    private struct Payload: Codable {
        let version: Int
        let preferences: PetPreferences
    }
}
