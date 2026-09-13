import CoreGraphics
import Foundation
import Testing
import SprigletCore

@Suite("Remembered screen-relative placement")
struct PetSavedPlacementTests {
    private let displayUUID = UUID(uuidString: "493A8F4C-85D4-4146-A77F-21B7A3408153")!
    private let otherDisplayUUID = UUID(uuidString: "0B942EAE-F6D5-468B-A242-A5D25F47DA01")!
    private let windowSize = CGSize(width: 192, height: 192)

    @Test("Capture and restore preserve a clamped position on negative-coordinate displays", arguments: [
        CGPoint(x: -1_800, y: -1_000),
        CGPoint(x: -1_200, y: -400),
        CGPoint(x: -12, y: -25),
        CGPoint(x: -10_000, y: 10_000)
    ])
    func roundTrip(origin: CGPoint) throws {
        let screen = CGRect(x: -1_920, y: -1_055, width: 1_920, height: 1_055)
        let saved = try #require(PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: origin,
            windowSize: windowSize,
            visibleFrame: screen
        ))
        let restored = try #require(saved.restoredOrigin(windowSize: windowSize, visibleFrame: screen))
        let expected = PetPlacement.clampedOrigin(origin, windowSize: windowSize, visibleFrame: screen)
        #expect(abs(restored.x - expected.x) < 0.000_001)
        #expect(abs(restored.y - expected.y) < 0.000_001)
        #expect(screen.insetBy(dx: 12, dy: 12).contains(CGRect(origin: restored, size: windowSize)))
    }

    @Test("Changing resolution and Dock geometry retains edge anchoring")
    func edgeAnchoring() throws {
        let before = CGRect(x: 0, y: 70, width: 1_512, height: 882)
        let after = CGRect(x: -2_000, y: -800, width: 1_000, height: 680)
        let saved = try #require(PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: before),
            windowSize: windowSize,
            visibleFrame: before
        ))
        #expect(saved.normalizedX == 1)
        #expect(saved.normalizedY == 0)
        #expect(saved.restoredOrigin(windowSize: windowSize, visibleFrame: after)
            == PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: after))
    }

    @Test("A fractional position follows the reachable range after layout and size changes")
    func proportionalPlacement() throws {
        let saved = try #require(PetSavedPlacement(displayUUID: displayUUID, normalizedX: 0.25, normalizedY: 0.75))
        let screen = CGRect(x: -1_000, y: 50, width: 1_216, height: 816)
        let origin = try #require(saved.restoredOrigin(windowSize: windowSize, visibleFrame: screen))
        // Reachable X is -988...12; reachable Y is 62...662.
        #expect(origin == CGPoint(x: -738, y: 512))
        let translated = try #require(saved.restoredOrigin(
            windowSize: windowSize,
            visibleFrame: screen.offsetBy(dx: 2_500, dy: -1_400)
        ))
        #expect(translated == CGPoint(x: origin.x + 2_500, y: origin.y - 1_400))
    }

    @Test("An exact-fit or oversized axis records its center without dividing by zero", arguments: [100.0, 192.0, 200.0])
    func collapsedAxis(screenWidth: Double) throws {
        let tinyScreen = CGRect(x: -300, y: -200, width: screenWidth, height: 600)
        let saved = try #require(PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: CGPoint(x: 5_000, y: -188),
            windowSize: windowSize,
            visibleFrame: tinyScreen
        ))
        #expect(saved.normalizedX == 0.5)
        let restored = try #require(saved.restoredOrigin(windowSize: windowSize, visibleFrame: tinyScreen))
        #expect(CGRect(origin: restored, size: windowSize).midX == tinyScreen.midX)
        #expect(restored.y == -188)
        let largerScreen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let expanded = try #require(saved.restoredOrigin(windowSize: windowSize, visibleFrame: largerScreen))
        #expect(CGRect(origin: expanded, size: windowSize).midX == largerScreen.midX)
    }

    @Test("Display selection survives rearrangement and recovers when the preferred display is absent")
    func displaySelection() throws {
        let saved = try #require(PetSavedPlacement(displayUUID: displayUUID, normalizedX: 0.5, normalizedY: 0.5))
        #expect(saved.displayIndex(in: [otherDisplayUUID, displayUUID], fallbackIndex: 0) == 1)
        #expect(saved.displayIndex(in: [displayUUID, otherDisplayUUID], fallbackIndex: 1) == 0)
        #expect(saved.displayIndex(in: [otherDisplayUUID, nil], fallbackIndex: 1) == 1)
        #expect(saved.displayIndex(in: [otherDisplayUUID], fallbackIndex: 99) == 0)
        #expect(saved.displayIndex(in: []) == nil)
        // The fallback decision never changes the value we can use after reconnect.
        #expect(saved.displayUUID == displayUUID)
    }

    @Test("Saved coordinates reject nonfinite and out-of-range values", arguments: [
        Double.nan, .infinity, -.infinity, -0.001, 1.001
    ])
    func invalidCoordinates(value: Double) {
        #expect(PetSavedPlacement(displayUUID: displayUUID, normalizedX: value, normalizedY: 0.5) == nil)
        #expect(PetSavedPlacement(displayUUID: displayUUID, normalizedX: 0.5, normalizedY: value) == nil)
    }

    @Test("Invalid geometry and nonfinite origins fail without reaching placement preconditions")
    func invalidGeometry() throws {
        let saved = try #require(PetSavedPlacement(displayUUID: displayUUID, normalizedX: 0.5, normalizedY: 0.5))
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        #expect(PetSavedPlacement.capture(
            displayUUID: displayUUID,
            origin: CGPoint(x: CGFloat.infinity, y: 0),
            windowSize: windowSize,
            visibleFrame: screen
        ) == nil)
        #expect(saved.restoredOrigin(windowSize: CGSize(width: -1, height: 192), visibleFrame: screen) == nil)
        #expect(saved.restoredOrigin(windowSize: windowSize, visibleFrame: CGRect(x: 0, y: 0, width: -1, height: 800)) == nil)
        #expect(saved.restoredOrigin(windowSize: windowSize, visibleFrame: screen, margin: .nan) == nil)
        #expect(saved.restoredOrigin(
            windowSize: windowSize,
            visibleFrame: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 800)
        ) == nil)
    }

    @Test("Codable decoding enforces the same coordinate invariants")
    func decodingRejectsNonfinite() {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let data = Data("""
        {"displayUUID":"\(displayUUID.uuidString)","normalizedX":"NaN","normalizedY":0.5}
        """.utf8)
        #expect(throws: DecodingError.self) {
            try decoder.decode(PetSavedPlacement.self, from: data)
        }
    }
}
