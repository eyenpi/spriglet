import AppKit
import CompanionCore
import CompanionRendering

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
        try autoreleasepool {
            let png = try painter.image(engine.snapshot, pointer: pointer, pressed: (240..<300).contains(index) || (420..<450).contains(index))
            guard let data = png.representation(using: .png, properties: [:]) else { throw BitmapRenderingError.encodingFailure }
            try data.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
        }
    }
    print("Rendered 480 frames using the production core and renderer.")
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

_ = NSApplication.shared
let args = CommandLine.arguments
do {
if args.count == 3 && args[1] == "--icons" {
    try exportIcons(to: URL(fileURLWithPath: args[2]))
} else if args.count == 2 {
    try export(to: URL(fileURLWithPath: args[1]))
} else {
    print("Usage: companion-preview OUTPUT_DIRECTORY | --icons APPICONSET_DIRECTORY"); exit(2)
}

} catch {
    FileHandle.standardError.write(Data("Preview export failed: \(error)\n".utf8)); exit(1)
}
