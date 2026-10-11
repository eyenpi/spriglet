import AppKit
import QuartzCore
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
    private var selections: [(ReminderDraft, NSButton)] = []
    private var contentStack: NSStackView?
    private var closing = false
    private var unfolding = false
    private var presentation = UUID()
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
        rows = []; selections = []; actionButtons = []
        let stack = makeStack()
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 8
        let eyebrow = NSTextField(labelWithString: state.isPerforming ? "Keeping it…" : "A little reminder")
        eyebrow.font = .systemFont(ofSize: 11, weight: .medium); eyebrow.textColor = IntakeBubbleView.ink
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let dismiss = iconButton("Dismiss to Pocket", symbol: "xmark", selector: #selector(dismissButton(_:)))
        dismiss.isEnabled = !state.isPerforming
        header.addArrangedSubview(eyebrow); header.addArrangedSubview(spacer); header.addArrangedSubview(dismiss)
        header.widthAnchor.constraint(equalToConstant: 284).isActive = true
        stack.addArrangedSubview(header)
        if state.analysis.confidence != .low {
            for draft in state.analysis.reminders { add(draft, editing: state.editing, to: stack) }
            if state.analysis.confidence == .medium {
                let review = NSTextField(labelWithString: "Check the highlighted details")
                review.font = .systemFont(ofSize: 11); review.textColor = IntakeBubbleView.reviewInk
                review.toolTip = state.analysis.explanation; stack.addArrangedSubview(review)
            }
        } else {
            let title = summaryTitle(state.item.label, uncertain: false)
            stack.addArrangedSubview(title)
            let note = NSTextField(wrappingLabelWithString: "No clear date. Keep it for later.")
            note.font = .systemFont(ofSize: 12); note.textColor = IntakeBubbleView.ink
            note.toolTip = state.analysis.explanation; stack.addArrangedSubview(note)
        }
        if let error = state.error {
            let note = NSTextField(wrappingLabelWithString: error)
            note.font = .systemFont(ofSize: 12); note.textColor = .systemRed
            note.widthAnchor.constraint(equalToConstant: 284).isActive = true; stack.addArrangedSubview(note)
        }
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 6
        let top = actions.first
        let primary = makeButton(top?.id == "reminder" ? "Add" : top?.title ?? "Pocket", selector: #selector(choose(_:)), id: top?.id ?? "pocket")
        primary.primary = true; primary.isEnabled = !state.isPerforming
        if state.focusesAdd { primary.keyEquivalent = "\r" }
        controls.addArrangedSubview(primary)
        var editButton: NSButton?
        if state.analysis.confidence != .low {
            let edit = makeButton(state.editing ? "Done" : "Edit", selector: #selector(edit(_:)))
            edit.isEnabled = !state.isPerforming; controls.addArrangedSubview(edit); editButton = edit
        }
        let gap = NSView(); gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.addArrangedSubview(gap)
        for action in actions where action.id != top?.id {
            let button = iconButton(action.title, symbol: action.id == "copy" ? "doc.on.doc" : "tray", selector: #selector(choose(_:)), id: action.id)
            button.isEnabled = !state.isPerforming; controls.addArrangedSubview(button)
        }
        let more = iconButton("More actions", symbol: "ellipsis", selector: #selector(showMore(_:)))
        more.isEnabled = !state.isPerforming; controls.addArrangedSubview(more)
        controls.widthAnchor.constraint(equalToConstant: 284).isActive = true; stack.addArrangedSubview(controls)
        let search = NSSearchField(); search.placeholderString = "Search actions"; search.target = self; search.action = #selector(searchActions(_:))
        search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("Search all intake actions")
        search.widthAnchor.constraint(equalToConstant: 284).isActive = true
        let moreStack = makeStack(); moreStack.addArrangedSubview(search); moreStack.isHidden = true
        stack.addArrangedSubview(moreStack); self.moreStack = moreStack; self.search = search
        install(stack)
        if state.editing { panel?.makeFirstResponder(rows.first?.title) }
        else { panel?.makeFirstResponder(state.focusesAdd ? primary : editButton ?? primary) }
    }
    private func makeStack() -> NSStackView {
        let stack = IntakeStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        return stack
    }
    private func makeButton(_ title: String, selector: Selector, id: String? = nil) -> IntakeBubbleButton {
        let button = IntakeBubbleButton(title: title, target: self, action: selector)
        button.isBordered = false; button.font = .systemFont(ofSize: 12, weight: .medium)
        button.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        button.setAccessibilityLabel(title); button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func iconButton(_ title: String, symbol: String, selector: Selector, id: String? = nil) -> IntakeBubbleButton {
        let button = makeButton(title, selector: selector, id: id)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly; button.toolTip = title
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    private func summaryTitle(_ text: String, uncertain: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text.replacingOccurrences(of: "\n", with: " "))
        let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        label.font = font.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 17) } ?? font
        label.textColor = IntakeBubbleView.ink; label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 284).isActive = true
        label.toolTip = text; label.setAccessibilityLabel(text + (uncertain ? ", needs review" : ""))
        if uncertain { label.drawsBackground = true; label.backgroundColor = IntakeBubbleView.reviewFill }
        return label
    }
    private func add(_ draft: ReminderDraft, editing: Bool, to stack: NSStackView) {
        let selected = KeyboardButton(checkboxWithTitle: "Include this reminder", target: nil, action: nil)
        selected.setAccessibilityLabel("Include reminder: " + draft.title)
        selected.state = draft.selected ? .on : .off; selected.isEnabled = state?.isPerforming != true
        if state?.analysis.reminders.count != 1 { stack.addArrangedSubview(selected) }
        if !editing {
            stack.addArrangedSubview(summaryTitle(draft.title, uncertain: draft.uncertain.contains(.title)))
            let summary = NSTextField(wrappingLabelWithString: Self.dateLabel(draft))
            summary.font = .systemFont(ofSize: 12); summary.textColor = draft.uncertain.contains(.date) ? IntakeBubbleView.reviewInk : IntakeBubbleView.ink
            summary.widthAnchor.constraint(equalToConstant: 284).isActive = true
            summary.setAccessibilityLabel(Self.dateLabel(draft) + (draft.uncertain.contains(.date) ? ", needs review" : ""))
            summary.toolTip = "\(draft.timeZoneID) · \(draft.listName)"; stack.addArrangedSubview(summary)
            if draft.uncertain.contains(.list) {
                let listNote = NSTextField(labelWithString: "Check Reminders list in Edit")
                listNote.font = .systemFont(ofSize: 11); listNote.textColor = IntakeBubbleView.reviewInk
                stack.addArrangedSubview(listNote)
            }
            selections.append((draft, selected)); return
        }
        let title = NSTextField(string: draft.title); title.isEditable = editing && state?.isPerforming != true; title.isSelectable = true
        title.setAccessibilityLabel("Reminder title" + (draft.uncertain.contains(.title) ? ", needs review" : ""))
        title.widthAnchor.constraint(equalToConstant: 284).isActive = true
        if draft.uncertain.contains(.title) { title.backgroundColor = IntakeBubbleView.reviewFill }
        stack.addArrangedSubview(title)
        let summary = NSTextField(wrappingLabelWithString: Self.dateLabel(draft))
        summary.font = .systemFont(ofSize: 12); summary.textColor = draft.uncertain.contains(.date) ? IntakeBubbleView.reviewInk : IntakeBubbleView.ink
        summary.setAccessibilityLabel("Date and time" + (draft.uncertain.contains(.date) ? ", needs review" : ""))
        stack.addArrangedSubview(summary)
        let dateRow = NSStackView(); dateRow.orientation = .horizontal; dateRow.spacing = 8
        let hasDate = KeyboardButton(checkboxWithTitle: "Due", target: self, action: #selector(dateChanged(_:)))
        hasDate.state = draft.due == nil ? .off : .on; hasDate.isEnabled = editing && state?.isPerforming != true
        let date = NSDatePicker(); date.datePickerStyle = .textFieldAndStepper; date.datePickerElements = [.yearMonthDay, .hourMinute]
        date.dateValue = draft.due ?? Date(); date.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        date.isEnabled = editing && state?.isPerforming != true && draft.due != nil; date.setAccessibilityLabel("Due date and time")
        let zone = KeyboardPopUpButton()
        let zones = Array(Set([draft.timeZoneID, TimeZone.current.identifier, "UTC", "Europe/Berlin", "Europe/Rome", "America/New_York", "America/Los_Angeles", "Asia/Tokyo"])).sorted()
        zone.addItems(withTitles: zones); zone.selectItem(withTitle: draft.timeZoneID); zone.isEnabled = editing && state?.isPerforming != true
        zone.target = self; zone.action = #selector(dateChanged(_:)); zone.setAccessibilityLabel("Time zone")
        dateRow.addArrangedSubview(hasDate); dateRow.addArrangedSubview(date); stack.addArrangedSubview(dateRow); zone.widthAnchor.constraint(equalToConstant: 284).isActive = true; stack.addArrangedSubview(zone)
        let list = KeyboardPopUpButton()
        list.addItem(withTitle: "Default Reminders list")
        for value in lists { list.addItem(withTitle: value.title); list.lastItem?.representedObject = value.id }
        if let id = draft.listID, let index = list.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { list.selectItem(at: index) }
        list.isEnabled = editing && state?.isPerforming != true; list.setAccessibilityLabel("Reminders list" + (draft.uncertain.contains(.list) ? ", needs review" : ""))
        if draft.uncertain.contains(.list) {
            list.wantsLayer = true; list.layer?.borderColor = NSColor.systemOrange.cgColor
            list.layer?.borderWidth = 1; list.layer?.cornerRadius = 6
        }
        list.widthAnchor.constraint(equalToConstant: 284).isActive = true
        stack.addArrangedSubview(list)
        rows.append(Fields(draft: draft, selected: selected, title: title, hasDate: hasDate, date: date, zone: zone, list: list))
    }
    static func dateLabel(_ draft: ReminderDraft) -> String {
        guard let due = draft.due else { return "No date" }
        let formatter = DateFormatter(); formatter.dateStyle = .long; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        return formatter.string(from: due)
    }
    private func dismissCard() {
        if let analysis = collect(), state?.isPerforming != true { onCommand?(.choose("pocket", analysis)) }
        else { onCommand?(.dismiss) }
    }
    private func collect() -> IntakeAnalysis? {
        guard var analysis = state?.analysis else { return nil }
        if !selections.isEmpty {
            analysis.reminders = selections.map { original, button in
                var draft = original; draft.selected = button.state == .on; return draft
            }
        }
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
    @objc private func dismissButton(_ sender: NSButton) { dismissCard() }
    @objc private func edit(_ sender: NSButton) {
        guard var state, let analysis = collect(), let context else { return }
        state.analysis = analysis; state.editing.toggle()
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
    @objc private func showMore(_ sender: NSButton) { moreStack?.isHidden.toggle(); searchActions(nil); resize(); if moreStack?.isHidden == false { panel?.makeFirstResponder(search) }; panel?.recalculateKeyViewLoop() }
    @objc private func searchActions(_ sender: NSSearchField?) {
        guard let moreStack, let state else { return }
        for button in actionButtons { moreStack.removeArrangedSubview(button); button.removeFromSuperview() }
        actionButtons = []
        let query = search?.stringValue ?? ""
        for action in actions where action.accepts(state.item) && (query.isEmpty || action.title.localizedCaseInsensitiveContains(query)) {
            let button = makeButton(action.title, selector: #selector(choose(_:)), id: action.id)
            moreStack.addArrangedSubview(button); actionButtons.append(button)
        }
        resize()
    }
    private func install(_ stack: NSStackView) {
        let wasVisible = isVisible
        let previousFrame = panel?.frame
        closing = false; presentation = UUID()
        contentStack = stack
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
        let paper = IntakeBubbleView()
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = stack; paper.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: paper.topAnchor, constant: 28),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalToConstant: 284)
        ])
        panel?.contentView = paper
        let height = stack.fittingSize.height + 46
        position(height: height)
        guard let panel else { return }
        let target = panel.frame
        if !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(NSRect(x: target.minX + 16, y: target.maxY - 24, width: target.width - 32, height: 24), display: false)
            panel.alphaValue = 0
        } else if wasVisible, let previousFrame, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(previousFrame, display: false)
        }
        unfolding = true
        let token = presentation
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true); panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation == token else { return }
                self.unfolding = false
            }
        }
        panel.recalculateKeyViewLoop()
    }
    private func resize() {
        guard let contentStack else { return }
        position(height: contentStack.fittingSize.height + 46)
    }
    func reposition(context: DisplayContext, anchor: Point) { self.context = context; self.anchor = anchor; if let panel, !closing, !unfolding { position(height: panel.frame.height) } }
    private func position(height: CGFloat) {
        guard let context else { return }
        let global = context.globalPoint(scene: anchor), frame = context.screen.visibleFrame
        let width: CGFloat = 320, height = min(height, min(480, frame.height - 20))
        let x = min(max(global.x - width / 2, frame.minX + 10), frame.maxX - width - 10)
        let y = max(frame.minY + 10, min(global.y - height - 2, frame.maxY - height - 10))
        let rect = NSRect(x: x, y: y, width: width, height: height)
        if panel?.frame != rect { panel?.setFrame(rect, display: true) }
        (panel?.contentView as? IntakeBubbleView)?.tailX = global.x - x
    }
    func showUndo(count: Int, context: DisplayContext, anchor: Point, error: String? = nil) {
        self.context = context; self.anchor = anchor; state = nil
        let stack = makeStack(); stack.addArrangedSubview(NSTextField(wrappingLabelWithString: error ?? "Added \(count == 1 ? "reminder" : "\(count) reminders")"))
        let button = makeButton("Undo (⌘Z)", selector: #selector(undo(_:))); stack.addArrangedSubview(button)
        install(stack); panel?.makeFirstResponder(button)
    }
    @objc private func undo(_ sender: NSButton) { onCommand?(.undo) }
    func setVisible(_ value: Bool) { guard !closing else { return }; if value { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) } }
    func close() {
        state = nil; rows = []; selections = []
        guard let panel, panel.isVisible, !closing else { return }
        closing = true; unfolding = false; let token = UUID(); presentation = token
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(NSRect(x: frame.midX - 32, y: frame.maxY - 12, width: 64, height: 12), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation == token else { return }
                panel.orderOut(nil); self.closing = false
            }
        }
    }
    func stop() { close(); if let localClicks { NSEvent.removeMonitor(localClicks) }; localClicks = nil; panel?.close(); panel = nil }
}
