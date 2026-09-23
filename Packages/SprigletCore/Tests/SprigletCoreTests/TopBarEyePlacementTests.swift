import CoreGraphics
import Testing
@testable import SprigletCore

@Suite struct TopBarEyePlacementTests {
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 73, width: 1512, height: 876)

    @Test func sitsBesideTheNotch() {
        let left = CGRect(x: 0, y: 950, width: 663.5, height: 32)
        let right = CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
        let target = TopBarEyePlacement.target(screenFrame: frame, visibleFrame: visible,
                                                auxiliaryLeft: left, auxiliaryRight: right)
        #expect(target?.minX == right.minX + 9)
        #expect(target?.minY == 953)
        #expect(target?.width == 48)
        #expect(target!.minX > left.maxX)
    }

    @Test func notchlessAndHiddenMenuBar() {
        let target = TopBarEyePlacement.target(screenFrame: frame, visibleFrame: visible,
                                                auxiliaryLeft: nil, auxiliaryRight: nil)
        #expect(target?.midX == frame.midX)
        #expect(TopBarEyePlacement.target(screenFrame: frame, visibleFrame: frame,
                                           auxiliaryLeft: nil, auxiliaryRight: nil) == nil)
    }

    @Test func avoidsInvalidAndCrampedAreas() {
        let narrow = CGRect(x: 740, y: 950, width: 55, height: 32)
        #expect(TopBarEyePlacement.target(screenFrame: frame, visibleFrame: visible,
                                           auxiliaryLeft: nil, auxiliaryRight: narrow) == nil)
        #expect(TopBarEyePlacement.isNearTop(CGPoint(x: 500, y: 930), screenFrame: frame))
        #expect(!TopBarEyePlacement.isNearTop(CGPoint(x: 500, y: 700), screenFrame: frame))
    }
}
