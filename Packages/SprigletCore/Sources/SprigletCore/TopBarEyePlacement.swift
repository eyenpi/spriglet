import CoreGraphics

/// Geometry for the eyes-only companion. All rectangles use global AppKit
/// screen coordinates; the camera housing itself is never a drawing target.
public enum TopBarEyePlacement {
    public static let size = CGSize(width: 48, height: 26)

    public static func target(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?
    ) -> CGRect? {
        guard valid(screenFrame), valid(visibleFrame) else { return nil }
        let barHeight = screenFrame.maxY - visibleFrame.maxY
        guard (20...64).contains(barHeight) else { return nil }

        let available = [auxiliaryRight, auxiliaryLeft].compactMap { $0 }
            .filter { valid($0) && screenFrame.contains($0) && $0.height >= size.height && $0.width >= size.width + 24 }
        if let right = auxiliaryRight, available.contains(right) {
            return CGRect(x: right.minX + 9, y: right.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        if let left = auxiliaryLeft, available.contains(left) {
            return CGRect(x: left.maxX - size.width - 9, y: left.midY - size.height / 2,
                          width: size.width, height: size.height)
        }

        // A notchless display has no auxiliary areas. Keep a quiet central
        // position instead of guessing the width of another app's menu titles.
        guard auxiliaryLeft == nil, auxiliaryRight == nil, screenFrame.width >= 480 else { return nil }
        return CGRect(x: screenFrame.midX - size.width / 2,
                      y: visibleFrame.maxY + (barHeight - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public static func isNearTop(_ pointer: CGPoint, screenFrame: CGRect) -> Bool {
        valid(screenFrame) && pointer.x >= screenFrame.minX && pointer.x <= screenFrame.maxX
            && pointer.y >= screenFrame.maxY - 72 && pointer.y <= screenFrame.maxY + 8
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
