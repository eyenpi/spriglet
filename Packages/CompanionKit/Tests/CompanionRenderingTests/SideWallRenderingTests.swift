import AppKit
import Foundation
import Testing
@testable import CompanionCore
@testable import CompanionRendering

@Suite("Rendered side-wall squash sequences") @MainActor struct SideWallRenderingTests {
    private let scene = SceneGeometry.preview

    private func snapshot(_ body: BodyPhysics, time: Double, compression: Double? = nil) -> CompanionSnapshot {
        var pose = CharacterPose()
        let deformation = compression ?? max(-0.38, min(0.2, body.compression.value))
        pose.width = 1 / (1 + deformation)
        pose.height = 1 + deformation
        pose.arm = 0.7
        return CompanionSnapshot(scene: body.scene, presence: .playing, phase: body.phase,
                                 pose: pose, feet: body.position, windowAnchor: body.position,
                                 rotation: 0, openness: 1, homeGrip: 0, time: time,
                                 gesture: nil, canCatch: false)
    }

    private func save(_ frame: CompanionSnapshot, named name: String,
                      in folder: URL, painter: ScenePreviewRenderer) throws -> NSBitmapImageRep {
        let image = try painter.image(frame)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw BitmapRenderingError.encodingFailure
        }
        try data.write(to: folder.appendingPathComponent("\(name).png"), options: .atomic)
        return image
    }

    private func assertImpactSequence(side: Double, root: URL, painter: ScenePreviewRenderer) throws {
        var impacted = BodyPhysics(scene: scene)
        let wall = side < 0 ? scene.leftLimit : scene.rightLimit
        let y = scene.floor - 80 * scene.scale
        impacted.grab(visibleFeet: Point(x: wall - side * 0.001, y: y),
                      visibleVelocity: Point(x: side * 450, y: 0),
                      target: Point(x: wall + side * 100, y: y), at: 0)
        var control = BodyPhysics(scene: scene)
        control.grab(visibleFeet: Point(x: wall - side * 0.001, y: y), target: Point(x: wall + side * 100, y: y), at: 0)
        let wallName = side < 0 ? "left" : "right"
        let folder = root.appendingPathComponent(wallName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try save(snapshot(impacted, time: 0), named: "before", in: folder, painter: painter)
        var peak = impacted, peakTime = 0.0
        var firstContact: BodyPhysics?
        for index in 0..<360 {
            let time = Double(index + 1) / 120
            impacted.step(1 / 120, at: time, walkingAmount: 0)
            control.step(1 / 120, at: time, walkingAmount: 0)
            if firstContact == nil && impacted.compression.value > 0 { firstContact = impacted }
            if impacted.compression.value > peak.compression.value {
                peak = impacted; peakTime = time
            }
        }
        let contact = try #require(firstContact)
        let contactFrame = snapshot(contact, time: 1 / 120)
        let peakFrame = snapshot(peak, time: peakTime)
        let recoveryFrame = snapshot(impacted, time: 3)
        let controlFrame = snapshot(control, time: 3, compression: 0)
        #expect(peakFrame.pose.width < 0.99)
        #expect(peakFrame.pose.height > 1)
        #expect(abs(peakFrame.pose.width * peakFrame.pose.height - 1) < 1e-12)
        #expect(abs(recoveryFrame.pose.width - 1) < 0.01)
        #expect(abs(recoveryFrame.pose.height - 1) < 0.01)
        #expect(peakFrame.hitBounds.width > 0 && peakFrame.hitBounds.height > 0)
        #expect(peakFrame.contains(Point(x: peakFrame.feet.x, y: peakFrame.feet.y - 40 * scene.scale)))

        _ = try save(contactFrame, named: "contact", in: folder, painter: painter)
        let peakImage = try save(peakFrame, named: "peak", in: folder, painter: painter)
        let recoveryImage = try save(recoveryFrame, named: "recovery", in: folder, painter: painter)
        let controlImage = try painter.image(controlFrame)
        var changedPixels = 0
        for y in stride(from: 0, to: peakImage.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: peakImage.pixelsWide, by: 2) {
                let a = peakImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = controlImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                if let a, let b {
                    let differs = abs(a.redComponent - b.redComponent) > 0.04
                        || abs(a.greenComponent - b.greenComponent) > 0.04
                        || abs(a.blueComponent - b.blueComponent) > 0.04
                    if differs { changedPixels += 1 }
                }
            }
        }
        #expect(changedPixels > 20)
        #expect(recoveryImage.representation(using: .png, properties: [:]) != nil)
        let baseline = try painter.image(controlFrame)
        guard let bytes = baseline.representation(using: .png, properties: [:]) else {
            throw BitmapRenderingError.encodingFailure
        }
        try bytes.write(to: folder.appendingPathComponent("no-impact-control.png"), options: .atomic)
    }

    private func assertCornerSequence(root: URL, painter: ScenePreviewRenderer) throws {
        var body = BodyPhysics(scene: scene)
        let feet = Point(x: scene.rightLimit - 0.001, y: scene.floor - 0.001)
        body.grab(visibleFeet: feet, visibleVelocity: Point(x: 5_000, y: 500), target: feet, at: 0)
        body.release()
        let folder = root.appendingPathComponent("right-floor-corner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try save(snapshot(body, time: 0), named: "before", in: folder, painter: painter)
        body.step(1 / 120, at: 1 / 120, walkingAmount: 0)
        let contact = snapshot(body, time: 1 / 120)
        #expect(body.compression.speed < 0)
        _ = try save(contact, named: "corner-contact-vertical-wins", in: folder, painter: painter)
        var peak = body
        for index in 1..<60 {
            body.step(1 / 120, at: Double(index + 1) / 120, walkingAmount: 0)
            if body.compression.value < peak.compression.value { peak = body }
        }
        _ = try save(snapshot(peak, time: 0.5), named: "corner-peak", in: folder, painter: painter)
        for index in 60..<360 { body.step(1 / 120, at: Double(index + 1) / 120, walkingAmount: 0) }
        _ = try save(snapshot(body, time: 3), named: "corner-recovery", in: folder, painter: painter)
    }

    @Test("Production renderer shows before, contact, peak and recovery at both walls")
    func bothWalls() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../../docs/next-update/side-wall-squish-evidence", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let painter = ScenePreviewRenderer()
        try assertImpactSequence(side: -1, root: root, painter: painter)
        try assertImpactSequence(side: 1, root: root, painter: painter)
        try assertCornerSequence(root: root, painter: painter)
        try Data("Generated by SideWallRenderingTests with BodyPhysics and ScenePreviewRenderer. Frames: before, contact, peak, recovery and no-impact-control for both walls.\n".utf8)
            .write(to: root.appendingPathComponent("README.txt"), options: .atomic)
    }
}
