import AppKit
import ImageIO
import SprigletCore

/// Reproducible review media from the exact Blender frames and root metadata.
/// This is an offline comparison, explicitly not a desktop screen recording.
@main
enum RenderMedia {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: RenderMedia <candidate asset root> <output directory>")
            exit(2)
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let framesURL = output.appendingPathComponent("media-frames")
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        let candidates = ["acorn-hopper", "moss-mouse"]
        var manifests: [SproutSampleManifest] = []
        var images: [[String: NSImage]] = []
        for candidate in candidates {
            let runtime = root.appendingPathComponent(candidate).appendingPathComponent("runtime")
            let manifest = try SproutSampleManifest.decode(Data(contentsOf: runtime.appendingPathComponent("manifest.json")))
            manifests.append(manifest)
            let names = Set([manifest.restFrame, manifest.sleepFrame] + manifest.clips.values.flatMap { $0.frames.map(\.file) })
            var cache: [String: NSImage] = [:]
            for name in names {
                guard let source = CGImageSourceCreateWithURL(runtime.appendingPathComponent(name) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MediaError.missingFrame }
                cache[name] = NSImage(cgImage: image, size: NSSize(width: 448, height: 448))
            }
            images.append(cache)
        }
        // Holds are static source images, not invented in-between poses.
        let sections: [(clip: String, count: Int, title: String)] = [
            ("rest", 15, "Meet the pair"), ("idle", 42, "A curious little pause"),
            ("rest", 10, "Ready…"), ("walkRight", 24, "One hop / two quick bounds"),
            ("rightHold", 12, "A clean stop"), ("walkLeft", 24, "And back again"),
            ("rest", 12, "Ready for a pet?"), ("pet", 30, "Very pleased with themselves"),
            ("settle", 18, "A soft settle"), ("rest", 10, "Getting sleepy…"),
            ("sleep", 36, "Leaf ears down. Eyes closed. Nap time."), ("rest", 17, "Two little forest troublemakers")
        ]
        let timeline = sections.flatMap { section in
            (0..<section.count).map { (clip: section.clip, index: $0, title: section.title) }
        }
        for (frame, moment) in timeline.enumerated() {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 940, pixelsHigh: 670,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw MediaError.context }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 940, height: 670)).fill()
            text("Acorn Hopper + Moss Mouse", x: 30, y: 620, size: 27, weight: .semibold)
            text("Refinement 02 · actual Blender models, rigs and rendered animation", x: 31, y: 593, size: 14)
            for (column, candidate) in candidates.enumerated() {
                let x = 26.0 + Double(column) * 458
                let manifest = manifests[column]
                let cache = images[column]
                text(candidate == "acorn-hopper" ? "Acorn Hopper" : "Moss Mouse", x: x + 12, y: 551, size: 21, weight: .semibold)
                text(candidate == "acorn-hopper" ? "Springy, cheeky, a little overconfident" : "Curious, quick, with twitchy leaf ears", x: x + 12, y: 528, size: 13)
                let right = manifest.clips["walkRight"]!.frames
                let left = manifest.clips["walkLeft"]!.frames
                let scale = 96.0 / 224.0
                let travel = right.last!.rootOffsetPoints.x
                let pose: SproutSampleManifest.Frame
                let base: Double
                if moment.clip == "rest" {
                    pose = right[0]; base = 0
                } else if moment.clip == "sleep" {
                    pose = .init(file: manifest.sleepFrame, rootOffsetPoints: .init(x: 0, y: 0)); base = 0
                } else if moment.clip == "rightHold" {
                    pose = right.last!; base = 0
                } else if moment.clip == "walkLeft" {
                    pose = left[moment.index]; base = travel
                } else {
                    pose = manifest.clips[moment.clip]!.frames[moment.index]; base = 0
                }
                cache[pose.file]?.draw(in: NSRect(x: x + 92, y: 300, width: 248, height: 248))
                text("Enlarged pose inspection · movement shown below", x: x + 66, y: 288, size: 11)
                for row in 0..<2 {
                    let y = row == 0 ? 167.0 : 52.0
                    let card = NSRect(x: x, y: y, width: 432, height: 108)
                    (row == 0 ? NSColor.white : NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
                    text(row == 0 ? "96 PX CANVAS / LIGHT" : "96 PX CANVAS / DARK",
                         x: x + 14, y: y + 85, size: 9, color: row == 0 ? .darkGray : .lightGray)
                    cache[pose.file]?.draw(in: NSRect(x: x + 92 + (base + pose.rootOffsetPoints.x) * scale,
                                                     y: y + 1 + pose.rootOffsetPoints.y * scale, width: 96, height: 96))
                }
            }
            text(moment.title, x: 30, y: 23, size: 13, weight: .medium)
            text("Offline render · native 96-point playback available in Candidate Review", x: 520, y: 24, size: 10)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: framesURL.appendingPathComponent(String(format: "%04d.png", frame)), options: .atomic)
            if frame == 0 { try data.write(to: output.appendingPathComponent("comparison.png"), options: .atomic) }
            if moment.clip == "pet" && moment.index == 15 {
                try data.write(to: output.appendingPathComponent("affection-comparison.png"), options: .atomic)
            }
            if moment.clip == "sleep" && moment.index == 0 {
                try data.write(to: output.appendingPathComponent("sleep-comparison.png"), options: .atomic)
            }
        }
        print("Rendered \(timeline.count) review frames at 30 fps.")
    }

    @MainActor private static func text(_ string: String, x: Double, y: Double, size: CGFloat,
                                       weight: NSFont.Weight = .regular, color: NSColor = .darkGray) {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color]).draw(at: NSPoint(x: x, y: y))
    }

    private enum MediaError: Error { case missingFrame, context }
}
