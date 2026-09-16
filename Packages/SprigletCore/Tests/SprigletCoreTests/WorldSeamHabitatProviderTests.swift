import CoreGraphics
import Foundation
import Testing
import SprigletCore

@Suite("Conservative floor habitat provider")
struct WorldSeamHabitatProviderTests {
    private let provider = ConservativeFloorHabitatProvider()
    private let displayID = UUID(uuidString: "D15A1A00-0000-4000-8000-000000000042")!

    @Test("Floor habitat delegates existing resting and clamping rules")
    func existingPlacementRules() throws {
        let frame = CGRect(x: -1_920, y: -980, width: 1_920, height: 1_055)
        let size = CGSize(width: 180, height: 200)
        let display = try #require(HabitatDisplayGeometry(displayID: displayID, visibleFrame: frame))
        let habitat = try #require(provider.habitat(for: display, windowSize: size, margin: 12))

        #expect(habitat.displayID == displayID)
        #expect(habitat.kind == .floor)
        #expect(habitat.restingOrigin == PetPlacement.restingOrigin(
            windowSize: size, visibleFrame: frame, margin: 12
        ))
        #expect(habitat.clampedOrigin(CGPoint(x: 10_000, y: -10_000))
            == PetPlacement.clampedOrigin(
                CGPoint(x: 10_000, y: -10_000),
                windowSize: size,
                visibleFrame: frame,
                margin: 12
            ))
    }

    @Test("Malformed display geometry is rejected before placement", arguments: [
        CGRect(x: CGFloat.nan, y: 0, width: 1_000, height: 800),
        CGRect(x: 0, y: CGFloat.infinity, width: 1_000, height: 800),
        CGRect(x: 0, y: 0, width: -1, height: 800),
        CGRect(x: 0, y: 0, width: 1_000, height: -CGFloat.infinity),
        CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 800)
    ])
    func malformedDisplay(frame: CGRect) {
        #expect(HabitatDisplayGeometry(displayID: displayID, visibleFrame: frame) == nil)
    }

    @Test("Malformed pet sizes and margins fail closed")
    func malformedRequest() throws {
        let display = try #require(HabitatDisplayGeometry(
            displayID: displayID,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        ))
        #expect(provider.habitat(
            for: display,
            windowSize: CGSize(width: CGFloat.nan, height: 200),
            margin: 12
        ) == nil)
        #expect(provider.habitat(
            for: display,
            windowSize: CGSize(width: 180, height: -1),
            margin: 12
        ) == nil)
        #expect(provider.habitat(
            for: display,
            windowSize: CGSize(width: 180, height: 200),
            margin: CGFloat.infinity
        ) == nil)
    }

    @Test("Finite components whose derived placement overflows fail closed")
    func overflowingPlacement() throws {
        let display = try #require(HabitatDisplayGeometry(
            displayID: displayID,
            visibleFrame: CGRect(x: -CGFloat.greatestFiniteMagnitude, y: 0, width: 0, height: 800)
        ))
        #expect(provider.habitat(for: display,
                               windowSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200)) == nil)
    }

    @Test("Malformed proposed origins never reach placement preconditions")
    func malformedOrigin() throws {
        let display = try #require(HabitatDisplayGeometry(
            displayID: displayID,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        ))
        let habitat = try #require(provider.habitat(
            for: display,
            windowSize: CGSize(width: 180, height: 200),
            margin: 12
        ))
        #expect(habitat.clampedOrigin(CGPoint(x: CGFloat.nan, y: 0)) == nil)
        #expect(habitat.clampedOrigin(CGPoint(x: 0, y: CGFloat.infinity)) == nil)
    }

    @Test("Habitat replacement is replayable world state")
    func habitatStimulus() throws {
        let display = try #require(HabitatDisplayGeometry(
            displayID: displayID,
            visibleFrame: CGRect(x: -1_000, y: -100, width: 1_000, height: 700)
        ))
        let habitat = try #require(provider.habitat(
            for: display,
            windowSize: CGSize(width: 180, height: 200),
            margin: 8
        ))
        let timestamp = try #require(MonotonicTimestamp(seconds: 10))
        let populated = WorldReducer.reduce(
            PetWorldSnapshot(),
            PetStimulus(timestamp: timestamp, event: .habitat(habitat))
        )
        let cleared = WorldReducer.reduce(
            populated,
            PetStimulus(timestamp: timestamp, event: .habitat(nil))
        )

        #expect(populated.habitat == habitat)
        #expect(cleared.habitat == nil)
    }
}
