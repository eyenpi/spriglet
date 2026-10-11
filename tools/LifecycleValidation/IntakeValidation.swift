import AppKit
import CompanionCore
import CompanionRendering

/// Real OCR/detectors and native views; an isolated fake prevents personal Reminders writes.
@MainActor private final class IntakeReminderFixture: ReminderWriting {
    let lists = [ReminderList(id: "fixture", title: "Reminders")]
    var defaultList: ReminderList? { lists.first }
    var added: [ReminderDraft] = []
    var notes = ""
    var deleted: [String] = []
    func add(_ drafts: [ReminderDraft], notes: String) async throws -> [String] {
        added = drafts; self.notes = notes; return drafts.map { $0.id.uuidString }
    }
    func delete(_ ids: [String]) throws { deleted = ids }
}
@MainActor enum IntakeValidation {
    static func storage() throws {
        let suite = "dev.spriglet.intake-validation.\(UUID().uuidString)", now = Date()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IntakeStore(defaults: defaults, now: { now })
        let item = IntakeItem(source: .text, text: "Call Sam October 15, 2026 at 9 AM")
        let analysis = LocalIntakeAnalyzer.detect(item)
        try LifecycleValidation.require(analysis.confidence == .medium && analysis.reminders.first?.due != nil, "Date-detector fallback lost its reviewable date")
        try store.save(item, analysis: analysis); store.record("pocket", source: .text)
        let reloaded = IntakeStore(defaults: defaults, now: { now.addingTimeInterval(604799) })
        try LifecycleValidation.require(reloaded.items.first?.item == item && reloaded.learning.bonus("pocket", source: .text) > 0, "Pocket/learning did not restore")
        let expired = IntakeStore(defaults: defaults, now: { now.addingTimeInterval(604800) })
        try LifecycleValidation.require(expired.items.isEmpty, "Expired Pocket item survived reload")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("https://example.com/task", forType: .string)
        try LifecycleValidation.require(try IntakeDropReader.read(board)?.source == .url, "Text URL did not normalize")
        board.clearContents(); board.setString("  hello\r\nworld  ", forType: .string)
        try LifecycleValidation.require(try IntakeDropReader.read(board)?.text == "hello\nworld", "Text drop did not normalize")
        print("Intake storage/detectors passed: normalization, persistent learning, exact seven-day expiry.")
    }
    static func run(screen: NSScreen, output: URL) async throws {
        try storage()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "dev.spriglet.intake-native.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = IntakeReminderFixture(), store = IntakeStore(defaults: defaults)
        let analyzer = LocalIntakeAnalyzer(modelsEnabled: false)
        let screenshot = try image(text: "Renew passport\nOctober 20, 2026 at 10:00 AM", illustrated: false)
        let session = IntakeSession(store: store, reminders: writer, analyzer: analyzer)
        let environment = DesktopEnvironment(applicationCenter: NotificationCenter(), workspaceCenter: NotificationCenter(), lockCenter: NotificationCenter(), displays: { [DisplayContext(screen: screen)] })
        let runtime = CompanionRuntime(intake: session, environment: environment, introductionPreferences: IntroductionPreferences(defaults: defaults), preferenceStore: PreferenceStore(defaults: defaults))
        runtime.start(); defer { runtime.stop() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func drop(_ name: String, text: String? = nil, image: Data? = nil) async throws {
            let began = Date()
            board.clearContents()
            if let text { board.setString(text, forType: .string) }
            if let image { board.setData(image, forType: NSPasteboard.PasteboardType("public.png")) }
            try LifecycleValidation.require(session.drop.onDrop?(board) == true, "Production drop callback rejected \(name)")
            let expires = Date().addingTimeInterval(7)
            while !session.card.isVisible && Date() < expires { try await Task.sleep(for: .milliseconds(50)) }
            try LifecycleValidation.require(session.card.isVisible, "Intake card did not finish \(name)")
            try await Task.sleep(for: .milliseconds(400))
            try capture(session: session, name: name, output: output)
            print("\(name) pipeline: \(Date().timeIntervalSince(began)) seconds")
        }
        try await drop("01-text", text: "Call Sam on October 15, 2026 at 9 AM")
        try LifecycleValidation.require(writer.added.isEmpty, "Analysis wrote a reminder without Add")
        guard let compact = session.card.panel, let content = compact.contentView else { throw ValidationFailure(description: "Compact card missing") }
        try LifecycleValidation.require(compact.frame.width == 320 && compact.frame.height < 250, "Default card is not compact")
        try LifecycleValidation.require(!descendants(content).contains(where: { $0 is NSDatePicker }), "Compact card exposed editing fields")
        guard let edit = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Edit" }) else { throw ValidationFailure(description: "Edit missing") }
        try LifecycleValidation.require(compact.firstResponder === edit, "Medium confidence did not focus Edit")
        edit.performClick(nil); try await Task.sleep(for: .milliseconds(400))
        try capture(session: session, name: "05-expanded-edit", output: output)
        guard let title = descendants(compact.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.stringValue.contains("Call Sam") }),
              let done = descendants(compact.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Done" }) else { throw ValidationFailure(description: "Inline fields missing") }
        title.stringValue = "Call Sam"
        done.performClick(nil); try await Task.sleep(for: .milliseconds(400))
        try LifecycleValidation.require(session.card.editedAnalysis?.reminders.first?.title == "Call Sam" && compact.frame.height < 250, "Collapse lost edited title or stayed expanded")
        compact.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(100))
        try LifecycleValidation.require(store.items.count == 1, "Dismiss did not Pocket the item")
        runtime.perform(.reopen(store.items[0].id))
        try LifecycleValidation.require(session.card.isVisible, "Pocket did not reopen the card")
        // Use the actual native button and edited/selected fields, not a second action path.
        guard let panel = session.card.panel, let add = descendants(panel.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Add" }) else { throw ValidationFailure(description: "Add control missing") }
        add.performClick(nil); try await Task.sleep(for: .milliseconds(400))
        try LifecycleValidation.require(writer.added.count == 1 && writer.added[0].due != nil && writer.notes.contains("Call Sam"), "Confirmed Add lost due date or source notes")
        try capture(session: session, name: "02-undo", output: output)
        guard let undoPanel = session.card.panel else { throw ValidationFailure(description: "Undo panel missing") }
        let undoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: undoPanel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        try LifecycleValidation.require(undoPanel.performKeyEquivalent(with: undoEvent), "Command-Z was not handled")
        try LifecycleValidation.require(writer.deleted.count == 1, "Undo did not delete the created reminder")
        try screenshot.write(to: output.appendingPathComponent("source-screenshot.png"))
        try await drop("03-screenshot-with-date", image: screenshot)
        guard let card = session.card.panel?.contentView else { throw ValidationFailure(description: "OCR card missing") }
        let texts = descendants(card).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        try LifecycleValidation.require(texts.contains("passport") && texts.contains("2026"), "Vision did not extract screenshot task/date")
        runtime.perform(IntakeCommand.dismiss)
        let picture = try image(text: "", illustrated: true)
        try picture.write(to: output.appendingPathComponent("source-image.png"))
        try await drop("04-image-no-date", image: picture)
        let buttons = descendants(session.card.panel!.contentView!).compactMap { $0 as? NSButton }
        try LifecycleValidation.require(!buttons.contains(where: { $0.title == "Add" }) && buttons.contains(where: { $0.title == "Pocket" }), "Low-confidence image offered Add")
        runtime.perform(IntakeCommand.dismiss)
        try LifecycleValidation.require(store.items.count == 2, "Pocket item counts changed after Add/Undo and image drops")
        print("Native intake passed: production drop callback, real Vision OCR, detector fallback, native Add, fake-writer Undo, Pocket reopen; exported \(output.lastPathComponent). Physical dragging and real EventKit permission are separate.")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func image(text: String, illustrated: Bool) throws -> Data {
        let image = NSImage(size: NSSize(width: 680, height: 280))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 680, height: 280).fill()
        if illustrated {
            NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: -80, y: -160, width: 700, height: 360)).fill()
            NSColor(calibratedRed: 0.5, green: 0.4, blue: 0.7, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 280, y: -190, width: 600, height: 320)).fill()
        } else {
            (text as NSString).draw(in: NSRect(x: 40, y: 50, width: 600, height: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { throw ValidationFailure(description: "Could not create fixture image") }
        return png
    }
    private static func capture(session: IntakeSession, name: String, output: URL) throws {
        guard let panel = session.card.panel, let card = panel.contentView, let characterPanel = NSApp.windows.first(where: { $0.contentView is CompanionView }), let character = characterPanel.contentView as? CompanionView else { throw ValidationFailure(description: "Native intake views missing") }
        card.layoutSubtreeIfNeeded()
        guard let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { throw ValidationFailure(description: "Card bitmap missing") }
        card.cacheDisplay(in: card.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ValidationFailure(description: "Card PNG missing") }
        try png.write(to: output.appendingPathComponent(name + "-card.png"))
        let snapshot = character.snapshot
        let preview = try ScenePreviewRenderer().image(snapshot)
        // Crop only the production character and its housing; no private desktop is captured.
        let box = snapshot.hitBounds
        let rect = CGRect(x: max(0, box.midX - 140), y: 0, width: 280, height: min(180, box.maxY + 35))
        if let cg = preview.cgImage?.cropping(to: rect) {
            let image = NSBitmapImageRep(cgImage: cg)
            if let png = image.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name + "-mallow.png")) }
            // A clean simulated backdrop combines the captured native card with
            // the production snapshot; no other desktop content enters evidence.
            let flow = NSImage(size: NSSize(width: 430, height: card.bounds.height + 170))
            flow.lockFocus()
            NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.99, alpha: 1).setFill()
            NSRect(origin: .zero, size: flow.size).fill()
            NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).draw(in: NSRect(x: 75, y: card.bounds.height + 25, width: 280, height: CGFloat(cg.height)))
            if let cardCG = bitmap.cgImage {
                NSImage(cgImage: cardCG, size: card.bounds.size).draw(in: NSRect(x: (430 - card.bounds.width) / 2, y: 20, width: card.bounds.width, height: card.bounds.height))
            }
            flow.unlockFocus()
            if let data = flow.tiffRepresentation, let result = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                try result.write(to: output.appendingPathComponent(name + "-flow.png"))
            }
        }
    }
}
