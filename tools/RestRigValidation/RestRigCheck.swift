import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import SprigletCore

@main
enum RestRigCheck {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let runner = RestRigRunner(resources: resourceDirectory())
        NSApplication.shared.delegate = runner
        withExtendedLifetime(runner) { NSApplication.shared.run() }
    }

    @MainActor
    private static func resourceDirectory() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--resources"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let resourceURL = Bundle.main.resourceURL,
           Bundle.main.bundleURL.pathExtension == "app" {
            return resourceURL.appendingPathComponent("RestRigPackage", isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("art/candidates/rest-rig-v04/acorn-hopper", isDirectory: true)
    }
}

@MainActor
private final class RestRigRunner: NSObject, NSApplicationDelegate {
    private let resources: URL
    private var review: RestRigReview?

    init(resources: URL) {
        self.resources = resources
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--review") {
            review = RestRigReview(resources: resources)
            return
        }
        Task { @MainActor [self] in
            defer { NSApplication.shared.terminate(nil) }
            do {
                let report = try await validate()
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Rest rig validation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    private func validate() async throws -> RestRigReport {
        let package = try CharacterPackage.decode(Data(contentsOf: resources.appendingPathComponent("character.json")))
        guard let canonicalFile = package.poses["ready"]?.stillFrame else {
            throw RestRigValidationFailure("The generated ready pose has no canonical still frame.")
        }
        let canonical = try SampleImageDecoder.decodeImage(
            url: resources.appendingPathComponent(canonicalFile),
            canvas: package.canvasPixels
        )

        var comparisons: [PixelComparison] = []
        for size in [72, 96, 120, 448] {
            for background in RenderBackground.allCases {
                let scene = try RestRigScene(package: package, resourceDirectory: resources)
                guard scene.decodedBytes < 1_048_576 else {
                    throw RestRigValidationFailure("Decoded rig bytes exceeded 1 MiB.")
                }
                guard scene.enter(poseID: "ready") else {
                    throw RestRigValidationFailure("Ready pose did not enter.")
                }
                let layered = LayerSurface(size: size, background: background, content: scene.layer)
                scene.layout(in: layered.bounds, contentsScale: 1)

                let canonicalLayer = makeCanonicalLayer(image: canonical, canvas: package.canvasPixels, size: size)
                let reference = LayerSurface(size: size, background: background, content: canonicalLayer)
                let backgroundOnly = LayerSurface(size: size, background: background, content: nil)
                let rendered = layered.render()
                let expected = reference.render()
                if CommandLine.arguments.contains("--export") {
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent("spriglet-rest-rig-check", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try rendered.writePNG(to: output.appendingPathComponent("\(size)-\(background.rawValue)-layered.png"))
                    try expected.writePNG(to: output.appendingPathComponent("\(size)-\(background.rawValue)-canonical.png"))
                    if size == 72, background == .light { print("Visual evidence: \(output.path)") }
                }
                let comparison = try compare(
                    rendered: rendered,
                    canonical: expected,
                    background: backgroundOnly.render(),
                    size: size,
                    backgroundName: background.rawValue
                )
                comparisons.append(comparison)
            }
        }

        let lifecycle = try await validateFiniteLifecycle(package: package)
        return RestRigReport(
            comparisons: comparisons,
            decodedLayerBytes: lifecycle.decodedLayerBytes,
            targetCommits: lifecycle.targetCommits,
            finitePhrases: lifecycle.finitePhrases,
            displayLinkCallbacks: 0,
            colorSpaceLimitation: "Offscreen sRGB Core Animation comparison; it does not certify extended-range or wide-gamut display compositing."
        )
    }

    private func validateFiniteLifecycle(package: CharacterPackage) async throws -> LifecycleReport {
        let scene = try RestRigScene(package: package, resourceDirectory: resources)
        guard scene.decodedBytes < 1_048_576 else {
            throw RestRigValidationFailure("Decoded rig bytes exceeded 1 MiB.")
        }
        guard scene.enter(poseID: "ready") else {
            throw RestRigValidationFailure("Ready pose did not enter for lifecycle validation.")
        }
        let surface = LayerSurface(size: 120, background: .light, content: scene.layer)
        scene.layout(in: surface.bounds, contentsScale: 1)
        let window = animationWindow(containing: surface)
        defer { window.close() }

        var finishedPhrases = 0
        scene.onPhraseFinished = { finishedPhrases += 1 }

        guard scene.playPhrase(semanticID: "blink") else {
            throw RestRigValidationFailure("Blink phrase was rejected.")
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(280))
        try require(finishedPhrases == 1, "Blink did not complete exactly once.")
        try require(scene.activeAnimationCount == 0, "Blink left an animation behind.")

        guard scene.playPhrase(semanticID: "breath") else {
            throw RestRigValidationFailure("Breath phrase was rejected.")
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(3_400))
        try require(finishedPhrases == 2, "Breath did not complete exactly once.")
        try require(scene.activeAnimationCount == 0, "Breath left an animation behind.")

        guard scene.retarget(semanticID: "gaze", value: SamplePoint(x: 1, y: 0), animated: true) else {
            throw RestRigValidationFailure("Initial gaze target was rejected.")
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(90))
        guard scene.retarget(semanticID: "gaze", value: SamplePoint(x: -1, y: 0), animated: true) else {
            throw RestRigValidationFailure("In-flight gaze retarget was rejected.")
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(600))
        try require(scene.targetCommitCount == 2, "Gaze target commits were not bounded to actual target changes.")
        try require(scene.activeAnimationCount == 0, "Gaze left completed target animations behind.")

        let completionsBeforeCancellation = finishedPhrases
        guard scene.playPhrase(semanticID: "blink") else {
            throw RestRigValidationFailure("Cancellation blink was rejected.")
        }
        scene.hide()
        try require(scene.activeAnimationCount == 0, "Hide did not cancel active phrase animations.")
        guard scene.enter(poseID: "ready") else {
            throw RestRigValidationFailure("Ready pose did not re-enter after hide.")
        }
        try await Task.sleep(for: .milliseconds(280))
        try require(finishedPhrases == completionsBeforeCancellation, "Cancelled blink produced a stale completion after hide.")

        guard scene.playPhrase(semanticID: "blink") else {
            throw RestRigValidationFailure("Stop-cancellation blink was rejected.")
        }
        scene.stop()
        try require(scene.activeAnimationCount == 0, "Stop did not cancel active phrase animations.")
        try await Task.sleep(for: .milliseconds(280))
        try require(finishedPhrases == completionsBeforeCancellation, "Cancelled blink produced a stale completion after stop.")

        return LifecycleReport(
            decodedLayerBytes: scene.decodedBytes,
            targetCommits: scene.targetCommitCount,
            finitePhrases: scene.finitePhraseCount
        )
    }
}

/// Uses the production renderer for visual authority and Retina review.
@MainActor
private final class RestRigReview: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var pets: [PetRenderView] = []

    init(resources: URL) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 180, width: 740, height: 350),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Acorn — native layer handoff review"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 350))
        window.contentView = board
        for (column, size) in PetDisplaySize.allCases.enumerated() {
            let x = CGFloat(35 + column * 240)
            let label = NSTextField(labelWithString: "\(Int(96 * size.scale)) pt · production renderer")
            label.frame = NSRect(x: x, y: 300, width: 225, height: 20)
            board.addSubview(label)
            let pet = PetRenderView(frame: .zero, resourceDirectory: resources)
            pet.setDisplaySize(size)
            pet.setFrameOrigin(NSPoint(x: x + 30, y: 145))
            board.addSubview(pet)
            pets.append(pet)
        }
        let actions = [("Blink", #selector(blink)), ("Breath", #selector(breathe)),
                       ("Gaze", #selector(gaze)), ("Pet + settle", #selector(react)),
                       ("Nap", #selector(nap)), ("Wake", #selector(wake))]
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.0, target: self, action: action.1)
            button.frame = NSRect(x: 20 + index * 120, y: 50, width: 112, height: 32)
            board.addSubview(button)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func blink() { pets.forEach { _ = $0.play(.blink) } }
    @objc private func breathe() { pets.forEach { _ = $0.play(.stretch) } }
    @objc private func gaze() { pets.forEach { _ = $0.retarget(semanticID: "gaze", value: .init(x: 1, y: 0)) } }
    @objc private func react() { pets.forEach { _ = $0.play(.react) } }
    @objc private func nap() { pets.forEach { _ = $0.play(.fallAsleep) } }
    @objc private func wake() { pets.forEach { _ = $0.play(.wakeUp) } }
    func windowWillClose(_ notification: Notification) {
        pets.forEach { $0.setSuspended(true) }
        NSApp.terminate(nil)
    }
}

@MainActor
private func animationWindow(containing surface: NSView) -> NSWindow {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
    let window = NSWindow(
        contentRect: NSRect(x: visibleFrame.minX + 16, y: visibleFrame.maxY - 136, width: 120, height: 120),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.contentView = surface
    window.orderFrontRegardless()
    CATransaction.flush()
    return window
}

private enum RenderBackground: String, CaseIterable {
    case light
    case dark
    case busy

    func apply(to layer: CALayer, size: Int) {
        switch self {
        case .light:
            layer.backgroundColor = CGColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        case .dark:
            layer.backgroundColor = CGColor(red: 0.055, green: 0.075, blue: 0.09, alpha: 1)
        case .busy:
            layer.contents = busyBackground(size: size)
            layer.contentsGravity = .resize
        }
    }
}

@MainActor
private final class LayerSurface: NSView {
    private let pixelSize: Int

    init(size: Int, background: RenderBackground, content: CALayer?) {
        pixelSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let root = CALayer()
        root.frame = bounds
        root.isGeometryFlipped = true
        root.contentsScale = 1
        background.apply(to: root, size: size)
        layer = root
        wantsLayer = true
        if let content { root.addSublayer(content) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render() -> RenderedBitmap {
        CATransaction.flush()
        var bytes = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
        bytes.withUnsafeMutableBytes { memory in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(
                data: memory.baseAddress,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: pixelSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )!
            layer!.render(in: context)
        }
        return RenderedBitmap(width: pixelSize, height: pixelSize, rgba: bytes)
    }
}

private func makeCanonicalLayer(image: CGImage, canvas: SampleSize, size: Int) -> CALayer {
    let layer = CALayer()
    layer.isGeometryFlipped = true
    layer.anchorPoint = .zero
    layer.position = .zero
    layer.bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    layer.contents = image
    layer.contentsGravity = .resize
    layer.setAffineTransform(CGAffineTransform(scaleX: Double(size) / canvas.width, y: Double(size) / canvas.height))
    return layer
}

private func busyBackground(size: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let index = (y * size + x) * 4
            let tile = ((x / 9) + (y / 11)) % 3
            let colors: (UInt8, UInt8, UInt8) = tile == 0 ? (43, 82, 90) : tile == 1 ? (126, 80, 104) : (214, 172, 95)
            bytes[index] = colors.0
            bytes[index + 1] = colors.1
            bytes[index + 2] = colors.2
            bytes[index + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

private struct RenderedBitmap {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func writePNG(to url: URL) throws {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RestRigValidationFailure("Could not create native composition evidence.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Could not save native composition evidence.")
    }
}

private struct PixelComparison: Codable {
    let sizePoints: Int
    let background: String
    let maximumChannelDifference: Int
    let meanAbsoluteChannelDifference: Double
    let differingPixelFraction: Double
    let groundingRowDeltaPixels: Int
    let registrationBoundsDeltaPixels: Int
}

private func compare(rendered: RenderedBitmap, canonical: RenderedBitmap, background: RenderedBitmap,
                     size: Int, backgroundName: String) throws -> PixelComparison {
    guard rendered.width == canonical.width, rendered.height == canonical.height,
          rendered.rgba.count == canonical.rgba.count, rendered.rgba.count == background.rgba.count else {
        throw RestRigValidationFailure("Rendered image dimensions differ.")
    }
    var maximum = 0
    var total = 0
    var changedPixels = 0
    for index in stride(from: 0, to: rendered.rgba.count, by: 4) {
        var pixelChanged = false
        for channel in 0..<4 {
            let difference = abs(Int(rendered.rgba[index + channel]) - Int(canonical.rgba[index + channel]))
            maximum = max(maximum, difference)
            total += difference
            pixelChanged = pixelChanged || difference > 2
        }
        changedPixels += pixelChanged ? 1 : 0
    }
    let renderedBounds = contentBounds(rendered, against: background)
    let canonicalBounds = contentBounds(canonical, against: background)
    guard let renderedBounds, let canonicalBounds else {
        throw RestRigValidationFailure("A rest render contained no visible character pixels.")
    }
    let groundingDelta = abs(renderedBounds.maxY - canonicalBounds.maxY)
    let registrationDelta = max(
        abs(renderedBounds.minX - canonicalBounds.minX), abs(renderedBounds.maxX - canonicalBounds.maxX),
        abs(renderedBounds.minY - canonicalBounds.minY), abs(renderedBounds.maxY - canonicalBounds.maxY)
    )
    let pixels = rendered.width * rendered.height
    let mean = Double(total) / Double(rendered.rgba.count)
    let changedFraction = Double(changedPixels) / Double(pixels)
    let metrics = "max \(maximum), mean \(mean), fraction \(changedFraction)"
    try require(maximum <= (size == 448 ? 2 : 110), "Layer composition maximum error is too high at \(size) pt / \(backgroundName): \(metrics).")
    try require(mean <= 1.8, "Layer composition mean error is too high at \(size) pt / \(backgroundName): \(metrics).")
    try require(changedFraction <= 0.18, "Layer composition differs across too many pixels at \(size) pt / \(backgroundName): \(metrics).")
    try require(groundingDelta <= 1, "Grounding moved at \(size) pt / \(backgroundName).")
    try require(registrationDelta <= 1, "Layer registration moved at \(size) pt / \(backgroundName).")
    return PixelComparison(
        sizePoints: size, background: backgroundName, maximumChannelDifference: maximum,
        meanAbsoluteChannelDifference: mean, differingPixelFraction: changedFraction,
        groundingRowDeltaPixels: groundingDelta, registrationBoundsDeltaPixels: registrationDelta
    )
}

private func contentBounds(_ image: RenderedBitmap, against background: RenderedBitmap) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = (y * image.width + x) * 4
            let differs = (0..<4).contains { abs(Int(image.rgba[index + $0]) - Int(background.rgba[index + $0])) > 8 }
            guard differs else { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    return maxX >= 0 ? (minX, minY, maxX, maxY) : nil
}

private struct LifecycleReport {
    let decodedLayerBytes: Int
    let targetCommits: UInt64
    let finitePhrases: UInt64
}

private struct RestRigReport: Codable {
    let comparisons: [PixelComparison]
    let decodedLayerBytes: Int
    let targetCommits: UInt64
    let finitePhrases: UInt64
    let displayLinkCallbacks: Int
    let colorSpaceLimitation: String
}

private struct RestRigValidationFailure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RestRigValidationFailure(message) }
}
