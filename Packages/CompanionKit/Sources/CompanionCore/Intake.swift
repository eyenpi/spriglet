import Foundation

public enum IntakeSource: String, Codable, Sendable { case text, image, file, url }
public enum IntakeTrigger: String, Codable, Sendable { case drop, paste, hotkey, service, pocket }

/// A user-supplied value, never a reference to a window or platform service.
public struct IntakeItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let source: IntakeSource
    public var text: String
    public let name: String?
    public let url: URL?
    public let image: Data?
    public let bookmark: Data?
    public let receivedAt: Date
    public init(id: UUID = UUID(), source: IntakeSource, text: String = "", name: String? = nil,
                url: URL? = nil, image: Data? = nil, bookmark: Data? = nil, receivedAt: Date = Date()) {
        self.id = id; self.source = source
        self.text = String(text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(16_000))
        self.name = name; self.url = url; self.image = image; self.bookmark = bookmark; self.receivedAt = receivedAt
    }
    public var label: String { String((text.isEmpty ? name ?? url?.absoluteString ?? "Image" : text).prefix(80)) }
    public var notes: String { [text, url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}
public enum IntakeConfidence: String, Codable, Sendable { case high, medium, low }
public enum ReminderField: String, Codable, Hashable, Sendable { case title, date, list }
public struct ReminderDraft: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var due: Date?
    public var timeZoneID: String
    public var listID: String?
    public var listName: String
    public var uncertain: Set<ReminderField>
    /// Optional for compatibility with previously saved Pocket entries.
    public var usesDefaultTime: Bool?
    public var selected: Bool
    public init(id: UUID = UUID(), title: String, due: Date? = nil, timeZoneID: String = TimeZone.current.identifier,
                listID: String? = nil, listName: String = "Default Reminders list", uncertain: Set<ReminderField> = [], selected: Bool = true, usesDefaultTime: Bool = false) {
        self.id = id; self.title = title; self.due = due; self.timeZoneID = timeZoneID
        self.listID = listID; self.listName = listName; self.uncertain = uncertain; self.selected = selected; self.usesDefaultTime = usesDefaultTime
    }
}
public struct IntakeAnalysis: Codable, Equatable, Sendable {
    public var reminders: [ReminderDraft]
    public var confidence: IntakeConfidence
    public var explanation: String
    public init(reminders: [ReminderDraft] = [], confidence: IntakeConfidence = .low, explanation: String = "No clear reminder found.") {
        self.reminders = reminders; self.confidence = reminders.isEmpty ? .low : confidence; self.explanation = explanation
    }
}
public protocol IntakeAnalyzing: Sendable {
    func analyze(_ item: IntakeItem) async throws -> IntakeAnalysis
}
public struct IntakePreview: Sendable {
    public let title: String
    public let reminders: [ReminderDraft]
    public init(title: String, reminders: [ReminderDraft] = []) { self.title = title; self.reminders = reminders }
}
public struct ReminderList: Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
/// The platform boundary is implemented by Environment; actions hold no adapter.
@MainActor public protocol IntakeActionContext: AnyObject {
    func createReminders(_ drafts: [ReminderDraft], notes: String) async throws -> [String]
    func copyText(_ text: String) throws
    func pocket(_ item: IntakeItem, analysis: IntakeAnalysis) throws
}
public enum IntakeActionResult: Sendable { case reminders([String]), copied, pocketed }
public protocol IntakeAction: Sendable {
    var id: String { get }
    var title: String { get }
    func accepts(_ item: IntakeItem) -> Bool
    func score(_ item: IntakeItem, analysis: IntakeAnalysis) -> Double
    func preview(_ item: IntakeItem, analysis: IntakeAnalysis) -> IntakePreview
    @MainActor func perform(_ item: IntakeItem, analysis: IntakeAnalysis, context: any IntakeActionContext) async throws -> IntakeActionResult
}
public struct CreateReminder: IntakeAction {
    public let id = "reminder", title = "Create reminder"
    public init() {}
    public func accepts(_ item: IntakeItem) -> Bool { true }
    public func score(_ item: IntakeItem, analysis: IntakeAnalysis) -> Double {
        switch analysis.confidence { case .high: 1; case .medium: 0.8; case .low: 0.1 }
    }
    public func preview(_ item: IntakeItem, analysis: IntakeAnalysis) -> IntakePreview { IntakePreview(title: title, reminders: analysis.reminders) }
    @MainActor public func perform(_ item: IntakeItem, analysis: IntakeAnalysis, context: any IntakeActionContext) async throws -> IntakeActionResult {
        .reminders(try await context.createReminders(analysis.reminders.filter(\.selected), notes: item.notes))
    }
}
public struct CopyText: IntakeAction {
    public let id = "copy", title = "Copy text"
    public init() {}
    public func accepts(_ item: IntakeItem) -> Bool { !item.text.isEmpty || item.url != nil }
    public func score(_ item: IntakeItem, analysis: IntakeAnalysis) -> Double { analysis.confidence == .low ? 0.7 : 0.3 }
    public func preview(_ item: IntakeItem, analysis: IntakeAnalysis) -> IntakePreview { IntakePreview(title: title) }
    @MainActor public func perform(_ item: IntakeItem, analysis: IntakeAnalysis, context: any IntakeActionContext) async throws -> IntakeActionResult {
        try context.copyText(item.notes); return .copied
    }
}
public struct Pocket: IntakeAction {
    public let id = "pocket", title = "Pocket"
    public init() {}
    public func accepts(_ item: IntakeItem) -> Bool { true }
    public func score(_ item: IntakeItem, analysis: IntakeAnalysis) -> Double { analysis.confidence == .low ? 0.6 : 0.2 }
    public func preview(_ item: IntakeItem, analysis: IntakeAnalysis) -> IntakePreview { IntakePreview(title: title) }
    @MainActor public func perform(_ item: IntakeItem, analysis: IntakeAnalysis, context: any IntakeActionContext) async throws -> IntakeActionResult {
        try context.pocket(item, analysis: analysis); return .pocketed
    }
}
public struct IntakeLearning: Codable, Equatable, Sendable {
    public private(set) var choices: [String: [String: Int]] = [:]
    public init() {}
    public mutating func record(_ action: String, source: IntakeSource) {
        choices[source.rawValue, default: [:]][action, default: 0] += 1
    }
    public func bonus(_ action: String, source: IntakeSource) -> Double {
        let counts = choices[source.rawValue] ?? [:], total = counts.values.reduce(0, +)
        return total == 0 ? 0 : min(0.25, Double(counts[action] ?? 0) / Double(total) * 0.25)
    }
}
public enum IntakeRanking {
    public static func rank(_ actions: [any IntakeAction], item: IntakeItem, analysis: IntakeAnalysis,
                            learning: IntakeLearning) -> [any IntakeAction] {
        actions.filter { $0.accepts(item) && !(analysis.confidence == .low && $0.id == "reminder") }.sorted {
            let a = $0.score(item, analysis: analysis) + learning.bonus($0.id, source: item.source)
            let b = $1.score(item, analysis: analysis) + learning.bonus($1.id, source: item.source)
            return a == b ? $0.id < $1.id : a > b
        }
    }
}
public struct IntakeCardState: Sendable {
    public var item: IntakeItem
    public var analysis: IntakeAnalysis
    public var editing: Bool
    public var isPerforming = false
    public var error: String?
    public init(item: IntakeItem, analysis: IntakeAnalysis) {
        self.item = item; self.analysis = analysis; editing = false
    }
    public var focusesAdd: Bool { analysis.confidence == .high && !editing }
}
public struct PocketEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { item.id }
    public let item: IntakeItem
    public let analysis: IntakeAnalysis
    public let savedAt: Date
    public init(item: IntakeItem, analysis: IntakeAnalysis, savedAt: Date) { self.item = item; self.analysis = analysis; self.savedAt = savedAt }
    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince(savedAt) >= 7 * 24 * 60 * 60 }
}
public struct IntakeUndo: Sendable {
    public let reminderIDs: [String]
    public let expiresAt: Date
    public init(reminderIDs: [String], now: Date) { self.reminderIDs = reminderIDs; expiresAt = now.addingTimeInterval(5) }
    public func isAvailable(at now: Date) -> Bool { !reminderIDs.isEmpty && now < expiresAt }
}
public enum IntakeCommand: Sendable {
    case receive(IntakeItem, IntakeTrigger), choose(String, IntakeAnalysis), dismiss, reopen(UUID), undo
}
