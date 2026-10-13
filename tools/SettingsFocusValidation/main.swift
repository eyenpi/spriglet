import AppKit
import ApplicationServices
import CryptoKit
struct Failure: Error, CustomStringConvertible { let description: String }
func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
func string(_ element: AXUIElement, _ key: String) -> String { value(element, key) as? String ?? "" }
func element(_ root: AXUIElement, _ key: String) -> AXUIElement? {
    guard let result = value(root, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}
func children(_ root: AXUIElement) -> [AXUIElement] { value(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func find(_ root: AXUIElement, depth: Int = 0, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
    if matches(root) { return root }
    guard depth < 8 else { return nil }
    for child in children(root) { if let result = find(child, depth: depth + 1, where: matches) { return result } }
    return nil
}
func wait(_ message: String, timeout: Double = 3, until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard condition() else { throw Failure(description: message) }
}
func require(_ success: Bool, _ message: String) throws { if !success { throw Failure(description: message) } }
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let modifier: CGKeyCode? = flags.contains(.maskCommand) ? 55 : flags.contains(.maskShift) ? 56 : nil
    func postModifier(_ down: Bool) {
        guard let modifier else { return }
        let event = CGEvent(keyboardEventSource: source, virtualKey: modifier, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? flags : []
        event.setIntegerValueField(.eventSourceUserData, value: 4848)
        event.post(tap: .cghidEventTap)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    postModifier(true)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        if !flags.contains(.maskCommand) {
            var chars = Array(([48: "\t", 49: " ", 53: "\u{1b}"][Int(code)] ?? "").utf16)
            chars.withUnsafeMutableBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        }
        event.setIntegerValueField(.eventSourceUserData, value: 4848)
        event.flags = flags
        event.post(tap: .cghidEventTap)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    postModifier(false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}
func click(_ target: AXUIElement) throws {
    guard let p = value(target, kAXPositionAttribute), let s = value(target, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else {
        throw Failure(description: "Target has no accessible screen rectangle")
    }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    try require(size.width > 0 && size.height > 0, "Target has an empty screen rectangle")
    try clickAt(CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2))
}
func clickAt(_ center: CGPoint) throws {
    for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 4848)
        event.post(tap: .cghidEventTap)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }
}
// For desktop thumbnails, AX may retain full-window geometry while WindowServer
// renders a thumbnail. Click the visible representation of this empty probe.
func clickProbe(_ process: pid_t, title: String) throws {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(process)
        && ($0[kCGWindowName as String] as? String) == title
        && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    try require(matches.count == 1, "Expected one visible disposable TextEdit probe")
    guard let bounds = matches[0][kCGWindowBounds as String] as? [String: Double],
          let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
          width > 0, height > 0 else { throw Failure(description: "Probe lacks visible bounds") }
    try clickAt(CGPoint(x: x + width / 2, y: y + height / 2))
}
func frontOrdinaryWindowOwner() -> pid_t? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.first {
        ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }?[kCGWindowOwnerPID as String] as? pid_t
}
func pid(_ element: AXUIElement?) -> pid_t {
    guard let element else { return -1 }
    var result: pid_t = -1; AXUIElementGetPid(element, &result); return result
}
let system = AXUIElementCreateSystemWide()
guard CommandLine.arguments.count == 3 else {
    print("Usage: settings-focus-validation <Daily-UseFixture.app> <result.json>")
    exit(EXIT_FAILURE)
}
let expectedFixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let infoData = try Data(contentsOf: expectedFixture.appendingPathComponent("Contents/Info.plist"))
let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
let fixtureID = info?["CFBundleIdentifier"] as? String ?? ""
guard fixtureID.hasPrefix("dev.spriglet.lifecycle-validation.") && fixtureID.hasSuffix(".daily-use") else {
    print("Expected a daily-use validation fixture")
    exit(EXIT_FAILURE)
}
var checkpoints: [[String: Any]] = []
var settingsWindowIDs: [Int] = []
var deliveredEvents: [[String: Int64]] = []
var outsideInputEvents: [[String: Int64]] = []
let observedTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
let eventMask = observedTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
let eventTap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: eventMask, callback: { _, type, event, _ in
    if event.getIntegerValueField(.eventSourceUserData) == 4848 {
        deliveredEvents.append(["type": Int64(type.rawValue), "keyCode": event.getIntegerValueField(.keyboardEventKeycode), "targetPID": event.getIntegerValueField(.eventTargetUnixProcessID)])
    } else {
        outsideInputEvents.append(["type": Int64(type.rawValue), "sourcePID": event.getIntegerValueField(.eventSourceUnixProcessID), "targetPID": event.getIntegerValueField(.eventTargetUnixProcessID)])
    }
    return Unmanaged.passUnretained(event)
}, userInfo: nil)
if let eventTap { CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), .commonModes) }
@MainActor func snapshot(_ label: String, fixture: NSRunningApplication) {
    let ax = AXUIElementCreateApplication(fixture.processIdentifier)
    let focus = element(system, kAXFocusedUIElementAttribute)
    let window = element(ax, kAXFocusedWindowAttribute)
    var row: [String: Any] = ["checkpoint": label, "time": ISO8601DateFormatter().string(from: Date()),
                            "fixturePID": fixture.processIdentifier, "fixtureActive": fixture.isActive,
                            "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                            "globalFocusedElementPID": pid(focus),
                            "globalFocusedApplicationPID": pid(element(system, kAXFocusedApplicationAttribute)),
                            "fixtureFocusedWindow": window.map { string($0, kAXTitleAttribute) } ?? "",
                            "globalFocusedRole": focus.map { string($0, kAXRoleAttribute) } ?? "",
                            "globalFocusedDescription": pid(focus) == fixture.processIdentifier ? focus.map { string($0, kAXDescriptionAttribute) } ?? "" : ""]
    if let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
       let settings = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(fixture.processIdentifier) && ($0[kCGWindowName as String] as? String) == "Spriglet Settings" }),
       let number = settings[kCGWindowNumber as String] as? Int {
        row["settingsWindowNumber"] = number
        settingsWindowIDs.append(number)
    }
    checkpoints.append(row)
    print(String(data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
}
var result: [String: Any] = [ "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "displayCount": NSScreen.screens.count,
                           "input": "Desktop-wide CGEvents posted to cghidEventTap, no postToPid and no direct window.sendEvent", "passed": false]
do {
    try require(AXIsProcessTrusted(), "Observer lacks Accessibility permission")
    let fixtures = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID)
    try require(fixtures.count == 1, "Expected exactly one running fixture with this identifier")
    guard let fixture = fixtures.first,
          let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
        throw Failure(description: "Fixture or TextEdit is not running")
    }
    try require(eventTap != nil, "Cannot observe desktop event delivery; check input permissions")
    // Launch Services may report another registered copy's bundle/executable
    // URL when fixtures share an identifier. Read the actual process image.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let pathLength = path.withUnsafeMutableBytes { proc_pidpath(fixture.processIdentifier, $0.baseAddress, UInt32($0.count)) }
    try require(pathLength > 0, "Cannot identify running fixture executable")
    let executable = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
    result["executablePath"] = executable.path
    result["expectedExecutablePath"] = expectedFixture.appendingPathComponent("Contents/MacOS/lifecycle-validation").path
    try require(executable.path == expectedFixture.appendingPathComponent("Contents/MacOS/lifecycle-validation").path,
                "Running fixture executable differs from requested build")
    result["fixturePath"] = expectedFixture.path
    result["executableSHA256"] = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
    let ax = AXUIElementCreateApplication(fixture.processIdentifier)
    let textAX = AXUIElementCreateApplication(textEdit.processIdentifier)
    guard let blank = (value(textAX, kAXWindowsAttribute) as? [AXUIElement] ?? []).first(where: { string($0, kAXTitleAttribute).hasPrefix("Untitled") }) else { throw Failure(description: "No disposable blank TextEdit window") }
    guard let text = find(blank, where: { string($0, kAXRoleAttribute) == kAXTextAreaRole }) else { throw Failure(description: "Blank probe has no text area") }
    try require(string(text, kAXValueAttribute).isEmpty, "TextEdit probe is not empty; refusing to interact")
    AXUIElementPerformAction(blank, kAXRaiseAction as CFString)
    try clickProbe(textEdit.processIdentifier, title: string(blank, kAXTitleAttribute))
    try wait("TextEdit did not become active") { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEdit.processIdentifier }
    try require(element(textAX, kAXFocusedWindowAttribute).map { CFEqual($0, blank) } == true,
                "TextEdit did not focus the empty disposable probe")
    let probe = blank
    try wait("TextEdit probe was not focused on the physical desktop") { pid(element(system, kAXFocusedUIElementAttribute)) == textEdit.processIdentifier }
    try require(outsideInputEvents.isEmpty, "Outside input interrupted probe setup")
    for cycle in 1...8 {
        try require(outsideInputEvents.isEmpty, "Outside input interrupted the controlled sequence")
        if cycle > 1 {
            AXUIElementPerformAction(probe, kAXRaiseAction as CFString)
            try clickProbe(textEdit.processIdentifier, title: string(probe, kAXTitleAttribute))
            try wait("TextEdit baseline was not active before reopen") { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEdit.processIdentifier }
        }
        snapshot("cycle \(cycle): inactive fixture baseline", fixture: fixture)
        try require(!fixture.isActive, "Fixture was already active before selecting Settings")
        guard let extras = element(ax, kAXExtrasMenuBarAttribute),
              let leaf = find(extras, where: { string($0, kAXDescriptionAttribute) == "Spriglet controls" }) else {
            throw Failure(description: "Fixture leaf menu is unavailable")
        }
        try click(leaf)
        var settingsItem: AXUIElement?
        try wait("Native leaf menu did not expose Settings") {
            settingsItem = find(extras, where: { string($0, kAXTitleAttribute) == "Settings…" })
            guard let settingsItem, let raw = value(settingsItem, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            var size = CGSize.zero
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
            return size.width > 0 && size.height > 0
        }
        try click(settingsItem!)
        try wait("Menu-opened Settings did not acquire global application and keyboard focus") {
            fixture.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
            && frontOrdinaryWindowOwner() == fixture.processIdentifier
            && pid(element(system, kAXFocusedUIElementAttribute)) == fixture.processIdentifier
            && element(ax, kAXFocusedWindowAttribute).map { string($0, kAXTitleAttribute) == "Spriglet Settings" } == true
        }
        snapshot("cycle \(cycle): Settings opened from leaf; no Settings click", fixture: fixture)
        let initial = element(system, kAXFocusedUIElementAttribute)!
        try require(outsideInputEvents.isEmpty, "Outside input interrupted Settings activation")
        try require(string(initial, kAXDescriptionAttribute) == "Character size", "Initial keyboard focus was not Character size")
        key(48)
        try wait("Global Tab did not move to Movement intensity") { element(system, kAXFocusedUIElementAttribute).map { string($0, kAXDescriptionAttribute) == "Movement intensity" } ?? false }
        snapshot("cycle \(cycle): global Tab", fixture: fixture)
        key(48, .maskShift)
        try wait("Global Shift-Tab did not return to Character size") { element(system, kAXFocusedUIElementAttribute).map { string($0, kAXDescriptionAttribute) == "Character size" } ?? false }
        key(49)
        try wait("Global Space did not open the native size menu") {
            guard let item = find(ax, where: { string($0, kAXTitleAttribute) == "Medium" && string($0, kAXRoleAttribute) == kAXMenuItemRole }), let raw = value(item, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            var size = CGSize.zero; AXValueGetValue(raw as! AXValue, .cgSize, &size)
            return size.width > 0 && size.height > 0
        }
        snapshot("cycle \(cycle): global Space opened size popup", fixture: fixture)
        if cycle == 2, let number = settingsWindowIDs.last {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l\(number)", output.deletingPathExtension().appendingPathExtension("png").path]
            try capture.run(); capture.waitUntilExit()
            try require(capture.terminationStatus == 0, "Settings screenshot failed")
        }
        key(53)
        key(13, .maskCommand)
        try wait("Global Command-W did not close Settings") { !(value(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { string($0, kAXTitleAttribute) == "Spriglet Settings" } }
        snapshot("cycle \(cycle): global Command-W closed Settings", fixture: fixture)
    }
    try require(outsideInputEvents.isEmpty, "Outside input invalidated the controlled sequence")
    try require(Set(settingsWindowIDs).count == 1, "Reopen replaced the existing Settings window")
    result["settingsWindowNumber"] = settingsWindowIDs.first
    AXUIElementPerformAction(probe, kAXRaiseAction as CFString)
    try clickProbe(textEdit.processIdentifier, title: string(probe, kAXTitleAttribute))
    try wait("TextEdit did not regain focus for probe cleanup") { NSWorkspace.shared.frontmostApplication?.processIdentifier == textEdit.processIdentifier }
    // Keep the blank probe open for serial repetitions; no document edits.
    try require(outsideInputEvents.isEmpty, "Outside input interrupted probe cleanup")
    let keyEvents = deliveredEvents.filter { $0["type"] == Int64(CGEventType.keyDown.rawValue) || $0["type"] == Int64(CGEventType.keyUp.rawValue) }
    try require(keyEvents.count == 8 * 10 && keyEvents.allSatisfy { $0["targetPID"] == Int64(fixture.processIdentifier) }, "Keyboard events were not all routed to the fixture")
    result["passed"] = true
} catch {
    result["failure"] = String(describing: error)
    if let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).first { snapshot("failure state", fixture: fixture) }
}
result["checkpoints"] = checkpoints
result["deliveredGlobalKeyEvents"] = deliveredEvents
result["outsideInputEvents"] = outsideInputEvents
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output)
print(String(data: data, encoding: .utf8)!)
exit(result["passed"] as? Bool == true ? EXIT_SUCCESS : EXIT_FAILURE)
