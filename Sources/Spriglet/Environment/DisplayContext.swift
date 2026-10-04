import AppKit
import CompanionCore

struct DisplayContext {
    let screen: NSScreen
    let id: CGDirectDisplayID
    let persistentID: String
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
    init(screen: NSScreen, id: CGDirectDisplayID, frame: Rect, scene: SceneGeometry, persistentID: String? = nil) {
        self.screen = screen; self.id = id; self.frame = frame; self.scene = scene
        if let persistentID { self.persistentID = persistentID }
        else if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            self.persistentID = CFUUIDCreateString(nil, uuid) as String
        } else {
            // An unavailable UUID must never alias another saved display.
            self.persistentID = "unavailable-\(id)"
        }
        backingScale = screen.backingScaleFactor; maximumFrameRate = screen.maximumFramesPerSecond
    }
    func placingHome(size: CharacterSize, location: HomeLocation) -> DisplayContext {
        let home: Rect
        if location == .automatic { home = scene.home }
        else {
            let margin = min(20, scene.bounds.width / 4)
            let width = min(180, scene.bounds.width - margin * 2)
            let x = switch location {
            case .left: scene.bounds.minX + margin
            case .center: scene.bounds.midX - width / 2
            case .right: scene.bounds.maxX - margin - width
            case .automatic: scene.home.minX
            }
            home = Rect(x: x, y: max(scene.bounds.minY, scene.home.maxY - 20), width: width, height: 20)
        }
        let geometry = SceneGeometry(bounds: scene.bounds, home: home, floor: scene.floor,
                                     scale: scene.scale * size.scale,
                                     hasHardwareNotch: location == .automatic && scene.hasHardwareNotch)
        return DisplayContext(screen: screen, id: id, frame: frame, scene: geometry, persistentID: persistentID)
    }
    /// Compare measurements, not NSScreen object identity or the focused app's screen.
    func hasSameLayout(as other: DisplayContext) -> Bool {
        id == other.id && persistentID == other.persistentID && frame == other.frame && scene == other.scene
            && backingScale == other.backingScale && maximumFrameRate == other.maximumFrameRate
    }
    func point(_ p: NSPoint) -> Point { WindowGeometry.scenePoint(global: Point(x: p.x, y: p.y), display: frame) }
}
