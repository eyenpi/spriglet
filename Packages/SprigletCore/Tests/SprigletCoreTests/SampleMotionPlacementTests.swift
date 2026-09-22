import CoreGraphics
import SprigletCore
import Testing

@Suite("Authored movement fits the whole desktop trajectory")
struct SampleMotionPlacementTests {
    private let size = CGSize(width: 224, height: 224)
    private let screen = CGRect(x: 0, y: 0, width: 600, height: 500)

    @Test("Intermediate excursions matter even when the clip returns to its origin")
    func completeTrajectory() throws {
        let offsets: [SamplePoint] = [.zero, .init(x: 120, y: 0), .init(x: -60, y: 20), .zero]
        let origin = try #require(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: CGPoint(x: 500, y: 50), windowSize: size, visibleFrame: screen, offsets: offsets))
        #expect(origin == CGPoint(x: 244, y: 50))
        for offset in offsets {
            let position = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
            #expect(screen.insetBy(dx: 12, dy: 12).contains(CGRect(origin: position, size: size)))
        }
    }

    @Test("Leftward travel reserves its starting space near the left edge")
    func leftwardStart() {
        let origin = SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: CGPoint(x: 0, y: 50), windowSize: size, visibleFrame: screen,
            offsets: [.zero, .init(x: -60, y: 0)])
        #expect(origin == CGPoint(x: 72, y: 50))
    }

    @Test("An already-safe starting position is preserved")
    func preserveSafeOrigin() {
        let preferred = CGPoint(x: 180, y: 100)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: preferred, windowSize: size, visibleFrame: screen,
            offsets: [.zero, .init(x: 80, y: 30), .init(x: -40, y: -20)]) == preferred)
    }

    @Test("The trajectory translates with a display left and below the main screen")
    func translatedDisplay() throws {
        let shift = CGPoint(x: -1_900, y: -1_100)
        let offsets: [SamplePoint] = [.zero, .init(x: 120, y: 0), .init(x: -60, y: 20)]
        let original = try #require(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: CGPoint(x: 500, y: 50), windowSize: size, visibleFrame: screen, offsets: offsets))
        let translated = try #require(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: CGPoint(x: 500 + shift.x, y: 50 + shift.y), windowSize: size,
            visibleFrame: screen.offsetBy(dx: shift.x, dy: shift.y), offsets: offsets))
        #expect(translated == CGPoint(x: original.x + shift.x, y: original.y + shift.y))
    }

    @Test("An impossible excursion is rejected instead of clamping moving frames")
    func tooWideToWalk() {
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: screen,
            offsets: [.zero, .init(x: 500, y: 0), .zero]) == nil)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: screen,
            offsets: [.zero, .init(x: 0, y: 500), .zero]) == nil)
    }

    @Test("An exact-size display can hold a still pose but cannot accommodate travel")
    func exactFit() {
        let tight = CGRect(x: -224, y: -224, width: 224, height: 224)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: tight, offsets: [.zero]) == tight.origin)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: tight,
            offsets: [.zero, .init(x: 0.1, y: 0)]) == nil)
    }

    @Test("A zero-margin stationary pose can sit flush with a safe ledge")
    func zeroMarginLedge() {
        let safeFrame = CGRect(x: 0, y: 73, width: 1_512, height: 876)
        let ledgeOrigin = CGPoint(x: 284, y: safeFrame.maxY - size.height)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: ledgeOrigin, windowSize: size, visibleFrame: safeFrame,
            offsets: [.zero], margin: 0
        ) == ledgeOrigin)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: ledgeOrigin, windowSize: size, visibleFrame: safeFrame,
            offsets: [.zero]
        ) != ledgeOrigin)
    }

    @Test("Nonfinite motion and geometry cannot produce an unsafe origin", arguments: [Double.nan, .infinity, -.infinity])
    func invalidNumbers(value: Double) {
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: screen,
            offsets: [.zero, .init(x: value, y: 0)]) == nil)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: CGPoint(x: value, y: 0), windowSize: size, visibleFrame: screen, offsets: [.zero]) == nil)
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: screen, offsets: [.zero], margin: value) == nil)
    }

    @Test("An empty trajectory cannot claim a fit")
    func emptyTrajectory() {
        #expect(SampleMotionPlacement.fittingStartOrigin(
            preferredOrigin: .zero, windowSize: size, visibleFrame: screen, offsets: []) == nil)
    }
}
