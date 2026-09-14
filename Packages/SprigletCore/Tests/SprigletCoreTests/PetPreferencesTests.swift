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
            #expect(preferences.isParked)
            #expect(preferences.profile == PetProfile())
            #expect(preferences.interactionMemory == PetInteractionMemory())
            #expect(defaults.object(forKey: PetPreferencesStore.storageKey) == nil)
            #expect(defaults.object(forKey: PetPreferencesStore.backupStorageKey) == nil)
        }
    }

    @Test("All user choices survive a new store instance", arguments: 0..<64)
    func roundTrip(mask: Int) throws {
        try withIsolatedDefaults { defaults in
            let preferences = PetPreferences(
                isHidden: mask & 1 != 0,
                isPaused: mask & 2 != 0,
                clickThrough: mask & 4 != 0,
                allSpaces: mask & 8 != 0,
                autonomousBehavior: mask & 16 != 0,
                profile: PetProfile(name: "Lumi", traits: PetTraits(curiosity: 0.2, sociability: 0.4, playfulness: 0.8)),
                isParked: mask & 32 != 0
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

    @Test("An unsupported version is left intact for a future app version", arguments: [0, 5, 999])
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
            #expect(envelope["version"] as? Int == 4)
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

    @Test("Current settings restore the preferred display and normalized placement")
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

    @Test("Version 2 keeps flags and placement while new identity starts parked")
    func versionTwoMigration() throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":2,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false,"placement":{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":0.25,"normalizedY":0.75},"profile":{"name":"Injected"},"isParked":false}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            let store = PetPreferencesStore(defaults: defaults)
            let migrated = store.load()
            #expect(migrated.isPaused && migrated.isHidden && migrated.clickThrough)
            #expect(!migrated.allSpaces && !migrated.autonomousBehavior)
            #expect(migrated.placement?.normalizedX == 0.25 && migrated.placement?.normalizedY == 0.75)
            #expect(migrated.profile == PetProfile() && migrated.interactionMemory == PetInteractionMemory())
            #expect(migrated.isParked)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
            store.save(migrated)
            #expect(store.load() == migrated)
        }
    }

    @Test("Malformed optional personality state cannot erase pause or home", arguments: [
        (#""profile""#, #""unexpected""#),
        (#""interactionMemory""#, #"[1,2,3]"#),
        (#""isParked""#, #""no""#)
    ])
    func corruptOptionalPersonality(field: (String, String)) throws {
        try withIsolatedDefaults { defaults in
            let original = Data("""
            {"version":3,"preferences":{"isHidden":true,"isPaused":true,"clickThrough":true,"allSpaces":false,"autonomousBehavior":false,"placement":{"displayUUID":"493A8F4C-85D4-4146-A77F-21B7A3408153","normalizedX":0.25,"normalizedY":0.75},\(field.0):\(field.1)}}
            """.utf8)
            defaults.set(original, forKey: PetPreferencesStore.storageKey)
            let value = PetPreferencesStore(defaults: defaults).load()
            #expect(value.isHidden && value.isPaused && value.clickThrough)
            #expect(!value.allSpaces && !value.autonomousBehavior)
            #expect(value.placement?.normalizedX == 0.25 && value.placement?.normalizedY == 0.75)
            #expect(value.profile == PetProfile() && value.interactionMemory == PetInteractionMemory())
            #expect(value.isParked)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == original)
        }
    }

    @Test("Current settings round-trip identity, interaction memory, and parked preference")
    func completeVersionThree() throws {
        try withIsolatedDefaults { defaults in
            var memory = PetInteractionMemory()
            memory.record(.played, at: Date(timeIntervalSinceReferenceDate: 800_000_000))
            let original = PetPreferences(isPaused: true, profile: PetProfile(name: "Little Sprout"), interactionMemory: memory, isParked: false)
            let store = PetPreferencesStore(defaults: defaults)
            store.save(original)
            #expect(store.load() == original)
            let data = try #require(defaults.data(forKey: PetPreferencesStore.storageKey))
            #expect(data.count < 2_048)
            let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(envelope["version"] as? Int == 4)
        }
    }

    @Test("Corrupted current data recovers the previous last-good state without writing")
    func backupRecovery() throws {
        try withIsolatedDefaults { defaults in
            let first = PetPreferences(isPaused: true, profile: PetProfile(name: "Lumi"))
            let second = PetPreferences(clickThrough: true, allSpaces: false, isParked: false)
            let store = PetPreferencesStore(defaults: defaults)
            store.save(first)
            store.save(second)
            #expect(store.load() == second)
            let backup = try #require(defaults.data(forKey: PetPreferencesStore.backupStorageKey))
            let corruption = Data("incomplete write".utf8)
            defaults.set(corruption, forKey: PetPreferencesStore.storageKey)
            #expect(store.load() == first)
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == corruption)
            #expect(defaults.data(forKey: PetPreferencesStore.backupStorageKey) == backup)
            store.save(second)
            #expect(store.load() == second)
            #expect(defaults.data(forKey: PetPreferencesStore.backupStorageKey) == backup)
        }
    }

    @Test("The initial save is recoverable and unrelated defaults remain intact")
    func firstSaveBackup() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("keep", forKey: "unrelated")
            let preferences = PetPreferences(isPaused: true, clickThrough: true)
            let store = PetPreferencesStore(defaults: defaults)
            store.save(preferences)
            defaults.removeObject(forKey: PetPreferencesStore.storageKey)
            #expect(store.load() == preferences)
            #expect(defaults.object(forKey: PetPreferencesStore.storageKey) == nil)
            #expect(defaults.string(forKey: "unrelated") == "keep")
        }
    }

    @Test("Clearing recent memory survives corrupt-primary recovery without resetting identity or settings")
    func clearMemoryRecoveryCheckpoint() throws {
        try withIsolatedDefaults { defaults in
            var memory = PetInteractionMemory()
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            for kind in PetInteractionKind.allCases { memory.record(kind, at: now) }
            let placement = try #require(PetSavedPlacement(displayUUID: UUID(), normalizedX: 0.25, normalizedY: 0.75))
            let original = PetPreferences(isPaused: true, placement: placement,
                                          profile: PetProfile(name: "Lumi"), interactionMemory: memory)
            var current = original
            current.isPaused = false
            current.clickThrough = true
            current.allSpaces = false
            current.autonomousBehavior = false
            current.isParked = false
            current.profile = PetProfile(name: "Little Lumi", traits: PetTraits(curiosity: 0.2, sociability: 0.8, playfulness: 0.4))
            defaults.set("keep", forKey: "unrelated")
            let store = PetPreferencesStore(defaults: defaults)
            store.save(original)
            store.save(current)

            // Even a caller that passes traces must not retain them in either copy.
            store.saveClearingRecentMemory(current)
            var cleared = current
            cleared.interactionMemory = PetInteractionMemory()
            #expect(store.load() == cleared)
            let primary = try #require(defaults.data(forKey: PetPreferencesStore.storageKey))
            let backup = try #require(defaults.data(forKey: PetPreferencesStore.backupStorageKey))
            #expect(primary == backup)
            let corruption = Data("damaged after forgetting".utf8)
            defaults.set(corruption, forKey: PetPreferencesStore.storageKey)
            #expect(store.load() == cleared)
            #expect(store.load().interactionMemory.values(at: now) == PetInteractionMemory().values(at: now))
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == corruption)
            #expect(defaults.data(forKey: PetPreferencesStore.backupStorageKey) == backup)
            #expect(defaults.string(forKey: "unrelated") == "keep")
        }
    }

    @Test("A future schema never silently downgrades to the backup", arguments: [
        #"{"version":5,"preferences":{"unfamiliar":"schema"}}"#,
        #"{"version":999,"completelyDifferentBody":true}"#,
        #"{"version":0,"preferences":null}"#
    ])
    func unsupportedVersionDoesNotUseBackup(json: String) throws {
        try withIsolatedDefaults { defaults in
            let store = PetPreferencesStore(defaults: defaults)
            store.save(PetPreferences(isPaused: true, profile: PetProfile(name: "Lumi")))
            let backup = defaults.data(forKey: PetPreferencesStore.backupStorageKey)
            let future = Data(json.utf8)
            defaults.set(future, forKey: PetPreferencesStore.storageKey)
            #expect(store.load() == PetPreferences())
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == future)
            #expect(defaults.data(forKey: PetPreferencesStore.backupStorageKey) == backup)
        }
    }

    @Test("An oversized envelope is preserved without guessing a schema downgrade")
    func oversizedEnvelope() throws {
        try withIsolatedDefaults { defaults in
            let store = PetPreferencesStore(defaults: defaults)
            store.save(PetPreferences(isPaused: true))
            let oversized = Data((#"{"version":4,"padding":""# + String(repeating: "x", count: 70_000) + #""}"#).utf8)
            defaults.set(oversized, forKey: PetPreferencesStore.storageKey)
            #expect(store.load() == PetPreferences())
            #expect(defaults.data(forKey: PetPreferencesStore.storageKey) == oversized)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "dev.spriglet.tests.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
