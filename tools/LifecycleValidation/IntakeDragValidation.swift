import AppKit
import CompanionCore

@MainActor private final class IntakeDraggingFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint(x: 80, y: 80)
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    init(board: NSPasteboard, window: NSWindow) { draggingPasteboard = board; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor enum IntakeDragValidation {
    static func run() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let view = IntakeDropView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        let panel = IntakeDropPanel(content: view); defer { panel.close() }
        // A clear destination was skipped by WindowServer before any drag callbacks.
        try LifecycleValidation.require(panel.backgroundColor.alphaComponent > 0 && !panel.ignoresMouseEvents,
                                        "Native drop surface is invisible to WindowServer input")
        let notchFrame = NSRect(x: 675, y: 848, width: 160, height: 160)
        panel.setFrame(notchFrame, display: false)
        try LifecycleValidation.require(abs(panel.frame.midY - notchFrame.midY) <= 1 && !panel.canBecomeKey,
                                        "Notch drop surface moved or stole keyboard focus")
        let info = IntakeDraggingFixture(board: board, window: panel)
        var received: IntakeItem?
        view.onDrop = { received = try? IntakeDropReader.read($0); return received != nil }
        board.setString("Call Sam on October 15, 2026", forType: .string)
        try LifecycleValidation.require(view.draggingEntered(info) == .copy && view.hasNativeDrag,
                                        "Native text entry was rejected")
        info.draggingLocation = NSPoint(x: 159, y: 159)
        try LifecycleValidation.require(view.draggingUpdated(info).isEmpty && !view.prepareForDragOperation(info),
                                        "Rectangular corner escaped the 80-point circle")
        info.draggingLocation = NSPoint(x: 80, y: 80)
        info.draggingSourceOperationMask = .move
        try LifecycleValidation.require(view.draggingUpdated(info).isEmpty, "Copy-only destination accepted a move-only source")
        info.draggingSourceOperationMask = .copy
        try LifecycleValidation.require(view.prepareForDragOperation(info) && view.performDragOperation(info)
            && received?.source == .text && received?.text.contains("Call Sam") == true,
            "Native drop did not reach the intake reader")
        info.draggingSourceOperationMask = .generic
        try LifecycleValidation.require(view.draggingUpdated(info) == .generic
            && view.prepareForDragOperation(info) && view.performDragOperation(info),
            "TextEdit's generic selected-text transfer was rejected")
        view.concludeDragOperation(info)
        try LifecycleValidation.require(!view.hasNativeDrag, "Concluded native drag stayed active")
        board.clearContents(); board.setString("   ", forType: .string)
        try LifecycleValidation.require(!view.performDragOperation(info), "Unreadable payload reported a successful drop")
        board.clearContents(); board.setData(Data([1, 2]), forType: .init("application/x-unsupported"))
        try LifecycleValidation.require(view.draggingEntered(info).isEmpty, "Unsupported pasteboard advertised acceptance")
        view.draggingExited(info)
        for type in [NSPasteboard.PasteboardType.string, .URL, .fileURL, .tiff, .init("public.png")] {
            try LifecycleValidation.require(view.registeredDraggedTypes.contains(type), "Supported drag type is not registered: \(type)")
        }
        #if DEBUG
        try LifecycleValidation.require(DebugIntakeArgument.parse(arguments: ["app", "-SprigletDebugIntakeText", "Call Sam"])?.text == "Call Sam",
                                        "Debug text argument did not create an intake item")
        try LifecycleValidation.require(DebugIntakeArgument.parse(arguments: ["app", "-SprigletDebugIntakeText"]) == nil
            && DebugIntakeArgument.parse(arguments: ["app", "-SprigletDebugIntakeText", "  "]) == nil,
            "Missing or empty debug input was accepted")
        #endif
        print("Intake drag validation passed: native backing/placement, registered types, Finder copy/TextEdit generic masks, circular bounds, prepare/perform results and Debug input. Physical dispatch is separate.")
    }
}
