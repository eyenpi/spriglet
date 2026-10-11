import Foundation
import Testing
import AppKit
import CompanionCore
@testable import IntakeExtraction

private struct Fixture: Decodable, Sendable {
    let id: String, kind: String, text: String, reference: String, expectedTitle: String
    let expectedDate: String?, expectedTime: String?
    let expectedAllDay: Bool
    let modelTitle: String, modelPhrase: String
    var item: IntakeItem {
        IntakeItem(source: kind.hasPrefix("ocr") ? .image : .text, text: text,
                   receivedAt: ISO8601DateFormatter().date(from: reference)!)
    }
}
/// Only supplies source-derived task/title/phrase, never the expected date/time.
/// Date resolution and the production reconciliation run unchanged.
private struct MockModel: IntakeExtractionModel {
    let tasks: [IntakeModelTask]
    func extract(text: String, reference: Date) async throws -> [IntakeModelTask] { tasks }
}
private func fixtures() throws -> [Fixture] {
    try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures")!))
}
private actor ProgressLog {
    var items: [IntakeItem] = []
    func record(_ item: IntakeItem) { items.append(item) }
}
private struct Score {
    var date = false, time = false, overall = false
}
private func score(_ fixture: Fixture, _ result: IntakeAnalysis) -> Score {
    guard let draft = result.reminders.first, let due = draft.due else {
        let correct = fixture.expectedDate == nil && result.reminders.isEmpty
        return Score(date: correct, time: correct, overall: correct)
    }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = IntakeDateResolver.zone
    formatter.dateFormat = "yyyy-MM-dd"; let date = formatter.string(from: due) == fixture.expectedDate
    formatter.dateFormat = "HH:mm"; let time = formatter.string(from: due) == fixture.expectedTime
    return Score(date: date, time: time, overall: date && time && draft.title == fixture.expectedTitle && !fixture.expectedAllDay && result.reminders.count == 1)
}

