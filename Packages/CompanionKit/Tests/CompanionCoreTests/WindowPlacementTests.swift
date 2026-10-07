import Testing
@testable import CompanionCore

@Suite("Paint-preserving window placement") struct WindowPlacementTests {
    @Test("Triangle seams split paint into contained canvases, independently of input ownership")
    func triangleCanvases() throws {
        let left = Rect(x: -1772, y: 982, width: 2560, height: 1440)
        let right = Rect(x: 788, y: 982, width: 2560, height: 1440)
        let main = Rect(x: 0, y: 0, width: 1512, height: 982)
        let request = Rect(x: 656, y: 938, width: 176, height: 144)
        let paint = Rect(x: 694.25, y: 988.5, width: 100.5, height: 90.25)
        let layout = try #require(WindowGeometry.desktopLayout(requested: request, paint: paint,
                                                               activeDisplay: left, displays: [left, right, main]))
        #expect(layout.inputFrame == Rect(x: 612, y: 982, width: 176, height: 144))
        #expect(layout.canvases == [
            DisplayWindowFrame(display: left, frame: Rect(x: 694, y: 988, width: 94, height: 91)),
            DisplayWindowFrame(display: right, frame: Rect(x: 788, y: 988, width: 7, height: 91)),
        ])
        // A pointer transfer to the lower display must not move upper paint.
        let transferred = try #require(WindowGeometry.desktopLayout(requested: request, paint: paint,
                                                                     activeDisplay: main, displays: [left, right, main]))
        #expect(transferred.inputFrame == Rect(x: 656, y: 838, width: 176, height: 144))
        #expect(transferred.canvases == layout.canvases)
        let crossing = Rect(x: 694.25, y: 960.5, width: 100.5, height: 90.25)
        let across = try #require(WindowGeometry.desktopLayout(requested: request, paint: crossing,
                                                                activeDisplay: main, displays: [left, right, main]))
        #expect(across.canvases.count == 3)
        for canvas in across.canvases {
            #expect(covers(canvas.display, canvas.frame))
            for point in corners(canvas.frame) {
                let local = WindowGeometry.scenePoint(global: point, display: left)
                let origin = WindowGeometry.drawingOrigin(window: canvas.frame, display: left)
                #expect(abs(canvas.frame.minX + local.x + origin.x - point.x) < 1e-8)
                #expect(abs(canvas.frame.maxY - local.y - origin.y - point.y) < 1e-8)
            }
        }
    }

    @Test("Gaps, duplicate mirrors and padding alone produce no extra paint window")
    func gapsAndMirrors() throws {
        let display = Rect(x: -100, y: -100, width: 200, height: 200)
        let neighbor = Rect(x: 150, y: -100, width: 200, height: 200)
        let request = Rect(x: -50, y: -50, width: 250, height: 100)
        let paint = Rect(x: 60.25, y: -20.5, width: 80, height: 40)
        let layout = try #require(WindowGeometry.desktopLayout(requested: request, paint: paint,
                                                               activeDisplay: display, displays: [display, neighbor, display]))
        #expect(layout.canvases == [DisplayWindowFrame(display: display, frame: Rect(x: 60, y: -21, width: 40, height: 41))])
        #expect(layout.inputFrame == Rect(x: -100, y: -50, width: 200, height: 100))
    }

    @Test("Oversized and fractional canvases retain every accessible envelope edge")
    func oversized() throws {
        let display = Rect(x: -100.25, y: -80.5, width: 100, height: 80)
        let request = Rect(x: -120.75, y: -90.25, width: 120, height: 110)
        let paint = Rect(x: -100.25, y: -80.5, width: 50, height: 80)
        let layout = try #require(WindowGeometry.desktopLayout(requested: request, paint: paint,
                                                               activeDisplay: display, displays: [display]))
        #expect(layout.inputFrame == display)
        #expect(layout.canvases == [DisplayWindowFrame(display: display, frame: Rect(x: -100.25, y: -80.5, width: 50.25, height: 80))])
    }

    @Test("Input bounds cannot crop independent artwork")
    func independentPaint() throws {
        let display = Rect(x: 0, y: 0, width: 100, height: 80)
        let input = Rect(x: 60, y: 50, width: 20, height: 20)
        let paint = Rect(x: 10.25, y: 10.5, width: 40, height: 30)
        let layout = try #require(WindowGeometry.desktopLayout(requested: input, paint: paint,
                                                               activeDisplay: display, displays: []))
        #expect(layout.inputFrame == input)
        #expect(layout.canvases == [DisplayWindowFrame(display: display, frame: Rect(x: 10, y: 10, width: 41, height: 31))])
    }

    @Test("Invalid or overflowing rectangles cannot create display windows")
    func invalidEnvelopes() {
        let display = Rect(x: 0, y: 0, width: 100, height: 80)
        let request = Rect(x: -10, y: -20, width: 120, height: 110)
        let invalid = [Rect(x: .nan, y: 0, width: 1, height: 1),
                       Rect(x: 0, y: 0, width: 0, height: 1),
                       Rect(x: 0, y: 0, width: 1, height: -.infinity),
                       Rect(x: Double.greatestFiniteMagnitude, y: 0,
                            width: Double.greatestFiniteMagnitude, height: 1)]
        for paint in invalid {
            #expect(WindowGeometry.desktopLayout(requested: request, paint: paint, activeDisplay: display, displays: []) == nil)
        }
        for bad in invalid {
            #expect(WindowGeometry.desktopLayout(requested: bad, paint: display, activeDisplay: display, displays: []) == nil)
            #expect(WindowGeometry.desktopLayout(requested: request, paint: display, activeDisplay: bad, displays: []) == nil)
        }
    }

    private func covers(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX && inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    @Test("Shadow bounds include its transformed corners without changing picking", arguments: [0.0, 0.7, -1.1])
    func shadowEnvelope(rotation: Double) {
        var pose = CharacterPose(); pose.width = 0.5; pose.height = 0.6; pose.arm = 1
        let snapshot = CompanionSnapshot(scene: .preview, presence: .playing, phase: .grounded,
                                         pose: pose, feet: Point(x: 300, y: 250), windowAnchor: .zero,
                                         rotation: rotation, openness: 1, homeGrip: 0,
                                         time: 0, gesture: nil, canCatch: false)
        let geometry = snapshot.geometry
        #expect(geometry.paintBounds(drawShadow: false) == geometry.bounds)
        let paint = geometry.paintBounds(drawShadow: true)
        for point in corners(MallowGeometry.groundShadowBounds).map(geometry.root.apply) + corners(geometry.bounds) {
            #expect(point.x >= paint.minX && point.x <= paint.maxX)
            #expect(point.y >= paint.minY && point.y <= paint.maxY)
        }

    }

    private func corners(_ rect: Rect) -> [Point] {
        [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
         Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
    }
}
