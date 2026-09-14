import Foundation
import SprigletCore
import Testing

@Suite("Bounded own-interaction memory")
struct PetInteractionMemoryTests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Own interactions occupy independent bounded channels")
    func separateChannels() {
        var memory = PetInteractionMemory()
        #expect(memory.values(at: epoch).affection == 0)
        memory.record(.petted, at: epoch)
        #expect(memory.values(at: epoch).affection == 0.2)
        #expect(memory.values(at: epoch).play == 0 && memory.values(at: epoch).relocation == 0)
        #expect(memory.values(at: epoch).quietSecondsRemaining == 90)
        memory.record(.played, at: epoch)
        #expect(memory.values(at: epoch).play == 0.25)
        #expect(memory.values(at: epoch).quietSecondsRemaining == 150)
        memory.record(.relocated, at: epoch)
        #expect(memory.values(at: epoch).relocation == 0.3)
        #expect(memory.values(at: epoch).quietSecondsRemaining == 180)
    }

    @Test("Repeated callbacks within twenty seconds coalesce", arguments: PetInteractionKind.allCases)
    func spamCoalesces(kind: PetInteractionKind) {
        var once = PetInteractionMemory()
        once.record(kind, at: epoch)
        var repeated = once
        for index in 0..<2_000 { repeated.record(kind, at: epoch.addingTimeInterval(Double(index) / 100)) }
        #expect(repeated == once)
        repeated.record(kind, at: epoch.addingTimeInterval(20))
        #expect(repeated != once)
        #expect(repeated.values(at: epoch.addingTimeInterval(200)).quietSecondsRemaining == 0)
    }

    @Test("Strength saturates and persistent state remains constant in size")
    func boundedState() throws {
        var memory = PetInteractionMemory()
        var now = epoch
        for _ in 0..<10_000 {
            for kind in PetInteractionKind.allCases { memory.record(kind, at: now) }
            now.addTimeInterval(20)
        }
        let values = memory.values(at: now.addingTimeInterval(-20))
        #expect(values.affection == 1 && values.play == 1 && values.relocation == 1)
        #expect(values.quietSecondsRemaining == 180)
        let data = try JSONEncoder().encode(memory)
        #expect(data.count < 400)
        #expect(try JSONDecoder().decode(PetInteractionMemory.self, from: data) == memory)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["affection", "play", "relocation"])
    }

    @Test("Memory decays predictably and stale preferences disappear")
    func decay() {
        var memory = PetInteractionMemory()
        for kind in PetInteractionKind.allCases { memory.record(kind, at: epoch) }
        #expect(abs(memory.values(at: epoch.addingTimeInterval(3 * 3_600)).affection - 0.1) < 1e-12)
        #expect(abs(memory.values(at: epoch.addingTimeInterval(2 * 3_600)).play - 0.125) < 1e-12)
        #expect(abs(memory.values(at: epoch.addingTimeInterval(30 * 60)).relocation - 0.15) < 1e-12)
        #expect(memory.values(at: epoch.addingTimeInterval(45)).quietSecondsRemaining == 135)
        #expect(memory.values(at: epoch.addingTimeInterval(24 * 3_600)) == PetInteractionMemory().values(at: epoch))
    }

    @Test("Future timestamps and backwards clocks cannot keep preferences or quiet time alive")
    func futureDates() {
        var memory = PetInteractionMemory()
        memory.record(.petted, at: epoch.addingTimeInterval(10_000_000))
        #expect(memory.values(at: epoch) == PetInteractionMemory().values(at: epoch))
        memory.record(.petted, at: epoch)
        #expect(memory.values(at: epoch).affection == 0.2)
        memory.record(.petted, at: epoch.addingTimeInterval(-10_000))
        #expect(memory.values(at: epoch.addingTimeInterval(-10_000)).affection == 0.2)
    }

    @Test("Exceptional clock values are ignored", arguments: [Double.nan, .infinity, -.infinity])
    func invalidClock(value: Double) {
        var memory = PetInteractionMemory()
        memory.record(.petted, at: epoch)
        let original = memory
        memory.record(.played, at: Date(timeIntervalSinceReferenceDate: value))
        #expect(memory == original)
        #expect(memory.values(at: Date(timeIntervalSinceReferenceDate: value)) == PetInteractionMemory().values(at: epoch))
    }

    @Test("A damaged channel cannot erase another valid channel")
    func corruptChannel() throws {
        let data = Data(#"{"affection":{"strength":"bad","updatedAt":0},"play":{"strength":5,"updatedAt":0},"relocation":{"strength":0.8,"updatedAt":"bad"}}"#.utf8)
        let memory = try JSONDecoder().decode(PetInteractionMemory.self, from: data)
        let values = memory.values(at: Date(timeIntervalSinceReferenceDate: 0))
        #expect(values.affection == 0 && values.play == 1 && values.relocation == 0)
        #expect(values.quietSecondsRemaining == 150)
    }
}
