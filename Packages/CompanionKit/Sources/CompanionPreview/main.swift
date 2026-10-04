import AppKit
import CompanionCore
import CompanionRendering

@MainActor func writeFrame(_ frame: CompanionSnapshot, painter: ScenePreviewRenderer, to folder: URL,
                          index: Int, pointer: Point, pressed: Bool) throws {
    try autoreleasepool {
        let png = try painter.image(frame, pointer: pointer, pressed: pressed)
        guard let data = png.representation(using: .png, properties: [:]) else { throw BitmapRenderingError.encodingFailure }
        try data.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
    }
}

@MainActor func export(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var engine = CompanionEngine(scene: .preview)
    let painter = ScenePreviewRenderer()
    var start = Point.zero
    for index in 0..<480 {
        let time = Double(index) / 30
        var pointer = Point(x: 625, y: 190)
        if (2..<6.2).contains(time) { pointer = engine.snapshot.hitBounds.center + Point(x: sin(time * 2) * 30, y: 0) }
        engine.send(.pointerMoved(pointer))
        if index == 105 || index == 150 { engine.send(.pointerPressed(pointer)); engine.send(.pointerReleased(pointer)) }
        if index == 186 || index == 360 { engine.send(.outsidePressed) }
        if index == 240 { start = engine.snapshot.hitBounds.center; engine.send(.pointerPressed(start)) }
        if (240..<300).contains(index) {
            let u = Double(index - 240) / 59, eased = u * u * (3 - 2 * u)
            pointer = start + Point(x: 160 * eased, y: 160 * eased)
            engine.send(.pointerDragged(pointer))
        }
        if index == 300 { engine.send(.pointerReleased(pointer)) }
        if index == 420 { start = engine.snapshot.hitBounds.center; engine.send(.pointerPressed(start)) }
        if (420..<450).contains(index) {
            let u = Double(index - 420) / 29
            pointer = start + Point(x: sin(u * .pi) * 45, y: -sin(u * .pi) * 12)
            engine.send(.pointerDragged(pointer))
        }
        if index == 450 { engine.send(.pointerReleased(pointer)) }
        engine.advance(by: 1 / 30.0)
        try writeFrame(engine.snapshot, painter: painter, to: folder, index: index, pointer: pointer,
                       pressed: (240..<300).contains(index) || (420..<450).contains(index))
    }
    print("Rendered 480 frames using the production core and renderer.")
}

/// A closer 60 fps review of emergence, grabs, a regrab during catch and a
/// reversed retreat, upward throw and return during a horizontal reversal.
/// Uses the same input path and fixed simulation as the app.
@MainActor func exportTransitions(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var engine = CompanionEngine(scene: .preview)
    let painter = ScenePreviewRenderer()
    var start = Point.zero, pointer = Point(x: 625, y: 190)
    for index in 0..<1080 {
        if index == 60 || index == 246 { engine.send(.activate) }
        if index == 72 || index == 108 {
            start = engine.snapshot.hitBounds.center
            pointer = start; engine.send(.pointerPressed(pointer))
        }
        if (73..<100).contains(index) {
            let u = Double(index - 72) / 27
            pointer = start + Point(x: 24 * u, y: 10 * u)
            engine.send(.pointerDragged(pointer))
        }
        if (109..<139).contains(index) {
            let u = Double(index - 108) / 30
            pointer = start + Point(x: 30 * sin(u * .pi), y: 12 * sin(u * .pi))
            engine.send(.pointerDragged(pointer))
        }
        if index == 100 || index == 139 { engine.send(.pointerReleased(pointer)) }
        if index == 200 { engine.send(.command(.stretch)) }
        if index == 240 || index == 276 { engine.send(.outsidePressed) }
        if index == 420 || index == 840 {
            start = engine.snapshot.hitBounds.center
            pointer = start; engine.send(.pointerPressed(pointer))
        }
        if index == 421 || index == 481 || index == 841 || index == 901 {
            let offset: Point = switch index {
            case 421: Point(x: 180, y: 300)
            case 481: Point(x: 180, y: -70)
            case 841: Point(x: -300, y: 150)
            default: Point(x: 300, y: 150)
            }
            pointer = start + offset; engine.send(.pointerDragged(pointer))
        }
        if index == 484 { engine.send(.pointerReleased(pointer)) }
        if index == 630 || index == 906 { engine.send(.command(.returnHome)) }
        engine.send(.pointerMoved(pointer))
        engine.advance(by: 1 / 60.0)
        try writeFrame(engine.snapshot, painter: painter, to: folder, index: index, pointer: pointer,
                       pressed: engine.hasPointerCapture)
    }
    print("Rendered 1080 transition frames at 60 fps using the production core and renderer.")
}

