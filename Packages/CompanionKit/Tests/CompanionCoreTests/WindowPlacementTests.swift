import Testing
@testable import CompanionCore

@Suite("Paint-preserving window placement") struct WindowPlacementTests {
    @Test("Padding is contained only on axes where the complete paint fits", arguments: [
        (Rect(x: 10, y: 10, width: 20, height: 20), Rect(x: 0, y: 0, width: 100, height: 80)),
        (Rect(x: -5, y: 10, width: 40, height: 20), Rect(x: -10, y: 0, width: 120, height: 80)),
        (Rect(x: 10, y: -5, width: 20, height: 40), Rect(x: 0, y: -20, width: 100, height: 110)),
        (Rect(x: -5, y: -5, width: 40, height: 40), Rect(x: -10, y: -20, width: 120, height: 110)),
        (Rect(x: 0, y: 0, width: 100, height: 80), Rect(x: 0, y: 0, width: 100, height: 80)),
    ])
    func independentAxes(paint: Rect, expected: Rect) {
        let request = Rect(x: -10, y: -20, width: 120, height: 110)
        let display = Rect(x: 0, y: 0, width: 100, height: 80)
        #expect(WindowGeometry.axisContainedFrame(request, in: display, protecting: paint) == expected)
        for point in corners(paint) {
            #expect(point.x >= expected.minX && point.x <= expected.maxX)
            #expect(point.y >= expected.minY && point.y <= expected.maxY)
        }
    }

    @Test("Both inward triangle corners retain horizontal travel and remove bottom padding", arguments: [
        (Rect(x: -1772, y: 982, width: 2560, height: 1440),
         Rect(x: 655.736779426, y: 938, width: 176, height: 144),
         Rect(x: 693.275124, y: 988.817993, width: 100.284542, height: 89.923779)),
        (Rect(x: 788, y: 982, width: 2560, height: 1440),
         Rect(x: 744.270029800, y: 938, width: 176, height: 144),
         Rect(x: 781.345313, y: 988.790050, width: 101.278547, height: 89.120612)),
    ])
    func triangleCorners(display: Rect, request: Rect, paint: Rect) {
        let result = WindowGeometry.axisContainedFrame(request, in: display, protecting: paint)
        #expect(result == Rect(x: request.x, y: 982, width: request.width, height: request.height))
        for point in corners(paint) {
            let local = WindowGeometry.scenePoint(global: point, display: display)
            let origin = WindowGeometry.drawingOrigin(window: result, display: display)
            #expect(abs(result.minX + local.x + origin.x - point.x) < 1e-8)
            #expect(abs(result.maxY - local.y - origin.y - point.y) < 1e-8)
        }
        // Genuine vertical seam travel must restore the original Y and height.
        let acrossBottom = Rect(x: paint.x, y: 978, width: paint.width, height: paint.height)
        #expect(WindowGeometry.axisContainedFrame(request, in: display, protecting: acrossBottom) == request)
    }

    @Test("Fractional negative origins and exact edge equality preserve the envelope")
    func fractionalEdges() {
        let display = Rect(x: -100.25, y: -80.5, width: 100, height: 80)
        let request = Rect(x: -120.75, y: -90.25, width: 120, height: 110)
        let paint = Rect(x: -100.25, y: -80.5, width: 50, height: 80)
        #expect(WindowGeometry.axisContainedFrame(request, in: display, protecting: paint)
                == Rect(x: -100.25, y: -80.5, width: 100, height: 80))
        let changedDisplay = Rect(x: -100.25, y: -60.5, width: 100, height: 80)
        #expect(WindowGeometry.axisContainedFrame(request, in: changedDisplay, protecting: paint)
                == Rect(x: -100.25, y: request.y, width: 100, height: request.height))
    }

    @Test("Invalid or already clipped paint cannot authorize moving the canvas")
    func invalidEnvelopes() {
        let display = Rect(x: 0, y: 0, width: 100, height: 80)
        let request = Rect(x: -10, y: -20, width: 120, height: 110)
        let invalid = [Rect(x: .nan, y: 0, width: 1, height: 1),
                       Rect(x: 0, y: 0, width: 0, height: 1),
                       Rect(x: 0, y: 0, width: 1, height: -.infinity),
                       Rect(x: Double.greatestFiniteMagnitude, y: 0,
                            width: Double.greatestFiniteMagnitude, height: 1)]
        for paint in invalid + [Rect(x: -11, y: 0, width: 20, height: 20)] {
            #expect(WindowGeometry.axisContainedFrame(request, in: display, protecting: paint) == request)
        }
        for badDisplay in invalid {
            #expect(WindowGeometry.axisContainedFrame(request, in: badDisplay,
                                                      protecting: Rect(x: 10, y: 10, width: 20, height: 20)) == request)
        }
        for badRequest in invalid.dropFirst() {
            #expect(WindowGeometry.axisContainedFrame(badRequest, in: display,
                                                      protecting: Rect(x: 10, y: 10, width: 20, height: 20)) == badRequest)
        }
        #expect(WindowGeometry.axisContainedFrame(invalid[0], in: display,
                                                  protecting: display).x.isNaN)
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
        // A shadow-only spill must keep this axis free even though the feet fit.
        if paint.minX < geometry.bounds.minX {
            let display = Rect(x: geometry.bounds.minX, y: paint.minY - 20,
                               width: 500, height: paint.height + 40)
            let request = Rect(x: paint.minX - 10, y: paint.minY - 30, width: 600, height: paint.height + 60)
            let result = WindowGeometry.axisContainedFrame(request, in: display, protecting: paint)
            #expect(result.x == request.x && result.width == request.width)
            #expect(result.y == display.y && result.height == display.height)
        }
    }

    private func corners(_ rect: Rect) -> [Point] {
        [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
         Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
    }
}
