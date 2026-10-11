import Foundation
import Testing
@testable import CompanionCore

private struct SampleAnalyzer: IntakeAnalyzing {
    let due: Date
    func analyze(_ item: IntakeItem) async throws -> IntakeAnalysis {
        switch item.text {
        case "Pay rent on October 15 at 9am":
            IntakeAnalysis(reminders: [ReminderDraft(title: "Pay rent", due: due, timeZoneID: "Europe/Berlin")], confidence: .high)
        case "Call Sam on October 15; send invoice on October 16":
            IntakeAnalysis(reminders: [ReminderDraft(title: "Call Sam", due: due), ReminderDraft(title: "Send invoice", due: due.addingTimeInterval(86400))], confidence: .medium)
        default: IntakeAnalysis()
        }
    }
}
@MainActor private final class ActionSpy: IntakeActionContext {
    var created: [ReminderDraft] = [], notes = "", copied = "", kept: IntakeItem?
    func createReminders(_ drafts: [ReminderDraft], notes: String) async throws -> [String] {
        created = drafts; self.notes = notes; return drafts.map { $0.id.uuidString }
    }
    func copyText(_ text: String) throws { copied = text }
    func pocket(_ item: IntakeItem, analysis: IntakeAnalysis) throws { kept = item }
}
struct IntakeTests {
    @Test func normalizesTextWithoutLosingLinesOrPayloads() {
        let item = IntakeItem(source: .text, text: " \r\nPay rent\r\nFriday\n ")
        #expect(item.text == "Pay rent\nFriday")
        #expect(IntakeItem(source: .text, text: String(repeating: "x", count: 20_000)).text.count == 16_000)
        let image = Data([1, 2, 3]), bookmark = Data([4, 5])
        let file = IntakeItem(source: .file, name: "note.png", image: image, bookmark: bookmark)
        #expect(file.image == image && file.bookmark == bookmark && file.label == "note.png")
        let url = URL(string: "https://example.com/task")!
        #expect(IntakeItem(source: .url, text: "Source", url: url).notes == "Source\nhttps://example.com/task")
    }
    @Test func mockExtractionDrivesConfidenceAndMultipleTasks() async throws {
        let due = Date(timeIntervalSince1970: 1_792_047_600), analyzer = SampleAnalyzer(due: due)
        let item = IntakeItem(source: .text, text: "Pay rent on October 15 at 9am")
        let high = try await analyzer.analyze(item)
        #expect(high.reminders.first?.title == "Pay rent")
        #expect(high.reminders.first?.due == due && high.reminders.first?.timeZoneID == "Europe/Berlin")
        #expect(IntakeCardState(item: item, analysis: high).focusesAdd)
        let multi = try await analyzer.analyze(IntakeItem(source: .text, text: "Call Sam on October 15; send invoice on October 16"))
        #expect(multi.reminders.map(\.title) == ["Call Sam", "Send invoice"])
        #expect(multi.reminders.last?.due == due.addingTimeInterval(86400))
        #expect(IntakeCardState(item: item, analysis: multi).editing)
        let low = try await analyzer.analyze(IntakeItem(source: .image))
        #expect(low.confidence == .low && !IntakeCardState(item: item, analysis: low).focusesAdd)
        #expect(IntakeAnalysis(confidence: .high).confidence == .low)
    }
    @Test func rankingHidesLowConfidenceAddAndLearnsPerSource() {
        let actions: [any IntakeAction] = [CreateReminder(), CopyText(), Pocket()]
        let item = IntakeItem(source: .text, text: "A poem"), analysis = IntakeAnalysis()
        var learning = IntakeLearning()
        #expect(IntakeRanking.rank(actions, item: item, analysis: analysis, learning: learning).map(\.id) == ["copy", "pocket"])
        for _ in 0..<5 { learning.record("pocket", source: .text) }
        #expect(IntakeRanking.rank(actions, item: item, analysis: analysis, learning: learning).first?.id == "pocket")
        #expect(IntakeRanking.rank(actions, item: IntakeItem(source: .url, text: "https://example.com"), analysis: analysis, learning: learning).first?.id == "copy")
        #expect(IntakeRanking.rank(actions, item: IntakeItem(source: .image), analysis: analysis, learning: learning).map(\.id) == ["pocket"])
        let high = IntakeAnalysis(reminders: [ReminderDraft(title: "Task")], confidence: .high)
        #expect(IntakeRanking.rank(actions, item: item, analysis: high, learning: learning).first?.id == "reminder")
    }
    @Test @MainActor func previewNeverCommitsAndAddOnlyCreatesSelectedTasks() async throws {
        let spy = ActionSpy(), item = IntakeItem(source: .url, text: "Pay rent", url: URL(string: "https://example.com"))
        var excluded = ReminderDraft(title: "Excluded"); excluded.selected = false
        let analysis = IntakeAnalysis(reminders: [ReminderDraft(title: "Pay rent"), excluded], confidence: .high)
        let action = CreateReminder()
        _ = action.preview(item, analysis: analysis)
        #expect(spy.created.isEmpty)
        _ = try await action.perform(item, analysis: analysis, context: spy)
        #expect(spy.created.map(\.title) == ["Pay rent"] && spy.notes == item.notes)
        _ = try await CopyText().perform(item, analysis: analysis, context: spy)
        #expect(spy.copied == item.notes)
        _ = try await Pocket().perform(item, analysis: analysis, context: spy)
        #expect(spy.kept == item)
    }
    @Test func expiryAndUndoHaveExactBoundaries() {
        let now = Date(timeIntervalSince1970: 1000)
        let entry = PocketEntry(item: IntakeItem(source: .text, text: "Task"), analysis: IntakeAnalysis(), savedAt: now)
        #expect(!entry.isExpired(at: now.addingTimeInterval(604799)))
        #expect(entry.isExpired(at: now.addingTimeInterval(604800)))
        let undo = IntakeUndo(reminderIDs: ["one", "two"], now: now)
        #expect(undo.isAvailable(at: now.addingTimeInterval(4.999)))
        #expect(!undo.isAvailable(at: now.addingTimeInterval(5)))
        #expect(!IntakeUndo(reminderIDs: [], now: now).isAvailable(at: now))
    }
    @Test func intakePresentationPreservesPlayAndReduceMotion() {
        let engine = CompanionEngine(scene: .preview)
        let frame = engine.snapshot
        let reduced = frame.presentingIntake(.analyzing, age: 1, reducedMotion: true, pocketCount: 2)
        #expect(reduced.feet == frame.feet && reduced.pose.height == frame.pose.height)
        #expect(reduced.phase == frame.phase && reduced.pocketCount == 2)
        let ready = frame.presentingIntake(.ready, age: 0, reducedMotion: false, pocketCount: 0)
        #expect(ready.pose.arm > frame.pose.arm && ready.homeGrip == 0)
        #expect(engine.snapshot.intakeFeedback == nil)
    }
}
