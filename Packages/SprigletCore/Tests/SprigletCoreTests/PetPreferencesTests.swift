import Foundation
import Testing
@testable import SprigletCore

@Suite("Local pet preferences")
@MainActor
struct PetPreferencesTests {
    @Test("An empty domain uses safe initial choices without writing them")
    func emptyStore() throws {
        try withIsolatedDefaults { defaults in
            let preferences = PetPreferencesStore(defaults: defaults).load()
            #expect(!preferences.isHidden)
            #expect(!preferences.isPaused)
            #expect(!preferences.clickThrough)
            #expect(preferences.allSpaces)
            #expect(preferences.autonomousBehavior)
            #expect(defaults.object(forKey: PetPreferencesStore.storageKey) == nil)
        }
    }

    @Test("All user choices survive a new store instance", arguments: 0..<32)
    func roundTrip(mask: Int) throws {
        try withIsolatedDefaults { defaults in
            let preferences = PetPreferences(
                isHidden: mask & 1 != 0,
                isPaused: mask & 2 != 0,
                clickThrough: mask & 4 != 0,
                allSpaces: mask & 8 != 0,
                autonomousBehavior: mask & 16 != 0
            )
            PetPreferencesStore(defaults: defaults).save(preferences)
            let restored = PetPreferencesStore(defaults: defaults).load()
            #expect(restored == preferences)
        }
    }

    @Test("Corrupt data falls back without replacing the payload or unrelated defaults")
    func corruptData() throws {
        try withIsolatedDefaults { defaults in
            let original = Data("not a preferences payload".utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            defaults.set("keep", forKey: "unrelated.setting")

            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences())
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
            #expect(defaults.string(forKey: "unrelated.setting") == "keep")
        }
    }

    @Test("An unsupported version is left intact for a future app version")
    func unknownVersion() throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":999,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)

            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences())
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
        }
    }

    @Test("A current payload with a missing or incorrectly typed choice falls back", arguments: [
        #"{"version":1,"preferences":{"isHidden":true}}"#,
        #"{"version":1,"preferences":{"isHidden":"yes","isPaused":false,"clickThrough":false,"allSpaces":true,"autonomousBehavior":true}}"#
    ])
    func malformedPreferences(json: String) throws {
        try withIsolatedDefaults { defaults in
            let original = Data(json.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences())
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
        }
    }

    @Test("An unexpected defaults value type is not coerced or removed")
    func wrongDefaultsType() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: PetPreferencesStore.storageKey)
            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences())
            #expect(defaults.object(forKey: PetPreferencesStore.storageKey) as? Bool == true)
        }
    }

    @Test("Saving replaces this app's payload while preserving other settings")
    func savesOnlyOwnedKey() throws {
        try withIsolatedDefaults { defaults in
            let store = PetPreferencesStore(defaults: defaults)
            defaults.set(42, forKey: "unrelated.setting")
            store.save(PetPreferences(isHidden: true, clickThrough: true))

            var updated = PetPreferences()
            updated.isPaused = true
            updated.autonomousBehavior = false
            store.save(updated)

            #expect(PetPreferencesStore(defaults: defaults).load() == updated)
            #expect(defaults.integer(forKey: "unrelated.setting") == 42)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "dev.spriglet.tests.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
