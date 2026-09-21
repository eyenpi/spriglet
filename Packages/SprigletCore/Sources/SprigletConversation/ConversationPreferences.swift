import Foundation

/// Conversation choices, stored apart from pet preferences so this domain can
/// grow and be erased without touching the pet's identity or placement.
public struct ConversationPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? values.decode(Bool.self, forKey: .isEnabled)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case isEnabled }
}

/// One versioned payload. Damaged or unsupported data reads as the safe default,
/// conversation off, and loading never writes.
@MainActor
public final class ConversationPreferencesStore {
    static let storageKey = "dev.spriglet.conversation.preferences"
    private static let currentVersion = 1
    private static let maximumPayloadBytes = 4_096

    private let defaults: UserDefaults
    public let allowsChanges: Bool

    /// Review, probe, and validation launches pass `allowsChanges: false`.
    public init(defaults: UserDefaults = .standard, allowsChanges: Bool = true) {
        self.defaults = defaults
        self.allowsChanges = allowsChanges
    }

    public func load() -> ConversationPreferences {
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= Self.maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else { return ConversationPreferences() }
        return payload.preferences
    }

    @discardableResult
    public func save(_ preferences: ConversationPreferences) -> Bool {
        guard allowsChanges,
              let data = try? JSONEncoder().encode(Payload(version: Self.currentVersion, preferences: preferences)),
              data.count <= Self.maximumPayloadBytes else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    private struct Payload: Codable {
        let version: Int
        let preferences: ConversationPreferences
    }
}
