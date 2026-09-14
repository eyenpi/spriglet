import Foundation
import Testing
@testable import SprigletCore

@Suite("Everyday settings migration") @MainActor
struct PetEverydayPreferencesTests {
    @Test("Version 3 preserves identity, quiet mode and home while new options are conservative")
    func migration() throws {
        try withStore { store, defaults in
            let home = PetSavedPlacement(displayUUID: UUID(), normalizedX: 0.3, normalizedY: 0.7)
            var memory = PetInteractionMemory()
            memory.record(.petted)
            let old = PetPreferences(isPaused: true, autonomousBehavior: false, placement: home,
                profile: PetProfile(name: "Fern"), interactionMemory: memory, isParked: false,
                displaySize: .large, activityLevel: .lively, soundEnabled: true)
            let encoded = try JSONEncoder().encode(old)
            let body = try JSONSerialization.jsonObject(with: encoded)
            let payload = try JSONSerialization.data(withJSONObject: ["version": 3, "preferences": body])
            defaults.set(payload, forKey: PetPreferencesStore.storageKey)
            let loaded = store.load()
            #expect(loaded.profile == old.profile && loaded.interactionMemory == old.interactionMemory)
            #expect(loaded.placement == home && loaded.isPaused && !loaded.autonomousBehavior && !loaded.isParked)
            #expect(loaded.displaySize == .standard && loaded.activityLevel == .balanced && !loaded.soundEnabled)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == payload)
        }
    }

    @Test("Every supported size and frequency round-trips with optional sound", arguments: PetDisplaySize.allCases, PetActivityLevel.allCases)
    func roundTrip(size: PetDisplaySize, activity: PetActivityLevel) throws {
        try withStore { store, defaults in
            let expected = PetPreferences(displaySize: size, activityLevel: activity, soundEnabled: true)
            store.save(expected)
            #expect(PetPreferencesStore(defaults: defaults).load() == expected)
            let encoded = try #require(defaults.data(forKey: PetPreferencesStore.storageKey))
            let envelope = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(envelope["version"] as? Int == 4)
            #expect((envelope["preferences"] as? [String: Any])?["launchAtLogin"] == nil)
        }
    }

    @Test("Unknown size/frequency and malformed sound do not erase valid user choices")
    func damagedOptionalFields() throws {
        try withStore { store, defaults in
            let data = Data(#"{"version":4,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false,"profile":{"name":"Fern"},"displaySize":"giant","activityLevel":"continuous","soundEnabled":"yes"}}"#.utf8)
            defaults.set(data, forKey: PetPreferencesStore.storageKey)
            let result = store.load()
            #expect(result.isHidden && result.isPaused && result.clickThrough && !result.allSpaces && !result.autonomousBehavior)
            #expect(result.profile.name == "Fern")
            #expect(result.displaySize == .standard && result.activityLevel == .balanced && !result.soundEnabled)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == data)
        }
    }

    private func withStore(_ body: (PetPreferencesStore, UserDefaults) throws -> Void) throws {
        let suite = "dev.spriglet.everyday-preferences-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PetPreferencesStore(defaults: defaults), defaults)
    }
}
