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
            #expect(preferences.placement == nil)
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

    @Test("An unsupported version is left intact for a future app version", arguments: [0, 3, 999])
    func unknownVersion(version: Int) throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":\(version),"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false}}
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

    @Test("Version 1 preserves all Boolean settings and migrates on the next explicit save")
    func versionOneMigration() throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":1,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            let store = PetPreferencesStore(defaults: defaults)
            let migrated = store.load()
            #expect(migrated == PetPreferences(
                isHidden: true, isPaused: true, clickThrough: true, allSpaces: false, autonomousBehavior: false
            ))
            #expect(migrated.placement == nil)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)

            store.save(migrated)
            let savedData = try #require(defaults.data(forKey: PetPreferencesStore.storageKey))
            let envelope = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
            #expect(envelope["version"] as? Int == 2)
            #expect(store.load() == migrated)
        }
    }

    @Test("Version 1 never adopts a placement field outside its original schema")
    func versionOneIgnoresPlacement() throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":1,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false,"placement":{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":0.25,"normalizedY":0.75}}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences(
                isHidden: true, isPaused: true, clickThrough: true, allSpaces: false, autonomousBehavior: false
            ))
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
        }
    }

    @Test("Version 2 restores the preferred display and normalized placement")
    func placementRoundTrip() throws {
        try withIsolatedDefaults { defaults in
            let placement = try #require(PetSavedPlacement(displayUUID: UUID(), normalizedX: 0.125, normalizedY: 0.75))
            let preferences = PetPreferences(isPaused: true, placement: placement)
            PetPreferencesStore(defaults: defaults).save(preferences)
            #expect(PetPreferencesStore(defaults: defaults).load() == preferences)
        }
    }

    @Test("Changing a Boolean choice preserves the remembered home")
    func editingFlagsPreservesPlacement() throws {
        try withIsolatedDefaults { defaults in
            let placement = try #require(PetSavedPlacement(displayUUID: UUID(), normalizedX: 0.25, normalizedY: 0.5))
            let store = PetPreferencesStore(defaults: defaults)
            store.save(PetPreferences(isPaused: true, placement: placement))
            var preferences = store.load()
            preferences.isPaused = false
            preferences.clickThrough = true
            store.save(preferences)
            #expect(store.load() == preferences)
            #expect(store.load().placement == placement)
        }
    }

    @Test("Malformed optional placement cannot erase valid pause and visibility choices", arguments: [
        #"{"displayUUID":"not-a-uuid","normalizedX":0.5,"normalizedY":0.5}"#,
        #"{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":-0.5,"normalizedY":0.5}"#,
        #"{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":0.5,"normalizedY":2}"#,
        #"{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":"NaN","normalizedY":0.5}"#,
        #"{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":1e999,"normalizedY":0.5}"#,
        #"{"normalizedX":0.5}"#,
        #""unexpected string""#
    ])
    func malformedPlacement(json: String) throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":2,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false,"placement":\(json)}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            #expect(PetPreferencesStore(defaults: defaults).load() == PetPreferences(
                isHidden: true, isPaused: true, clickThrough: true, allSpaces: false, autonomousBehavior: false
            ))
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "dev.spriglet.tests.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