/// Review transparent-corner input, departure, upward catch feedback and release.
@MainActor func exportInteraction(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var engine = CompanionEngine(scene: .preview)
    let painter = ScenePreviewRenderer()
    var start = Point.zero, pointer = Point(x: 625, y: 190)
    for index in 0..<420 {
        if (20..<50).contains(index) {
            let bounds = engine.snapshot.hitBounds
            pointer = Point(x: bounds.maxX - 1, y: bounds.maxY - 1)
        }
        if index == 25 { engine.send(.pointerPressed(pointer)) }
        if index == 26 { engine.send(.pointerDragged(pointer + Point(x: 6, y: 0))) }
        if index == 27 { engine.send(.pointerReleased(pointer)) }
        if index == 60 { engine.send(.activate) }
        if index == 120 {
            start = engine.snapshot.hitBounds.center; pointer = start
            engine.send(.pointerPressed(pointer))
        }
        if (121..<160).contains(index) {
            let u = Double(index - 120) / 39
            pointer = start + Point(x: 150 * u, y: 100 * u)
            engine.send(.pointerDragged(pointer))
        }
        if (200..<240).contains(index) {
            let u = Double(index - 200) / 39
            pointer = start + Point(x: 150 - 125 * u, y: 100 - 90 * u)
            engine.send(.pointerDragged(pointer))
        }
        if index == 280 { engine.send(.pointerReleased(pointer)) }
        engine.send(.pointerMoved(pointer)); engine.advance(by: 1 / 60.0)
        try writeFrame(engine.snapshot, painter: painter, to: folder, index: index,
                       pointer: pointer, pressed: engine.hasPointerCapture)
    }
    print("Rendered 420 interaction frames at 60 fps using the production core and renderer.")
}

@MainActor func exportIcons(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let renderer = MallowIconRenderer()
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let image = try renderer.image(pixels: size * scale)
            let filename = "icon_\(size)x\(size)@\(scale)x.png"
            guard let data = image.representation(using: .png, properties: [:]) else { throw BitmapRenderingError.encodingFailure }
            try data.write(to: directory.appendingPathComponent(filename))
        }
    }
    print("Exported ten opaque RGB icon sizes from the production vector artwork.")
}

/// The exact input scripts shown in the first-launch introduction.
@MainActor func exportIntroduction(to directory: URL) throws {
    let painter = ScenePreviewRenderer()
    for step in IntroductionStep.allCases {
        let folder = directory.appendingPathComponent("\(step.rawValue + 1)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var demo = IntroductionDemo(step: step)
        for index in 0..<Int(IntroductionDemo.duration * 30) {
            try writeFrame(demo.snapshot, painter: painter, to: folder, index: index, pointer: demo.pointer, pressed: demo.pressed)
            demo.advance(by: 1 / 30)
        }
    }
    print("Rendered five introduction demos using the production input scripts, core and renderer.")
}

_ = NSApplication.shared
let args = CommandLine.arguments
do {
if args.count == 3 && args[1] == "--icons" {
    try exportIcons(to: URL(fileURLWithPath: args[2]))
} else if args.count == 3 && args[1] == "--transitions" {
    try exportTransitions(to: URL(fileURLWithPath: args[2]))
} else if args.count == 3 && args[1] == "--interaction" {
    try exportInteraction(to: URL(fileURLWithPath: args[2]))
} else if args.count == 3 && args[1] == "--introduction" {
    try exportIntroduction(to: URL(fileURLWithPath: args[2]))
} else if args.count == 2 {
    try export(to: URL(fileURLWithPath: args[1]))
} else {
    print("Usage: companion-preview OUTPUT_DIRECTORY | --transitions OUTPUT_DIRECTORY | --interaction OUTPUT_DIRECTORY | --introduction OUTPUT_DIRECTORY | --icons APPICONSET_DIRECTORY"); exit(2)
}

} catch {
    FileHandle.standardError.write(Data("Preview export failed: \(error)\n".utf8)); exit(1)
}
