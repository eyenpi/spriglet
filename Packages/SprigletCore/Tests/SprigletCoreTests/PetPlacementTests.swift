import Foundation
import CoreGraphics
import Testing
import SprigletCore

@Suite("Visible screen placement")
struct PetPlacementTests {
    private let windowSize = CGSize(width: 180, height: 200)
    private let desktop = CGRect(x: 0, y: 70, width: 1_512, height: 882)

    @Test("Resting position clears the Dock and right edge")
    func restingCorner() {
        let origin = PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: desktop)
        #expect(origin == CGPoint(x: 1_320, y: 82))
    }

    @Test("Dragging past any edge keeps the whole window within the visible frame", arguments: [
        CGPoint(x: -10_000, y: -10_000),
        CGPoint(x: -10_000, y: 10_000),
        CGPoint(x: 10_000, y: -10_000),
        CGPoint(x: 10_000, y: 10_000),
        CGPoint(x: 700, y: 400)
    ])
    func draggedWindowStaysVisible(proposed: CGPoint) {
        let origin = PetPlacement.clampedOrigin(proposed, windowSize: windowSize, visibleFrame: desktop)
        let result = CGRect(origin: origin, size: windowSize)
        #expect(desktop.insetBy(dx: 12, dy: 12).contains(result))
        #expect(PetPlacement.clampedOrigin(origin, windowSize: windowSize, visibleFrame: desktop) == origin)
        if desktop.insetBy(dx: 12, dy: 12).contains(CGRect(origin: proposed, size: windowSize)) {
            #expect(origin == proposed)
        }
    }

    @Test("Moving a display left and below the main screen preserves local placement")
    func negativeScreenCoordinates() {
        let shift = CGPoint(x: -2_000, y: -1_200)
        let secondary = desktop.offsetBy(dx: shift.x, dy: shift.y)
        let original = PetPlacement.clampedOrigin(CGPoint(x: 2_000, y: -100), windowSize: windowSize, visibleFrame: desktop)
        let translated = PetPlacement.clampedOrigin(
            CGPoint(x: 2_000 + shift.x, y: -100 + shift.y),
            windowSize: windowSize,
            visibleFrame: secondary
        )
        #expect(translated == CGPoint(x: original.x + shift.x, y: original.y + shift.y))
        #expect(secondary.contains(CGRect(origin: translated, size: windowSize)))
    }

    @Test("A narrow display reduces horizontal margin without losing vertical margin")
    func tightScreen() {
        let screen = CGRect(x: -300, y: -200, width: 190, height: 500)
        let origin = PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: screen)
        #expect(origin == CGPoint(x: -295, y: -188))
        #expect(screen.contains(CGRect(origin: origin, size: windowSize)))
    }

    @Test("An exact-size screen fits without a margin")
    func exactFit() {
        let screen = CGRect(x: -180, y: -200, width: 180, height: 200)
        let origin = PetPlacement.clampedOrigin(CGPoint(x: 100, y: 100), windowSize: windowSize, visibleFrame: screen)
        #expect(origin == screen.origin)
        #expect(screen.contains(CGRect(origin: origin, size: windowSize)))
    }

    @Test("An oversized window is centered on only the axis that cannot fit")
    func oversizedWindow() {
        let screen = CGRect(x: -100, y: -300, width: 100, height: 600)
        let origin = PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: screen)
        let result = CGRect(origin: origin, size: windowSize)
        #expect(result.midX == screen.midX)
        #expect(origin.y == -288)
        #expect(result.minY >= screen.minY && result.maxY <= screen.maxY)
    }

    @Test("Zero margin permits placement directly against an edge")
    func zeroMargin() {
        let origin = PetPlacement.restingOrigin(windowSize: windowSize, visibleFrame: desktop, margin: 0)
        #expect(origin == CGPoint(x: 1_332, y: 70))
    }
}
