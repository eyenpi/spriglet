import AppKit
import CompanionCore

/// Native acceptance entry point for a later owner-authorized fixture dispatch.
/// Building this helper does not run physical-display acceptance.
@MainActor enum MultiMonitorValidation {
    static func inspectConnectedDisplays() throws -> String {
        let measured = NSScreen.screens.map(DisplayContext.init(screen:))
        var logical: [DisplayContext] = []
        for context in measured {
            if let index = logical.firstIndex(where: { $0.logicalID == context.logicalID }) {
                if context.id == context.logicalID { logical[index] = context }
            } else { logical.append(context) }
        }
        guard logical.count >= 2 else { throw Failure.needsMultipleDisplays }
        for context in logical {
            let global = Point(x: context.frame.midX, y: context.frame.midY)
            let local = context.scenePoint(global: global)
            guard abs(local.x - context.frame.width / 2) < 0.001,
                  abs(local.y - context.frame.height / 2) < 0.001 else { throw Failure.coordinateMismatch }
        }
        return "connectedScreens=\(measured.count) logicalDisplays=\(logical.count)"
    }
    private enum Failure: Error { case needsMultipleDisplays, coordinateMismatch }
}
