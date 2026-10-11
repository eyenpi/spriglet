import AppKit
import CompanionCore

/// Runtime-owned user transaction. Every action arrives through runtime.perform.
@MainActor final class IntakeSession {
    let card = IntakeCardHost()
    let drop = IntakeDropHost()
    private let analyzer: LocalIntakeAnalyzer
    private let services: LocalIntakeActionContext
    private let actions: [any IntakeAction] = [CreateReminder(), CopyText(), Pocket()]
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var undoExpiry: Task<Void, Never>?
    private var generation = UUID()
    private var analyzing = false
    private var current: IntakeCardState?
    private var undo: IntakeUndo?
    private var context: DisplayContext?
    private var anchor = Point.zero
    private var visible = false
    private(set) var feedback: IntakeFeedback?
    private(set) var feedbackAge = 0.0
    var onChanged: (() -> Void)?
    var onPocketChanged: (() -> Void)?
    var isPerforming: Bool { current?.isPerforming == true }
    var pocketItems: [PocketEntry] { services.store.items }
    init(store: IntakeStore = IntakeStore(), reminders: any ReminderWriting = EventKitReminderWriter(),
         analyzer: LocalIntakeAnalyzer = LocalIntakeAnalyzer()) {
        self.analyzer = analyzer
        services = LocalIntakeActionContext(reminders: reminders, store: store)
    }
    func hover(_ value: Bool) {
        guard current == nil, undo == nil else { return }
        setFeedback(value ? .ready : nil)
    }
    func update(context: DisplayContext, snapshot: CompanionSnapshot, visible: Bool, enabled: Bool, playing: Bool) {
        self.context = context; anchor = Point(x: snapshot.hitBounds.midX, y: snapshot.hitBounds.maxY)
        self.visible = visible
        drop.update(context: context, snapshot: snapshot, enabled: enabled && !isPerforming, playing: playing)
        card.reposition(context: context, anchor: anchor); card.setVisible(visible && (current != nil && !analyzing || current == nil && undo != nil))
    }
    func advance(_ elapsed: Double) {
        feedbackAge += elapsed
        if feedback == .caught && feedbackAge >= 0.3 { setFeedback(.analyzing) }
        if feedback == .happy && feedbackAge >= 0.8 { setFeedback(nil) }
    }
    func perform(_ command: IntakeCommand) {
        switch command {
        case .receive(let item, _): receive(item)
        case .choose(let id, let analysis): choose(id, analysis: analysis)
        case .dismiss: dismiss()
        case .reopen(let id):
            guard !isPerforming, let entry = pocketItems.first(where: { $0.id == id }) else { return }
            dismiss(); current = IntakeCardState(item: entry.item, analysis: entry.analysis)
            showCard(); setFeedback(entry.analysis.confidence == .low ? .uncertain : nil)
        case .undo: undoLast()
        }
    }
    private func receive(_ item: IntakeItem) {
        guard !isPerforming else { return }
        if current != nil { dismiss(); guard current == nil else { return } }
        analyzing = true; card.close(); current = IntakeCardState(item: item, analysis: IntakeAnalysis(explanation: "Reading on this Mac…"))
        let token = UUID(); generation = token; setFeedback(.caught)
        task = Task { [weak self, analyzer] in
            do {
                let enriched = try await analyzer.enrich(item, onProgress: { [weak self] progress in
                    await self?.enrichmentProgress(progress, token: token)
                })
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.current?.item = enriched
                let result = try await analyzer.analyze(enriched)
                try Task.checkCancellation()
                self.finish(result, token: token)
            } catch is CancellationError { }
            catch {
                self?.finish(IntakeAnalysis(explanation: "Couldn’t read this item. Keep it in Pocket or write a reminder with More…."), token: token)
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.generation == token, let item = self.current?.item else { return }
            self.task?.cancel()
            var fallback = LocalIntakeAnalyzer.detect(item)
            fallback.explanation = "Analysis timed out. " + fallback.explanation
            self.finish(fallback, token: token)
        }
    }
    private func enrichmentProgress(_ item: IntakeItem, token: UUID) {
        guard generation == token else { return }
        current?.item = item
    }
    private func finish(_ result: IntakeAnalysis, token: UUID) {
        var analysis = result
        if let list = services.reminders.defaultList {
            for index in analysis.reminders.indices where analysis.reminders[index].listID == nil {
                analysis.reminders[index].listID = list.id; analysis.reminders[index].listName = list.title
                analysis.reminders[index].uncertain.remove(.list)
            }
        }
        if analysis.confidence == .high && analysis.reminders.contains(where: { !$0.uncertain.isEmpty }) { analysis.confidence = .medium }
        guard generation == token, let item = current?.item else { return }
        analyzing = false; generation = UUID(); task = nil; deadline?.cancel(); deadline = nil
        current = IntakeCardState(item: item, analysis: analysis)
        setFeedback(analysis.confidence == .low ? .uncertain : nil); showCard()
    }
    private func showCard() {
        guard let current, let context else { return }
        let ranking = IntakeRanking.rank(actions, item: current.item, analysis: current.analysis, learning: services.store.learning)
        card.present(current, actions: ranking, allActions: actions, lists: services.reminders.lists, context: context, anchor: anchor)
        card.setVisible(visible)
    }
    private func choose(_ id: String, analysis: IntakeAnalysis) {
        guard var state = current, !state.isPerforming, let action = actions.first(where: { $0.id == id }), action.accepts(state.item) else { return }
        task?.cancel(); deadline?.cancel(); generation = UUID()
        analyzing = false
        state.analysis = analysis; state.isPerforming = true; state.error = nil; current = state
        let token = generation; showCard()
        task = Task { [weak self, services] in
            do {
                let result = try await action.perform(state.item, analysis: analysis, context: services)
                guard let self, self.generation == token else { return }
                self.task = nil; self.services.store.record(id, source: state.item.source)
                if id != "pocket" { self.services.store.remove(state.item.id) }
                self.current = nil; self.card.close(); self.onPocketChanged?()
                switch result {
                case .reminders(let ids):
                    self.clearUndo()
                    self.undo = IntakeUndo(reminderIDs: ids, now: Date())
                    if let context = self.context { self.card.showUndo(count: ids.count, context: context, anchor: self.anchor); self.card.setVisible(self.visible) }
                    self.setFeedback(.happy)
                    self.undoExpiry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        self?.clearUndo()
                    }
                case .copied, .pocketed:
                    self.setFeedback(nil)
                    if let undo = self.undo, undo.isAvailable(at: Date()), let context = self.context {
                        self.card.showUndo(count: undo.reminderIDs.count, context: context, anchor: self.anchor)
                        self.card.setVisible(self.visible)
                    }
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.task = nil; self.current?.isPerforming = false; self.current?.error = error.localizedDescription
                self.current?.editing = true; self.showCard()
            }
        }
    }
    private func dismiss() {
        guard var state = current, !state.isPerforming else { return }
        if card.isVisible, let analysis = card.editedAnalysis { state.analysis = analysis; current = state }
        do {
            try services.store.save(state.item, analysis: state.analysis)
            task?.cancel(); task = nil; deadline?.cancel(); deadline = nil; generation = UUID()
            analyzing = false; current = nil; card.close(); setFeedback(nil); onPocketChanged?()
        } catch { current?.error = error.localizedDescription; showCard() }
    }
    private func undoLast() {
        guard let undo, undo.isAvailable(at: Date()) else { clearUndo(); return }
        do { try services.reminders.delete(undo.reminderIDs); clearUndo(); setFeedback(nil) }
        catch {
            if let context { card.showUndo(count: undo.reminderIDs.count, context: context, anchor: anchor, error: error.localizedDescription) }
        }
    }
    private func clearUndo() { undo = nil; undoExpiry?.cancel(); undoExpiry = nil; if current == nil { card.close() } }
    private func setFeedback(_ value: IntakeFeedback?) {
        guard value != feedback else { return }; feedback = value; feedbackAge = 0; onChanged?()
    }
    func stop() {
        task?.cancel(); deadline?.cancel(); undoExpiry?.cancel(); generation = UUID()
        task = nil; deadline = nil; undoExpiry = nil; analyzing = false; current = nil; undo = nil; feedback = nil
        card.stop(); drop.close()
    }
}
