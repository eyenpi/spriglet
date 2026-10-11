import AppKit
import CompanionCore

@MainActor private final class IntakeStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor private final class IntakeCardPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onUndo: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { onUndo?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class IntakeCardHost: NSObject {
    private struct Fields {
        let draft: ReminderDraft
        let selected: NSButton
        let title: NSTextField
        let hasDate: NSButton
        let date: NSDatePicker
        let zone: NSPopUpButton
        let list: NSPopUpButton
    }
    var onCommand: ((IntakeCommand) -> Void)?
    private(set) var panel: NSPanel?
    private var state: IntakeCardState?
    private var rows: [Fields] = []
    private var actions: [any IntakeAction] = []
    private var lists: [ReminderList] = []
    private var context: DisplayContext?
    private var anchor = Point.zero
    private var localClicks: Any?
    private var moreStack: NSStackView?
    private var search: NSSearchField?
    private var actionButtons: [NSButton] = []
    var editedAnalysis: IntakeAnalysis? { collect() }
    var isVisible: Bool { panel?.isVisible == true }

    func present(_ state: IntakeCardState, actions: [any IntakeAction], allActions: [any IntakeAction],
                 lists: [ReminderList], context: DisplayContext, anchor: Point) {
        self.state = state; self.actions = allActions; self.lists = lists; self.context = context; self.anchor = anchor
        rows = []; actionButtons = []
        let stack = makeStack()
        let preview = actions.first?.preview(state.item, analysis: state.analysis)
        let heading = NSTextField(labelWithString: preview?.title ?? "Keep this item")
        heading.font = .systemFont(ofSize: 18, weight: .semibold); stack.addArrangedSubview(heading)
        let description = NSTextField(wrappingLabelWithString: state.error ?? state.analysis.explanation)
        description.font = .systemFont(ofSize: 12); description.textColor = state.error == nil ? .secondaryLabelColor : .systemRed
        stack.addArrangedSubview(description)
        if state.analysis.confidence != .low {
            for draft in preview?.reminders ?? [] { add(draft, editing: state.editing && !state.isPerforming, to: stack) }
        }
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        if let top = actions.first {
            let button = makeButton(top.id == "reminder" ? "Add" : top.title, selector: #selector(choose(_:)), id: top.id)
            button.isEnabled = !state.isPerforming
            if state.focusesAdd { button.keyEquivalent = "\r" }
            controls.addArrangedSubview(button)
        }
        if state.analysis.confidence != .low {
            let edit = makeButton("Edit", selector: #selector(edit(_:))); edit.isEnabled = !state.isPerforming
            controls.addArrangedSubview(edit)
        }
        let more = makeButton("More…", selector: #selector(showMore(_:))); more.isEnabled = !state.isPerforming
        controls.addArrangedSubview(more); stack.addArrangedSubview(controls)
        let alternatives = NSStackView(); alternatives.orientation = .horizontal; alternatives.spacing = 8
        for action in actions.dropFirst().prefix(3) {
            let button = makeButton(action.title, selector: #selector(choose(_:)), id: action.id)
            button.isEnabled = !state.isPerforming; alternatives.addArrangedSubview(button)
        }
        if !alternatives.arrangedSubviews.isEmpty { stack.addArrangedSubview(alternatives) }
        let search = NSSearchField(); search.placeholderString = "Search actions"; search.target = self; search.action = #selector(searchActions(_:))
        search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("Search all intake actions")
        let moreStack = makeStack(); moreStack.addArrangedSubview(search); moreStack.isHidden = true
        stack.addArrangedSubview(moreStack); self.moreStack = moreStack; self.search = search
        install(stack, height: rows.isEmpty ? 160 : min(600, CGFloat(rows.count * 188 + 210)))
        if state.focusesAdd { panel?.makeFirstResponder(controls.arrangedSubviews.first) }
        else if state.editing { panel?.makeFirstResponder(rows.first?.title) }
        else { panel?.makeFirstResponder(controls.arrangedSubviews.first) }
    }
    private func makeStack() -> NSStackView {
        let stack = IntakeStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        return stack
    }
    private func makeButton(_ title: String, selector: Selector, id: String? = nil) -> KeyboardButton {
        let button = KeyboardButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded; button.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        button.setAccessibilityLabel(title); return button
    }
    private func add(_ draft: ReminderDraft, editing: Bool, to stack: NSStackView) {
        let selected = KeyboardButton(checkboxWithTitle: rows.isEmpty && state?.analysis.reminders.count == 1 ? "Reminder" : "Include this reminder", target: nil, action: nil)
        selected.setAccessibilityLabel("Include reminder: " + draft.title)
        selected.state = draft.selected ? .on : .off; selected.isEnabled = state?.isPerforming != true
        stack.addArrangedSubview(selected)
        let title = NSTextField(string: draft.title); title.isEditable = editing; title.isSelectable = true
        title.setAccessibilityLabel("Reminder title" + (draft.uncertain.contains(.title) ? ", needs review" : ""))
        title.widthAnchor.constraint(equalToConstant: 340).isActive = true
        if draft.uncertain.contains(.title) { title.backgroundColor = .systemYellow.withAlphaComponent(0.16) }
        stack.addArrangedSubview(title)
        let summary = NSTextField(wrappingLabelWithString: Self.dateLabel(draft))
        summary.font = .systemFont(ofSize: 12); summary.textColor = draft.uncertain.contains(.date) ? .systemOrange : .secondaryLabelColor
        summary.setAccessibilityLabel("Date and time" + (draft.uncertain.contains(.date) ? ", needs review" : ""))
        stack.addArrangedSubview(summary)
        let dateRow = NSStackView(); dateRow.orientation = .horizontal; dateRow.spacing = 8
        let hasDate = KeyboardButton(checkboxWithTitle: "Due", target: self, action: #selector(dateChanged(_:)))
        hasDate.state = draft.due == nil ? .off : .on; hasDate.isEnabled = editing
        let date = NSDatePicker(); date.datePickerStyle = .textFieldAndStepper; date.datePickerElements = [.yearMonthDay, .hourMinute]
        date.dateValue = draft.due ?? Date(); date.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        date.isEnabled = editing && draft.due != nil; date.setAccessibilityLabel("Due date and time")
        let zone = KeyboardPopUpButton()
        let zones = Array(Set([draft.timeZoneID, TimeZone.current.identifier, "UTC", "Europe/Berlin", "Europe/Rome", "America/New_York", "America/Los_Angeles", "Asia/Tokyo"])).sorted()
        zone.addItems(withTitles: zones); zone.selectItem(withTitle: draft.timeZoneID); zone.isEnabled = editing
        zone.target = self; zone.action = #selector(dateChanged(_:)); zone.setAccessibilityLabel("Time zone")
        dateRow.addArrangedSubview(hasDate); dateRow.addArrangedSubview(date); stack.addArrangedSubview(dateRow); stack.addArrangedSubview(zone)
        let list = KeyboardPopUpButton()
        list.addItem(withTitle: "Default Reminders list")
        for value in lists { list.addItem(withTitle: value.title); list.lastItem?.representedObject = value.id }
        if let id = draft.listID, let index = list.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { list.selectItem(at: index) }
        list.isEnabled = editing; list.setAccessibilityLabel("Reminders list" + (draft.uncertain.contains(.list) ? ", needs review" : ""))
        if draft.uncertain.contains(.list) {
            list.wantsLayer = true; list.layer?.borderColor = NSColor.systemOrange.cgColor
            list.layer?.borderWidth = 1; list.layer?.cornerRadius = 6
        }
        stack.addArrangedSubview(list)
        rows.append(Fields(draft: draft, selected: selected, title: title, hasDate: hasDate, date: date, zone: zone, list: list))
    }
    static func dateLabel(_ draft: ReminderDraft) -> String {
        guard let due = draft.due else { return "No date · \(draft.timeZoneID) · \(draft.listName)" }
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        return formatter.string(from: due) + " · " + draft.timeZoneID + " · " + draft.listName
    }
    private func dismissCard() {
        if let analysis = collect(), state?.isPerforming != true { onCommand?(.choose("pocket", analysis)) }
        else { onCommand?(.dismiss) }
    }
    private func collect() -> IntakeAnalysis? {
        guard var analysis = state?.analysis else { return nil }
        if !rows.isEmpty {
            analysis.reminders = rows.map { fields in
                var draft = fields.draft
                draft.title = fields.title.stringValue; draft.selected = fields.selected.state == .on
                draft.due = fields.hasDate.state == .on ? fields.date.dateValue : nil
                draft.timeZoneID = fields.zone.titleOfSelectedItem ?? TimeZone.current.identifier
                draft.listID = fields.list.selectedItem?.representedObject as? String
                draft.listName = fields.list.titleOfSelectedItem ?? "Default Reminders list"
                return draft
            }
        }
        return analysis
    }
    @objc private func choose(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let analysis = collect() else { return }
        if id == "reminder", analysis.confidence == .low { manualReminder(); return }
        onCommand?(.choose(id, analysis))
    }
    @objc private func edit(_ sender: NSButton) {
        guard var state, let analysis = collect(), let context else { return }
        state.analysis = analysis; state.editing = true
        let ranked = IntakeRanking.rank(actions, item: state.item, analysis: analysis, learning: IntakeLearning())
        present(state, actions: ranked, allActions: actions, lists: lists, context: context, anchor: anchor)
    }
    @objc private func dateChanged(_ sender: NSControl) {
        for row in rows {
            row.date.isEnabled = state?.editing == true && row.hasDate.state == .on
            row.date.timeZone = TimeZone(identifier: row.zone.titleOfSelectedItem ?? "") ?? .current
        }
    }
    private func manualReminder() {
        guard var state, let context else { return }
        state.analysis = IntakeAnalysis(reminders: [ReminderDraft(title: state.item.text.isEmpty ? state.item.name ?? "Reminder" : String(state.item.text.prefix(240)), uncertain: [.title, .date, .list])], confidence: .medium, explanation: "Write a reminder and check its fields before Add.")
        state.editing = true
        present(state, actions: ([CreateReminder(), CopyText(), Pocket()] as [any IntakeAction]).filter { $0.accepts(state.item) }, allActions: actions, lists: lists, context: context, anchor: anchor)
    }
    @objc private func showMore(_ sender: NSButton) { moreStack?.isHidden.toggle(); searchActions(nil); if moreStack?.isHidden == false { panel?.makeFirstResponder(search) } }
    @objc private func searchActions(_ sender: NSSearchField?) {
        guard let moreStack, let state else { return }
        for button in actionButtons { moreStack.removeArrangedSubview(button); button.removeFromSuperview() }
        actionButtons = []
        let query = search?.stringValue ?? ""
        for action in actions where action.accepts(state.item) && (query.isEmpty || action.title.localizedCaseInsensitiveContains(query)) {
            let button = makeButton(action.title, selector: #selector(choose(_:)), id: action.id)
            moreStack.addArrangedSubview(button); actionButtons.append(button)
        }
    }
    private func install(_ stack: NSStackView, height: CGFloat) {
        if panel == nil {
            let panel = IntakeCardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.onDismiss = { [weak self] in self?.dismissCard() }; panel.onUndo = { [weak self] in self?.onCommand?(.undo) }
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; panel.title = "Mallow intake"
            panel.isMovable = false; self.panel = panel
            localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, self.isVisible, event.window !== self.panel { self.dismissCard() }
                return event
            }
        }
        let material = NSVisualEffectView(); material.material = .popover; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 18; material.layer?.masksToBounds = true
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = stack; material.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalToConstant: 350)
        ])
        panel?.contentView = material
        position(height: height); panel?.makeKeyAndOrderFront(nil)
        panel?.recalculateKeyViewLoop()
    }
    func reposition(context: DisplayContext, anchor: Point) { self.context = context; self.anchor = anchor; if let panel { position(height: panel.frame.height) } }
    private func position(height: CGFloat) {
        guard let context else { return }
        let global = context.globalPoint(scene: anchor), frame = context.screen.visibleFrame
        let width: CGFloat = 390, height = min(height, frame.height - 20)
        let x = min(max(global.x - width / 2, frame.minX + 10), frame.maxX - width - 10)
        let y = max(frame.minY + 10, min(global.y - height - 12, frame.maxY - height - 10))
        panel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    func showUndo(count: Int, context: DisplayContext, anchor: Point, error: String? = nil) {
        self.context = context; self.anchor = anchor; state = nil
        let stack = makeStack(); stack.addArrangedSubview(NSTextField(wrappingLabelWithString: error ?? "Added \(count == 1 ? "reminder" : "\(count) reminders")"))
        let button = makeButton("Undo (⌘Z)", selector: #selector(undo(_:))); stack.addArrangedSubview(button)
        install(stack, height: 110); panel?.makeFirstResponder(button)
    }
    @objc private func undo(_ sender: NSButton) { onCommand?(.undo) }
    func setVisible(_ value: Bool) { if value { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) } }
    func close() { panel?.orderOut(nil); state = nil; rows = [] }
    func stop() { close(); if let localClicks { NSEvent.removeMonitor(localClicks) }; localClicks = nil; panel?.close(); panel = nil }
}