@MainActor private func raster(_ text: String) -> Data {
    let image = NSImage(size: NSSize(width: 1200, height: 800))
    image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
    (text as NSString).draw(in: NSRect(x: 40, y: 80, width: 1120, height: 660), withAttributes: [
        .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return bitmap.representation(using: .png, properties: [:])!
}

@Suite struct IntakeExtractionTests {
    @Test("Corpus runs the production analyzer with a mock model and fixed reference dates")
    func corpusAccuracy() async throws {
        let corpus = try fixtures(); #expect(corpus.count >= 30)
        var date = 0, time = 0, overall = 0
        for fixture in corpus {
            let tasks = fixture.modelTitle.isEmpty ? [] : [IntakeModelTask(title: fixture.modelTitle, datePhrase: fixture.modelPhrase)]
            let result = try await LocalIntakeAnalyzer(model: MockModel(tasks: tasks)).analyze(fixture.item)
            let scored = score(fixture, result)
            date += scored.date ? 1 : 0; time += scored.time ? 1 : 0; overall += scored.overall ? 1 : 0
            if !scored.overall { print("CORPUS FAILURE \(fixture.id): date=\(scored.date) time=\(scored.time) drafts=\(result.reminders)") }
        }
        print("CORPUS ACCURACY: date \(date)/\(corpus.count), time \(time)/\(corpus.count), overall \(overall)/\(corpus.count)")
        #expect(Double(date) / Double(corpus.count) >= 0.9)
        #expect(Double(time) / Double(corpus.count) >= 0.9)
        #expect(Double(overall) / Double(corpus.count) >= 0.9)
    }
    @Test("Synthetic screenshot rasters pass through real Vision OCR before analysis")
    func screenshotAccuracy() async throws {
        let corpus = try fixtures().filter { $0.kind.hasPrefix("ocr") }
        var date = 0, time = 0, overall = 0
        let analyzer = LocalIntakeAnalyzer(modelsEnabled: false)
        for fixture in corpus {
            let png = await raster(fixture.text)
            let item = IntakeItem(source: .image, image: png, receivedAt: fixture.item.receivedAt)
            let start = Date()
            let enriched = try await analyzer.enrich(item)
            let result = try await LocalIntakeAnalyzer(model: MockModel(tasks: [IntakeModelTask(title: fixture.modelTitle, datePhrase: fixture.modelPhrase)])).analyze(enriched)
            let scored = score(fixture, result)
            date += scored.date ? 1 : 0; time += scored.time ? 1 : 0; overall += scored.overall ? 1 : 0
            if !scored.overall { print("OCR FAILURE \(fixture.id): \(enriched.text) => \(result.reminders)") }
            print("OCR LATENCY \(fixture.id): \(Date().timeIntervalSince(start))s")
        }
        print("OCR ACCURACY: date \(date)/\(corpus.count), time \(time)/\(corpus.count), overall \(overall)/\(corpus.count)")
        #expect(Double(date) / Double(corpus.count) >= 0.9)
        #expect(Double(time) / Double(corpus.count) >= 0.9)
        #expect(Double(overall) / Double(corpus.count) >= 0.9)
    }
    @Test("Fast OCR is published before an accurate fallback or model can delay the card")
    func fastOCRProgress() async throws {
        let fixture = try fixtures().first { $0.id == "demo-screenshot" }!
        let png = await raster(fixture.text)
        let log = ProgressLog()
        let enriched = try await LocalIntakeAnalyzer(modelsEnabled: false).enrich(
            IntakeItem(source: .image, image: png, receivedAt: fixture.item.receivedAt),
            onProgress: { await log.record($0) })
        let items = await log.items
        #expect(items.count == 1 && items.first?.text == enriched.text)
        #expect(score(fixture, LocalIntakeAnalyzer.detect(enriched)).date)
        #expect(score(fixture, LocalIntakeAnalyzer.detect(enriched)).time)
    }
    @Test("Model disagreement lowers confidence and cannot overwrite an explicit source time")
    func disagreement() async throws {
        let item = IntakeItem(source: .text, text: "Call Sam October 15, 2026 at 09:00", receivedAt: ISO8601DateFormatter().date(from: "2026-10-11T12:00:00+02:00")!)
        let agreed = IntakeModelTask(title: "Call Sam", datePhrase: "October 15, 2026 at 09:00", isoDate: "2026-10-15", localTime: "09:00")
        let a = try await LocalIntakeAnalyzer(model: MockModel(tasks: [agreed])).analyze(item)
        var wrong = agreed; wrong.isoDate = "2026-10-16"; wrong.localTime = "15:00"
        let b = try await LocalIntakeAnalyzer(model: MockModel(tasks: [wrong])).analyze(item)
        #expect(a.confidence == .high)
        #expect(b.confidence == .medium && b.reminders.first?.uncertain.contains(.date) == true)
        #expect(a.reminders.first?.due == b.reminders.first?.due)
        #expect(b.explanation.contains("disagree"))
    }
    @Test("Model time breaks a same-day phrase tie only against a timestamp actually in the source")
    func modelTieBreaker() async throws {
        let reference = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00+02:00")!
        let item = IntakeItem(source: .text, text: "Call Sam on October 15, 2026 at 2 PM\nSend report on October 15, 2026 at 4 PM", receivedAt: reference)
        let task = IntakeModelTask(title: "Call Sam", datePhrase: "October 15, 2026", isoDate: "2026-10-15", localTime: "14:00")
        let result = try await LocalIntakeAnalyzer(model: MockModel(tasks: [task])).analyze(item)
        #expect(result.reminders.count == 2 && result.confidence == .medium)
        #expect(IntakeDateResolver.calendar.component(.hour, from: result.reminders[0].due!) == 14)
        var invented = task; invented.localTime = "13:00"
        let rejected = try await LocalIntakeAnalyzer(model: MockModel(tasks: [invented])).analyze(item)
        #expect(rejected.reminders.count == 2)
        #expect(rejected.reminders.allSatisfy { IntakeDateResolver.calendar.component(.hour, from: $0.due!) != 13 })
    }
    @Test("Abstention, ungrounded dates and incomplete model phrases preserve local results")
    func modelFallback() async throws {
        let fixture = try fixtures().first { $0.id == "demo-screenshot" }!
        for tasks in [[], [IntakeModelTask(title: "Invented", datePhrase: "tomorrow at 5")],
                      [IntakeModelTask(title: "Send the draft", datePhrase: "October 16, 2026")]] {
            let result = try await LocalIntakeAnalyzer(model: MockModel(tasks: tasks)).analyze(fixture.item)
            #expect(result.reminders.first?.due == LocalIntakeAnalyzer.detect(fixture.item).reminders.first?.due)
        }
    }
    @Test("No time means a persistent 09:00 default; invalid dates are rejected")
    func defaultsAndInvalidDates() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00+02:00")!
        let result = LocalIntakeAnalyzer.detect(IntakeItem(source: .text, text: "Pay invoice on 15.10.2026", receivedAt: reference))
        #expect(result.reminders.first?.usesDefaultTime == true)
        #expect(result.reminders.first?.timeZoneID == "Europe/Berlin")
        let draft = result.reminders.first!
        let data = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(ReminderDraft.self, from: data).usesDefaultTime == true)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "usesDefaultTime")
        #expect(try JSONDecoder().decode(ReminderDraft.self, from: JSONSerialization.data(withJSONObject: legacy)).usesDefaultTime == nil)
        #expect(IntakeDateResolver.resolve("2026-02-30", reference: reference).isEmpty)
        #expect(IntakeDateResolver.resolve("31.02.2026", reference: reference).isEmpty)
        #expect(IntakeDateResolver.resolve("in 999999999999999999 weeks", reference: reference).isEmpty)
        #expect(IntakeDateResolver.clean("Call Sam at 14:3O on I5.1O.2026").contains("Call Sam at 14:30 on 15.10.2026"))
    }
}
