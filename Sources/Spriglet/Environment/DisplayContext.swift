import AppKit
import CompanionCore

struct DisplayContext {
    let screen: NSScreen
    let id: CGDirectDisplayID
    let frame: Rect
    let scene: SceneGeometry
    private let backingScale: CGFloat
    private let maximumFrameRate: Int
    init(screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let f = screen.frame, visible = screen.visibleFrame
        let frame = Rect(x: f.minX, y: f.minY, width: f.width, height: f.height)
        let notch = screen.safeAreaInsets.top > 0
        let home: Rect
        if notch {
            let left = screen.auxiliaryTopLeftArea?.maxX ?? (f.midX - 92.5)
            let right = screen.auxiliaryTopRightArea?.minX ?? (f.midX + 92.5)
            home = Rect(x: left - f.minX, y: 0, width: right - left, height: screen.safeAreaInsets.top)
        } else {
            // A display without a notch gets the same small peek at its upper
            // right edge, below the menu bar. No guessed Dock/window obstacles.
            let menuHeight = max(20, f.maxY - visible.maxY)
            home = Rect(x: max(20, f.width - 230), y: menuHeight - 20, width: min(180, f.width - 40), height: 20)
        }
        let reservedBottom = visible.minY - f.minY
        let floor = max(home.maxY + 80, f.height - reservedBottom - 12)
        let scene = SceneGeometry(bounds: Rect(x: 0, y: 0, width: f.width, height: f.height), home: home,
                              floor: min(f.height, floor), hasHardwareNotch: notch)
        self.init(screen: screen, id: id, frame: frame, scene: scene)
    }
    init(screen: NSScreen, id: CGDirectDisplayID, frame: Rect, scene: SceneGeometry) {
        self.screen = screen; self.id = id; self.frame = frame; self.scene = scene
        backingScale = screen.backingScaleFactor; maximumFrameRate = screen.maximumFramesPerSecond
    }
    /// Compare measurements, not NSScreen object identity or the focused app's screen.
    func hasSameLayout(as other: DisplayContext) -> Bool {
        id == other.id && frame == other.frame && scene == other.scene
            && backingScale == other.backingScale && maximumFrameRate == other.maximumFrameRate
    }
    func point(_ p: NSPoint) -> Point { WindowGeometry.scenePoint(global: Point(x: p.x, y: p.y), display: frame) }
}
