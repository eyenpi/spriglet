import AppKit
import QuartzCore
import SprigletCore

/// A disposable, visible comparison using the shipping PetRenderView. The
/// parent's bounds transform presents its 224-unit canvas at 96 native points.
/// No app preferences, shipping assets, or desktop permissions are involved.
@main
enum CandidateReview {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let checkout = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let assets = value("--assets").map { URL(fileURLWithPath: $0) }
            ?? checkout.appendingPathComponent("art/candidates/refinement-v02")
        let report = value("--report").map { URL(fileURLWithPath: $0) }
            ?? checkout.appendingPathComponent(".build/candidate-refinement/native-playback.json")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = ReviewRunner(assets: assets, report: report, checkOnly: arguments.contains("--check"))
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}

private struct Observation: Codable {
    let candidate: String
    let background: String
    let action: String
    let canvasPoints: [Double]
    let backingPixels: [Double]
    let acceptedFrames: Int
    let completed: Bool
    let underruns: UInt64
    let movementErrorPoints: Double
    let travelPoints: Double
    let stoppedAtRest: Bool
    let assetError: String?

    var passed: Bool {
        canvasPoints.allSatisfy { abs($0 - 96) < 0.001 }
            && acceptedFrames > 12 && completed && underruns == 0
            && movementErrorPoints < 0.001
            && (action.hasPrefix("walk") ? abs(travelPoints) > 90 : abs(travelPoints) < 0.001)
            && stoppedAtRest && assetError == nil
    }
}

@MainActor
private final class ProofPet {
    let candidate: String
    let background: String
    let renderer: PetRenderView
    let host: NSView
    let home: NSPoint
    let canvasSize: Double
    let followsTravel: Bool
    weak var board: NSView?
    private var start = NSPoint.zero
    private var submittedBefore: UInt64 = 0
    private var underrunsBefore: UInt64 = 0
    private var accepted = 0
    private var maximumError = 0.0

    init(candidate: String, background: String, resources: URL, board: NSView, origin: NSPoint,
         canvasSize: Double = 96, followsTravel: Bool = true) {
        self.candidate = candidate
        self.background = background
        self.board = board
        self.canvasSize = canvasSize
        self.followsTravel = followsTravel
        home = origin
        start = origin
        host = NSView(frame: NSRect(origin: origin, size: NSSize(width: canvasSize, height: canvasSize)))
        host.wantsLayer = true
        host.setBoundsSize(NSSize(width: 224, height: 224))
        renderer = PetRenderView(frame: NSRect(x: 0, y: 0, width: 224, height: 224), resourceDirectory: resources)
        host.addSubview(renderer)
        board.addSubview(host)
        renderer.onFrame = { [weak self] snapshot in
            guard let self, let board = self.board else { return false }
            let scale = self.followsTravel ? self.canvasSize / 224.0 : 0
            let expected = NSPoint(x: self.start.x + snapshot.rootOffsetPoints.x * scale,
                                   y: self.start.y + snapshot.rootOffsetPoints.y * scale)
            self.host.setFrameOrigin(expected)
            let actual = self.renderer.convert(self.renderer.bounds, to: board).origin
            self.maximumError = max(self.maximumError, hypot(actual.x - expected.x, actual.y - expected.y))
            self.accepted += 1
            return true
        }
    }

    func play(_ action: String) {
        renderer.resetPose()
        // Replay always starts in a known position. Leftward travel begins at
        // the right endpoint so the entire trajectory fits in its review card.
        let sourceTravel = renderer.manifest?.clips[action]?.frames.last?.rootOffsetPoints.x ?? 0
        start = NSPoint(x: home.x + (action == "walkLeft" && followsTravel ? -sourceTravel * canvasSize / 224 : 0), y: home.y)
        host.setFrameOrigin(start)
        accepted = 0
        maximumError = 0
        submittedBefore = renderer.submittedFrameCount
        underrunsBefore = renderer.bufferUnderrunCount
        switch action {
        case "walkRight": renderer.playWalk(.walkRight)
        case "walkLeft": renderer.playWalk(.walkLeft)
        case "idle": renderer.play(.blink)
        case "pet": renderer.play(.react)
        case "sleep": renderer.play(.fallAsleep)
        default: break
        }
    }

