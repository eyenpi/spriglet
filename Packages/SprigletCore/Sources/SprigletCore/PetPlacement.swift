import Foundation
import CoreGraphics

/// Placement in global macOS screen coordinates, where Y increases upward.
public enum PetPlacement {
    /// Keeps a window inside the supplied visible screen area when it can fit.
    ///
    /// Margin shrinks independently on each axis when space is tight. If a
    /// window is larger than an axis of the screen, it is centered on that axis
    /// because fully containing it is impossible. Coordinates may be negative.
    ///
    /// Supply current screen geometry; don't cache `NSScreen.visibleFrame`.
    /// Inputs must be finite, dimensions nonnegative, and margin nonnegative.
    public static func clampedOrigin(
        _ origin: CGPoint,
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint {
        validate(windowSize: windowSize, visibleFrame: visibleFrame, margin: margin)
        precondition(origin.x.isFinite && origin.y.isFinite, "Origin must be finite")

        return CGPoint(
            x: clampedAxis(
                origin.x,
                windowLength: windowSize.width,
                screenStart: visibleFrame.minX,
                screenLength: visibleFrame.width,
                margin: margin
            ),
            y: clampedAxis(
                origin.y,
                windowLength: windowSize.height,
                screenStart: visibleFrame.minY,
                screenLength: visibleFrame.height,
                margin: margin
            )
        )
    }

    /// Places the companion at the bottom-right of the visible screen area.
    /// Uses the same reduced-margin and oversized-window rules as clamping.
    public static func restingOrigin(
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint {
        // Start at the screen corner; clamping applies the attainable margin.
        clampedOrigin(
            CGPoint(x: visibleFrame.maxX, y: visibleFrame.minY),
            windowSize: windowSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
    }

    private static func clampedAxis(
        _ origin: CGFloat,
        windowLength: CGFloat,
        screenStart: CGFloat,
        screenLength: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let available = screenLength - windowLength
        guard available >= 0 else {
            return screenStart + available / 2
        }

        let attainableMargin = min(margin, available / 2)
        let lower = screenStart + attainableMargin
        let upper = screenStart + available - attainableMargin
        return min(max(origin, lower), upper)
    }

    private static func validate(
        windowSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat
    ) {
        precondition(
            windowSize.width.isFinite && windowSize.height.isFinite
                && windowSize.width >= 0 && windowSize.height >= 0,
            "Window dimensions must be finite and nonnegative"
        )
        precondition(
            visibleFrame.origin.x.isFinite && visibleFrame.origin.y.isFinite
                && visibleFrame.size.width.isFinite && visibleFrame.size.height.isFinite
                && visibleFrame.size.width >= 0 && visibleFrame.size.height >= 0,
            "Visible screen geometry must be finite with nonnegative dimensions"
        )
        precondition(margin.isFinite && margin >= 0, "Margin must be finite and nonnegative")
    }
}
