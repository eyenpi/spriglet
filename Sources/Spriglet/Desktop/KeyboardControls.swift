import AppKit

/// Keep the app's small control windows usable with Tab even when macOS's
/// optional keyboard navigation setting is off. Native controls handle keys.
@MainActor class KeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override func keyDown(with event: NSEvent) {
        if !moveKeyboardFocus(event, from: self) { super.keyDown(with: event) }
    }
}

@MainActor final class KeyboardPopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override func keyDown(with event: NSEvent) {
        if !moveKeyboardFocus(event, from: self) { super.keyDown(with: event) }
    }
}

@MainActor private func moveKeyboardFocus(_ event: NSEvent, from view: NSView) -> Bool {
    guard event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
          let window = view.window else { return false }
    if event.modifierFlags.contains(.shift) { window.selectPreviousKeyView(view) }
    else { window.selectNextKeyView(view) }
    return true
}