    func reset() {
        renderer.resetPose()
        start = home
        host.setFrameOrigin(home)
    }

    func observation(_ action: String, stopped: Bool) -> Observation {
        let visible = renderer.convert(renderer.bounds, to: board)
        let backing = renderer.convertToBacking(renderer.bounds)
        return Observation(candidate: candidate, background: background, action: action,
                           canvasPoints: [visible.width, visible.height],
                           backingPixels: [backing.width, backing.height], acceptedFrames: accepted,
                           completed: renderer.currentSnapshot?.isComplete == true && renderer.submittedFrameCount > submittedBefore,
                           underruns: renderer.bufferUnderrunCount - underrunsBefore,
                           movementErrorPoints: maximumError, travelPoints: host.frame.minX - start.x,
                           stoppedAtRest: stopped, assetError: renderer.assetError)
    }
}

@MainActor
private final class ReviewRunner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let assets: URL
    private let report: URL
    private let checkOnly: Bool
    private var window: NSWindow?
    private var pets: [ProofPet] = []
    private var enlarged: [ProofPet] = []
    private let status = NSTextField(labelWithString: "Loading Blender models…")
    private var task: Task<Void, Never>?
    private var observations: [Observation] = []
    private var sleepChecksPassed = false
    private var checking = true
    private var buttons: [NSButton] = []

    init(assets: URL, report: URL, checkOnly: Bool) {
        self.assets = assets; self.report = report; self.checkOnly = checkOnly
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Candidate Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        appMenu.addItem(item)
        NSApp.mainMenu = appMenu
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 670))
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        label("Two little forest troublemakers", at: NSRect(x: 30, y: 617, width: 700, height: 32), size: 26, weight: .semibold, in: board)
        label("Refinement 02 · idle, movement, affection and sleep · real Spriglet playback", at: NSRect(x: 31, y: 590, width: 850, height: 23), size: 13, in: board)
        for (column, candidate) in ["acorn-hopper", "moss-mouse"].enumerated() {
            let x = 26.0 + Double(column) * 458
            let title = column == 0 ? "Acorn Hopper" : "Moss Mouse"
            let subtitle = column == 0 ? "Springy, pleased with itself, a wobbly little cap" : "Curious, darting, independently twitching leaf ears"
            label(title, at: NSRect(x: x + 12, y: 550, width: 400, height: 28), size: 20, weight: .semibold, in: board)
            label(subtitle, at: NSRect(x: x + 12, y: 527, width: 400, height: 21), size: 12, in: board)
            let resources = assets.appendingPathComponent(candidate).appendingPathComponent("runtime")
            enlarged.append(ProofPet(candidate: candidate, background: "inspection", resources: resources,
                                     board: board, origin: NSPoint(x: x + 92, y: 300), canvasSize: 248, followsTravel: false))
            label("Enlarged pose inspection · movement shown below", at: NSRect(x: x + 67, y: 288, width: 330, height: 18), size: 11, in: board)
            for (row, background) in ["light", "dark"].enumerated() {
                let y = row == 0 ? 169.0 : 55.0
                let card = NSView(frame: NSRect(x: x, y: y, width: 432, height: 107))
                card.wantsLayer = true
                card.layer?.cornerRadius = 12
                card.layer?.backgroundColor = (row == 0 ? NSColor.white : NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1)).cgColor
                board.addSubview(card)
                label(row == 0 ? "ACTUAL SIZE / LIGHT" : "ACTUAL SIZE / DARK",
                      at: NSRect(x: x + 14, y: y + 83, width: 270, height: 15), size: 9,
                      color: row == 0 ? .secondaryLabelColor : NSColor(calibratedWhite: 0.68, alpha: 1), in: board)
                let pet = ProofPet(candidate: candidate, background: background, resources: resources,
                                   board: board, origin: NSPoint(x: x + 92, y: y + 1))
                pets.append(pet)
            }
        }
        for (i, title) in ["Curious", "Hop / dash →", "← Replay", "Pet both", "Nap", "Rest"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(control(_:)))
            button.tag = i
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 24 + i * 105, y: 14, width: 101, height: 28)
            button.isEnabled = false
            board.addSubview(button)
            buttons.append(button)
        }
        status.frame = NSRect(x: 662, y: 17, width: 265, height: 23)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        board.addSubview(status)
        let window = NSWindow(contentRect: board.bounds, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Spriglet · Candidate Review"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = board
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        task = Task { await validate() }
    }

    private func label(_ title: String, at frame: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, in view: NSView) {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.frame = frame
        view.addSubview(field)
    }

    @objc private func control(_ sender: NSButton) {
        guard !checking else { return }
        if sender.tag == 5 {
            (pets + enlarged).forEach { $0.reset() }
        } else {
            let action = ["idle", "walkRight", "walkLeft", "pet", "sleep"][sender.tag]
            (pets + enlarged).forEach { $0.play(action) }
        }
    }

    private func validate() async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            for action in ["idle", "walkRight", "walkLeft", "pet"] {
                status.stringValue = "Checking \(action) at 96 points…"
                (pets + enlarged).forEach { $0.play(action) }
                try await Task.sleep(for: .seconds(2.5))
                let settled = pets.map { ($0.renderer.submittedFrameCount, $0.renderer.displayLinkCallbackCount) }
                try await Task.sleep(for: .milliseconds(400))
                for (index, pet) in pets.enumerated() {
                    let stopped = !pet.renderer.isAnimating && !pet.renderer.hasActiveDisplayLink
                        && pet.renderer.submittedFrameCount == settled[index].0
                        && pet.renderer.displayLinkCallbackCount == settled[index].1
                    observations.append(pet.observation(action, stopped: stopped))
                }
            }
            (pets + enlarged).forEach { $0.play("sleep") }
            try await Task.sleep(for: .milliseconds(200))
            let sleepCounts = pets.map { ($0.renderer.submittedFrameCount, $0.renderer.displayLinkCallbackCount) }
            try await Task.sleep(for: .milliseconds(400))
            sleepChecksPassed = pets.enumerated().allSatisfy { index, pet in
                pet.renderer.isSleeping && !pet.renderer.isAnimating && !pet.renderer.hasActiveDisplayLink
                    && pet.renderer.submittedFrameCount == sleepCounts[index].0
                    && pet.renderer.displayLinkCallbackCount == sleepCounts[index].1 && pet.renderer.assetError == nil
            }
            let passed = observations.count == 16 && observations.allSatisfy(\.passed) && sleepChecksPassed
            try writeReport(passed: passed)
            checking = false
            buttons.forEach { $0.isEnabled = true }
            status.stringValue = passed ? "96 pt · finite playback + nap checked" : "Playback needs attention — see report"
            (pets + enlarged).forEach { $0.reset() }
            try await Task.sleep(for: .milliseconds(150))
            if let board = window?.contentView,
               let bitmap = board.bitmapImageRepForCachingDisplay(in: board.bounds) {
                board.cacheDisplay(in: board.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: report.deletingLastPathComponent().appendingPathComponent("native-review.png"), options: .atomic)
            }
            if checkOnly { exit(passed ? 0 : 1) }
        } catch is CancellationError {
            // Closing the review stops all renderers and leaves no clock running.
        } catch {
            checking = false
            status.stringValue = error.localizedDescription
            if checkOnly { exit(1) }
        }
    }

    private func writeReport(passed: Bool) throws {
        struct Report: Encodable {
            let passed: Bool
            let renderer: String
            let observations: [Observation]
            let sleepChecksPassed: Bool
            let limitation: String
        }
        let value = Report(passed: passed, renderer: "Unmodified shipping PetRenderView and SampleImageDecoder",
                           observations: observations, sleepChecksPassed: sleepChecksPassed,
                           limitation: "Embedded native view verifies size, finite playback, root placement and stopped work; not separate desktop panels, all-frame presentation, or artistic approval.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: report, options: .atomic)
        print("Candidate native playback: \(passed ? "PASS" : "FAIL") (\(observations.count) sequences)")
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        (pets + enlarged).forEach { $0.renderer.setSuspended(true) }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel()
        (pets + enlarged).forEach { $0.renderer.setSuspended(true) }
    }
}
