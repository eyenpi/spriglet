import AppKit
import EventKit
import CompanionCore

@MainActor protocol ReminderWriting: AnyObject {
    var lists: [ReminderList] { get }
    var defaultList: ReminderList? { get }
    func add(_ drafts: [ReminderDraft], notes: String) async throws -> [String]
    func delete(_ ids: [String]) throws
}
@MainActor final class EventKitReminderWriter: ReminderWriting {
    private let store = EKEventStore()
    var defaultList: ReminderList? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let calendar = store.defaultCalendarForNewReminders() else { return nil }
        return ReminderList(id: calendar.calendarIdentifier, title: calendar.title)
    }
    var lists: [ReminderList] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }
    func add(_ drafts: [ReminderDraft], notes: String) async throws -> [String] {
        guard !drafts.isEmpty, drafts.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw IntakeServiceError.message("Select at least one reminder with a title.")
        }
        // Nothing before Add requests access, reads reminders, or changes Apple Reminders.
        guard try await store.requestFullAccessToReminders() else {
            throw IntakeServiceError.message("Allow Reminders in System Settings > Privacy & Security > Reminders, then try Add again.")
        }
        var reminders: [EKReminder] = []
        do {
            for draft in drafts {
                let calendar: EKCalendar?
                if let id = draft.listID { calendar = store.calendar(withIdentifier: id) }
                else { calendar = store.defaultCalendarForNewReminders() }
                guard let calendar, calendar.allowsContentModifications else { throw IntakeServiceError.message("Choose an available Reminders list and try again.") }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar; reminder.title = draft.title; reminder.notes = notes
                if let due = draft.due {
                    var components = Calendar.current.dateComponents(in: TimeZone(identifier: draft.timeZoneID) ?? .current, from: due)
                    components.second = 0; components.nanosecond = nil
                    reminder.dueDateComponents = components; reminder.addAlarm(EKAlarm(absoluteDate: due))
                }
                try store.save(reminder, commit: false); reminders.append(reminder)
            }
            try store.commit()
            return reminders.map(\.calendarItemIdentifier)
        } catch { store.reset(); throw error }
    }
    func delete(_ ids: [String]) throws {
        do {
            for id in ids {
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { continue }
                try store.remove(reminder, commit: false)
            }
            try store.commit()
        } catch { store.reset(); throw error }
    }
}
nonisolated enum IntakeServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// Persistence is confined to the app container; expiry is checked on every read.
@MainActor final class IntakeStore {
    private let defaults: UserDefaults
    private let pocketFile: URL?
    private var entries: [PocketEntry]
    private(set) var learning: IntakeLearning
    private let now: () -> Date
    init(defaults: UserDefaults? = nil, directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        let preferences = defaults ?? .standard
        self.defaults = preferences; self.now = now
        let storage = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Spriglet/Intake", isDirectory: true)
        // Explicit preference injection keeps validation suites isolated. Production
        // image payloads belong in an atomic container file, not large preferences.
        pocketFile = defaults == nil || directory != nil ? storage?.appendingPathComponent("pocket.json") : nil
        let data = pocketFile.flatMap { try? Data(contentsOf: $0) } ?? (pocketFile == nil ? preferences.data(forKey: "mallow.intake.pocket.v1") : nil)
        entries = data.flatMap { try? JSONDecoder().decode([PocketEntry].self, from: $0) } ?? []
        learning = preferences.data(forKey: "mallow.intake.learning.v1").flatMap { try? JSONDecoder().decode(IntakeLearning.self, from: $0) } ?? IntakeLearning()
        prune()
    }
    var items: [PocketEntry] { prune(); return entries }
    func save(_ item: IntakeItem, analysis: IntakeAnalysis) throws {
        prune(); let savedAt = entries.first { $0.id == item.id }?.savedAt ?? now()
        entries.removeAll { $0.id == item.id }
        // Bounded container storage. Older retained items expire after seven days.
        guard entries.count < 100 else { throw IntakeServiceError.message("Pocket is full. Reopen an item and use Copy text or Add to make room.") }
        entries.append(PocketEntry(item: item, analysis: analysis, savedAt: savedAt)); try persist()
    }
    func remove(_ id: UUID) { entries.removeAll { $0.id == id }; try? persist() }
    func record(_ action: String, source: IntakeSource) {
        learning.record(action, source: source)
        if let data = try? JSONEncoder().encode(learning) { defaults.set(data, forKey: "mallow.intake.learning.v1") }
    }
    private func prune() {
        let count = entries.count; entries.removeAll { $0.isExpired(at: now()) }
        if count != entries.count { try? persist() }
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(entries)
        if let pocketFile {
            try FileManager.default.createDirectory(at: pocketFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: pocketFile, options: .atomic)
        } else { defaults.set(data, forKey: "mallow.intake.pocket.v1") }
    }
}
@MainActor final class LocalIntakeActionContext: IntakeActionContext {
    let reminders: any ReminderWriting
    let store: IntakeStore
    init(reminders: any ReminderWriting, store: IntakeStore) { self.reminders = reminders; self.store = store }
    func createReminders(_ drafts: [ReminderDraft], notes: String) async throws -> [String] { try await reminders.add(drafts, notes: notes) }
    func copyText(_ text: String) throws { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func pocket(_ item: IntakeItem, analysis: IntakeAnalysis) throws { try store.save(item, analysis: analysis) }
}
