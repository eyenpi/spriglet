import AppKit
import CompanionCore
import CompanionRendering

/// Reproducible size and transition review using the production snapshots and renderer.
@MainActor enum SizePreview {
    private static let examples: [(name: String, scale: Double, form: MallowForm)] = [
        ("Small", 0.8, .fingertipGrip), ("Medium", 0.8, .standard), ("Large", 1, .standard),
    ]

    private static func scene(scale: Double, form: MallowForm, notch: Bool, width: Double = 720,
                              height: Double = 420) -> SceneGeometry {
        SceneGeometry(bounds: Rect(x: 0, y: 0, width: width, height: height),
                      home: Rect(x: width / 2 - 92.5, y: notch ? 0 : 12, width: 185, height: notch ? 32 : 20),
                      floor: height - 20, scale: scale, hasHardwareNotch: notch, form: form)
    }

    static func export(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let painter = ScenePreviewRenderer()
        for example in examples {
            for notch in [true, false] {
                let frame = CompanionEngine(scene: scene(scale: example.scale, form: example.form, notch: notch)).snapshot
                let png = try painter.image(frame)
                guard let data = png.representation(using: .png, properties: [:]) else { throw BitmapRenderingError.encodingFailure }
                try data.write(to: folder.appendingPathComponent("\(example.name.lowercased())-\(notch ? "notched" : "unnotched").png"))
            }
        }
        try comparison(to: folder.appendingPathComponent("size-comparison.png"))
        for notch in [true, false] {
            try transitions(to: folder, notch: notch)
            try hoverPasses(to: folder, notch: notch)
        }
        print("Rendered all three sizes, both homes and Small's invite, retuck, drag, landing and return transitions.")
    }

    private static func transitions(to directory: URL, notch: Bool) throws {
        let folder = directory.appendingPathComponent("small-\(notch ? "notched" : "unnotched")-transitions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var engine = CompanionEngine(scene: scene(scale: 0.8, form: .fingertipGrip, notch: notch))
        let painter = ScenePreviewRenderer()
        var start = Point.zero, pointer = Point(x: 625, y: 190)
        for index in 0..<480 {
            if index == 5, let area = engine.snapshot.homeHoverBounds {
                pointer = Point(x: area.maxX - 12, y: area.maxY - 6)
            }
            if index == 30 {
                pointer = engine.snapshot.hitBounds.center
                engine.send(.pointerMoved(pointer))
                engine.send(.pointerPressed(pointer)); engine.send(.pointerReleased(pointer))
                pointer = Point(x: 625, y: 190)
            }
            if index == 105 { engine.send(.outsidePressed) }
            if index == 165 {
                start = engine.snapshot.geometry.hands[0].palm.center + Point(x: 0, y: 2); pointer = start
                engine.send(.pointerPressed(pointer))
            }
            if (166..<226).contains(index) {
                let progress = Double(index - 165) / 60
                pointer = start + Point(x: 160 * progress, y: 160 * progress)
                engine.send(.pointerDragged(pointer))
            }
            if index == 226 { engine.send(.pointerReleased(pointer)); pointer = Point(x: 625, y: 190) }
            if index == 315 { engine.send(.command(.returnHome)) }
            engine.send(.pointerMoved(pointer)); engine.advance(by: 1 / 30.0)
            try writeFrame(engine.snapshot, painter: painter, to: folder, index: index,
                           pointer: pointer, pressed: engine.hasPointerCapture)
        }
    }

    private static func hoverPasses(to directory: URL, notch: Bool) throws {
        let folder = directory.appendingPathComponent("small-\(notch ? "notched" : "unnotched")-hover")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var engine = CompanionEngine(scene: scene(scale: 0.8, form: .fingertipGrip, notch: notch))
        guard let area = engine.snapshot.homeHoverBounds else { throw BitmapRenderingError.invalidSize }
        let painter = ScenePreviewRenderer()
        let away = Point(x: 625, y: 190)
        var pointer = away
        for index in 0..<150 {
            if (10..<15).contains(index) {
                let progress = Double(index - 10) / 4
                pointer = Point(x: area.minX + progress * area.width, y: area.minY + progress * area.height)
            }
            if index == 15 || index == 34 { pointer = away }
            if index == 30 || index == 70 {
                pointer = notch ? Point(x: area.midX, y: engine.snapshot.scene.home.maxY - 16) : area.center
            }
            if (71..<77).contains(index) {
                pointer.x += 200 / 30.0
            }
            if index == 100 {
                pointer = engine.snapshot.hitBounds.center
                engine.send(.pointerPressed(pointer)); engine.send(.pointerReleased(pointer))
            }
            engine.send(.pointerMoved(pointer)); engine.advance(by: 1 / 30.0)
            try writeFrame(engine.snapshot, painter: painter, to: folder, index: index,
                           pointer: pointer, pressed: engine.hasPointerCapture)
        }
    }

    private static func comparison(to file: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1080, pixelsHigh: 580,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BitmapRenderingError.contextFailure }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.translateBy(x: 0, y: 580); context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1080, height: 580).fill()
        func label(_ text: String, x: Double, y: Double, size: Double = 16) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor])
        }
        label("Small, Medium and Large · production rendering", x: 24, y: 20, size: 26)
        let painter = ScenePreviewRenderer()
        for (index, example) in examples.enumerated() {
            let x = Double(index * 352 + 24)
            label(example.name, x: x, y: 65, size: 23)
            label(["Fingertip grip", "Default · previous Small", "Previous Medium"][index], x: x, y: 95)
            for (row, notch) in [true, false].enumerated() {
                let frame = CompanionEngine(scene: scene(scale: example.scale, form: example.form, notch: notch,
                                                         width: 320, height: 180)).snapshot
                let y = Double(row * 210 + 160)
                label("\(notch ? "With notch" : "Without notch") · \(String(format: "%.1f", frame.hitBounds.height)) pt tall", x: x, y: y - 30)
                NSGraphicsContext.saveGraphicsState()
                let translation = NSAffineTransform(); translation.translateX(by: x, yBy: y); translation.concat()
                painter.draw(frame)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        label("All three use the same desktop scale. Current Large is removed.", x: 24, y: 550, size: 14)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BitmapRenderingError.encodingFailure }
        try data.write(to: file)
    }
}
