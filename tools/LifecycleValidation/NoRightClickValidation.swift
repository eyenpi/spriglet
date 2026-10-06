import AppKit
import CompanionCore

@MainActor enum NoRightClickValidation {
    static func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1,
                      windowNumber: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                           windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    static func detachedView() throws {
        guard let screen = NSScreen.screens.first else {
            throw ValidationFailure(description: "No display context for detached no-right-click view probe")
        }
        let context = DisplayContext(screen: screen)
        let view = CompanionView(context: context, snapshot: CompanionEngine(scene: context.scene).snapshot)
        var inputs: [CompanionInput] = []
        var pointerKinds: [String] = []
        view.onInput = { inputs.append($0) }
        view.onPointerInput = { event in
            switch event {
            case .pressed: pointerKinds.append("pressed")
            case .dragged: pointerKinds.append("dragged")
            case .released: pointerKinds.append("released")
            }
        }

        let initialSnapshot = view.snapshot
        view.rightMouseDown(with: event(.rightMouseDown))
        view.rightMouseDragged(with: event(.rightMouseDragged))
        view.rightMouseUp(with: event(.rightMouseUp))
        try LifecycleValidation.require(inputs.isEmpty && pointerKinds.isEmpty,
                                        "Secondary click or its follow-up phases reached Mallow input")
        try LifecycleValidation.require(view.menu(for: nil) == nil, "Mallow exposed a native context menu")

        view.mouseDown(with: event(.leftMouseDown, modifiers: .control))
        view.mouseDragged(with: event(.leftMouseDragged, modifiers: .control))
        view.rightMouseDown(with: event(.rightMouseDown))
        view.rightMouseDragged(with: event(.rightMouseDragged))
        view.rightMouseUp(with: event(.rightMouseUp))
        view.mouseUp(with: event(.leftMouseUp))
        try LifecycleValidation.require(inputs.isEmpty && pointerKinds.isEmpty,
                                        "Control-primary sequence escaped suppression after modifier release")

        view.mouseDown(with: event(.leftMouseDown))
        view.rightMouseDown(with: event(.rightMouseDown))
        view.rightMouseDragged(with: event(.rightMouseDragged))
        view.rightMouseUp(with: event(.rightMouseUp))
        view.mouseDragged(with: event(.leftMouseDragged, modifiers: .control))
        view.mouseUp(with: event(.leftMouseUp, modifiers: .control))
        for clickCount in [1, 2] {
            view.mouseDown(with: event(.leftMouseDown, clickCount: clickCount))
            view.mouseUp(with: event(.leftMouseUp, clickCount: clickCount))
        }
        try LifecycleValidation.require(pointerKinds == ["pressed", "dragged", "released", "pressed", "released", "pressed", "released"],
                                        "Ordinary primary click/drag sequences changed under secondary or later Control events")
        try LifecycleValidation.require(inputs.isEmpty && view.snapshot.feet == initialSnapshot.feet
                                        && view.snapshot.phase == initialSnapshot.phase,
                                        "Ignored context gesture changed Mallow state")

        try assertNoAccessibilityMenu(view)
        view.onInput = nil; view.onPointerInput = nil
        print("No-right-click detached validation passed: secondary phases and Control-primary suppressed; normal click/drag/double-click and direct accessibility retained.")
    }

    static func nativeEventPaths(on view: CompanionView, windowNumber: Int) throws {
        view.rightMouseDown(with: event(.rightMouseDown, windowNumber: windowNumber))
        view.rightMouseDragged(with: event(.rightMouseDragged, windowNumber: windowNumber))
        view.rightMouseUp(with: event(.rightMouseUp, windowNumber: windowNumber))
        view.mouseDown(with: event(.leftMouseDown, modifiers: .control, windowNumber: windowNumber))
        view.mouseDragged(with: event(.leftMouseDragged, modifiers: .control, windowNumber: windowNumber))
        view.rightMouseDown(with: event(.rightMouseDown, windowNumber: windowNumber))
        view.rightMouseDragged(with: event(.rightMouseDragged, windowNumber: windowNumber))
        view.rightMouseUp(with: event(.rightMouseUp, windowNumber: windowNumber))
        view.mouseUp(with: event(.leftMouseUp, windowNumber: windowNumber))
        try assertNoAccessibilityMenu(view)
    }

    static func assertNoAccessibilityMenu(_ view: CompanionView) throws {
        let showMenu = #selector(CompanionView.accessibilityPerformShowMenu)
        try LifecycleValidation.require(!view.isAccessibilitySelectorAllowed(showMenu) && !view.accessibilityPerformShowMenu(),
                                        "VoiceOver Show Menu remained available for Mallow")
        try LifecycleValidation.require(view.menu(for: nil) == nil, "Mallow exposed a native context menu")
        let labels = Set((view.accessibilityCustomActions() ?? []).map(\.name))
        try LifecycleValidation.require([AppText.inviteMallow, AppText.swingMallow, AppText.stretchMallow,
                                         AppText.bringHome, AppText.pauseMallow, AppText.hideMallow,
                                         AppText.settingsMenu, AppText.introductionMenu, AppText.supportTitle].allSatisfy(labels.contains),
                                        "Removing the menu removed direct VoiceOver actions")
    }
}
