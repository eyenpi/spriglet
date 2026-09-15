import Foundation
import SprigletCore
import Testing

@Suite("Stable local character identity")
struct PetProfileTests {
    @Test("Blank, controls, and invisible-only names use the default", arguments: ["", " \n\t ", "\u{0}\u{7}", "\u{200D}\u{202E}", "\u{0301}"])
    func emptyNames(name: String) {
        #expect(PetProfile(name: name).name == "Acorn")
    }

    @Test("Name cleanup removes control characters and preserves readable word spacing")
    func sanitizedNames() {
        #expect(PetProfile(name: "  Little\n  Sprout\t ").name == "Little Sprout")
        #expect(PetProfile(name: "Spr\u{0}out\u{202E}").name == "Sprout")
        #expect(PetProfile(name: "نام کوچک").name == "نام کوچک")
    }

    @Test("Length uses grapheme clusters rather than splitting emoji or composed letters", arguments: ["👨‍👩‍👧‍👦", "e\u{0301}", "🌱"])
    func graphemeLength(grapheme: String) {
        let name = PetProfile(name: String(repeating: grapheme, count: 40)).name
        #expect(name.count == 32)
        #expect(name == String(repeating: grapheme, count: 32))
    }

    @Test("Traits clamp finite inputs and recover exceptional numbers")
    func traitBounds() {
        let bounded = PetTraits(curiosity: -3, sociability: 9, playfulness: 0.125)
        #expect(bounded.curiosity == 0 && bounded.sociability == 1 && bounded.playfulness == 0.125)
        #expect(PetTraits(curiosity: .nan, sociability: .infinity, playfulness: -.infinity) == .sprout)
    }

    @Test("Identity round-trips and does not drift when memory or planner changes")
    func stableTraits() throws {
        let original = PetProfile(name: "Lumi", traits: PetTraits(curiosity: 0.2, sociability: 0.8, playfulness: 0.3))
        let restored = try JSONDecoder().decode(PetProfile.self, from: JSONEncoder().encode(original))
        var memory = PetInteractionMemory()
        var planner = PetBehaviorPlanner(seed: 1)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<1_000 {
            memory.record(.petted, at: now.addingTimeInterval(Double(index) * 20))
            _ = planner.next(isSleeping: false, profile: restored, memory: memory, now: now, canWander: true)
        }
        #expect(restored == original)
        #expect(restored.traitSummary == "Content to watch, friendly, and unhurried.")
        #expect(PetProfile(name: "Another name", traits: restored.traits).traits == original.traits)
    }

    @Test("Damaged profile components recover independently")
    func corruptComponents() throws {
        let data = Data(#"{"name":"  Little\nSprout  ","traits":{"curiosity":2,"sociability":"bad","playfulness":-4}}"#.utf8)
        let profile = try JSONDecoder().decode(PetProfile.self, from: data)
        #expect(profile.name == "Little Sprout")
        #expect(profile.traits == PetTraits(curiosity: 1, sociability: 0.6, playfulness: 0))
    }
}
