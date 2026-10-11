import Foundation
import CompanionCore

/// Date policy shared by OCR, detectors and the guided-model cross-check.
/// NSDataDetector has no public reference-date option. Anchor relative/yearless
/// expressions to receivedAt before detection; never trust its wall-clock inference.
nonisolated enum IntakeDateResolver {
    static let timePattern = #"\b(?:(?:at|um)\s+)?(\d{1,2})(?::(\d{2})\b(?:\s*(AM|PM)\b)?|\s*(AM|PM)\b)|\b(?:at|um)\s+(\d{1,2})\b|\b(noon|midnight)\b"#
    static let zone = TimeZone(identifier: "Europe/Berlin")!
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    struct Candidate: Sendable {
        let due: Date
        let phrase: String
        let defaultTime: Bool
        let title: String
        let detectorDisagrees: Bool
        let ambiguousTime: Bool
        let priority: Int
    }
    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }
    static func group(_ n: Int, _ match: NSTextCheckingResult, _ text: String) -> String {
        guard n < match.numberOfRanges, match.range(at: n).location != NSNotFound else { return "" }
        return (text as NSString).substring(with: match.range(at: n))
    }
    static func replace(_ pattern: String, in text: String, using transform: (NSTextCheckingResult) -> String) -> String {
        var result = text
        for m in matches(pattern, text).reversed() {
            if let range = Range(m.range, in: result) { result.replaceSubrange(range, with: transform(m)) }
        }
        return result
    }
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{00a0}", with: " ")
        // Correct only tokens shaped like dates/times, never words such as Sam.
        text = replace(#"\b[0-9OlIS]{1,4}[.:/\-][0-9OlIS]{1,2}(?:[./\-][0-9OlIS]{2,4})?\b"#, in: text) { m in
            group(0, m, text).replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "l", with: "1")
                .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "S", with: "5")
        }
        text = replace(#"\b[OlIS0-9]{1,2}(?=\s+(?:Jan|Feb|Mar|Mär|Apr|Mai|May|Jun|Jul|Aug|Sep|Oct|Okt|Nov|Dec|Dez))"#, in: text) { m in
            group(0, m, text).replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "l", with: "1")
                .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "S", with: "5")
        }
        text = replace(#"\b[0-9][0-9OlIS]{2}[0-9]\b"#, in: text) { m in
            group(0, m, text).replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "l", with: "1")
                .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "S", with: "5")
        }
        text = replace(#"\b(at|um)(?=\d)"#, in: text) { m in group(0, m, text) + " " }
        return text
    }
    static func iso(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: d) == year, calendar.component(.month, from: d) == month,
              calendar.component(.day, from: d) == day else { return nil }
        return d
    }
    static func anchor(_ source: String, reference: Date) -> String {
        var text = source
        text = replace(#"\b(today|tomorrow|day after tomorrow|heute|morgen|übermorgen)\b"#, in: text) { m in
            let word = group(0, m, text).lowercased()
            let offset = ["today": 0, "heute": 0, "tomorrow": 1, "morgen": 1, "day after tomorrow": 2, "übermorgen": 2][word] ?? 0
            return iso(calendar.date(byAdding: .day, value: offset, to: reference)!)
        }
        text = replace(#"\bin\s+(\d+)\s+(days?|weeks?|tagen?|wochen?)\b"#, in: text) { m in
            guard let n = Int(group(1, m, text)), (0...3650).contains(n) else { return group(0, m, text) }
            let weeks = group(2, m, text).lowercased().hasPrefix("w")
            return iso(calendar.date(byAdding: .day, value: n * (weeks ? 7 : 1), to: reference)!)
        }
        let weekdays = ["sunday": 1, "sonntag": 1, "monday": 2, "montag": 2, "tuesday": 3, "dienstag": 3,
                        "wednesday": 4, "mittwoch": 4, "thursday": 5, "donnerstag": 5, "friday": 6, "freitag": 6, "saturday": 7, "samstag": 7]
        text = replace(#"\b(?:(next|this|nächsten|nächster|diesen)\s+)?(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sonntag|Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag)\b"#, in: text) { m in
            let weekday = weekdays[group(2, m, text).lowercased()]!
            var delta = (weekday - calendar.component(.weekday, from: reference) + 7) % 7
            if delta == 0 { delta = 7 }
            return iso(calendar.date(byAdding: .day, value: delta, to: reference)!)
        }
        // EU day-first formats, including an OCR-split year.
        text = replace(#"\b(\d{1,2})[./](\d{1,2})[./]\s*(\d{4}|\d{2})\b"#, in: text) { m in
            var y = Int(group(3, m, text)) ?? 0; if y < 100 { y += 2000 }
            return day(y, Int(group(2, m, text)) ?? 0, Int(group(1, m, text)) ?? 0).map(iso) ?? group(0, m, text)
        }
        let months = ["jan": 1, "feb": 2, "mar": 3, "mär": 3, "apr": 4, "may": 5, "mai": 5,
                      "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "dez": 12]
        let monthPattern = "(?:January|Jan|February|Feb|March|Mar|März|Mär|April|Apr|May|Mai|June|Jun|July|Jul|August|Aug|September|Sept|Sep|October|Oct|Oktober|Okt|November|Nov|December|Dec|Dezember|Dez)"
        for dayFirst in [true, false] {
            let pattern = dayFirst ? #"\b(\d{1,2})\.?\s+("# + monthPattern + #")\.?(?:,?\s+(\d{4}))?\b"#
                : #"\b("# + monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#
            text = replace(pattern, in: text) { m in
                let month = months[String(group(dayFirst ? 2 : 1, m, text).lowercased().prefix(3))] ?? 0
                let d = Int(group(dayFirst ? 1 : 2, m, text)) ?? 0
                let explicitYear = Int(group(3, m, text))
                var y = explicitYear ?? calendar.component(.year, from: reference)
                if explicitYear == nil, let date = day(y, month, d), date < calendar.startOfDay(for: reference) { y += 1 }
                return day(y, month, d).map(iso) ?? group(0, m, text)
            }
        }
        return text
    }
    static func resolve(_ source: String, reference: Date) -> [Candidate] {
        let cleaned = clean(source)
        let text = anchor(cleaned, reference: reference)
        // Joining soft OCR wraps lets a date and its time reach the detector together.
        let joined = text.replacingOccurrences(of: "\n", with: " ")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let detected = detector?.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)) ?? []
        let dates = matches(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, text)
        var candidates: [Candidate] = []
        for (index, m) in dates.enumerated() {
            guard let date = day(Int(group(1, m, text))!, Int(group(2, m, text))!, Int(group(3, m, text))!) else { continue }
            let end = index + 1 < dates.count ? dates[index + 1].range.location : (text as NSString).length
            let suffix = (text as NSString).substring(with: NSRange(location: NSMaxRange(m.range), length: end - NSMaxRange(m.range)))
            // Restrict time association to the same or immediately following OCR line.
            let vicinity = suffix.components(separatedBy: .newlines).prefix(2).joined(separator: " ")
            let time = matches(timePattern, vicinity).first
            var hour = 9, minute = 0
            if let time {
                hour = Int(group(1, time, vicinity)) ?? Int(group(5, time, vicinity)) ?? 9
                minute = Int(group(2, time, vicinity)) ?? 0
                let ampm = (group(3, time, vicinity) + group(4, time, vicinity)).lowercased()
                if !ampm.isEmpty { hour = hour % 12 + (ampm == "pm" ? 12 : 0) }
                if group(6, time, vicinity).lowercased() == "noon" { hour = 12 }
                if group(6, time, vicinity).lowercased() == "midnight" { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute),
                  let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date),
                  calendar.component(.hour, from: due) == hour else { continue }
            // Detector is a corroborating source; explicit formats remain parseable
            // when it drops a valid EU date or OCR wrap. It never supplies the clock.
            let phrase = group(0, m, text)
            let detectorPhrase = detected.first { (joined as NSString).substring(with: $0.range).contains(phrase) }
            let detectorDisagrees = detectorPhrase?.date.map { detectedDate in
                var detectorCalendar = Calendar(identifier: .gregorian)
                detectorCalendar.timeZone = detectorPhrase?.timeZone ?? .current
                var fields: Set<Calendar.Component> = [.year, .month, .day]
                if let detectorPhrase, time != nil,
                   !matches(timePattern, (joined as NSString).substring(with: detectorPhrase.range)).isEmpty {
                    fields.formUnion([.hour, .minute])
                }
                return detectorCalendar.dateComponents(fields, from: detectedDate)
                    != calendar.dateComponents(fields, from: due)
            } ?? false
            let prefix = (text as NSString).substring(to: m.range.location)
            let context = String(prefix.suffix(70)).lowercased()
            let priority = matches(#"(?:payment due|due date|fällig|fallig|departure|check-in)\s*:?\s*$"#, context).isEmpty ? 0 : 1
            var title = prefix.components(separatedBy: .newlines).last ?? ""
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = replace(#"\b(?:on|at|by|due|am|um|fällig|fallig|date|when|departure|check-in|payment due)\s*:?\s*$"#, in: title) { _ in "" }
            if title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
                title = prefix.components(separatedBy: .newlines).dropLast().reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Reminder"
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            candidates.append(Candidate(due: due, phrase: phrase, defaultTime: time == nil, title: String(title.prefix(240)), detectorDisagrees: detectorDisagrees, ambiguousTime: time.map { !group(5, $0, vicinity).isEmpty } ?? false, priority: priority))
        }
        // General natural-language detector fallback: only accept an explicit year,
        // avoiding any implicit wall-clock dates the detector synthesized.
        let invalidEU = matches(#"\b(\d{1,2})[./](\d{1,2})[./]\s*(\d{4}|\d{2})\b"#, text).contains { m in
            var year = Int(group(3, m, text)) ?? 0; if year < 100 { year += 2000 }
            return day(year, Int(group(2, m, text)) ?? 0, Int(group(1, m, text)) ?? 0) == nil
        }
        if candidates.isEmpty && dates.isEmpty && !invalidEU {
            for m in detected where matches(#"\b\d{4}\b"#, (joined as NSString).substring(with: m.range)).count > 0 {
                guard let detectedDate = m.date else { continue }
                let phrase = (joined as NSString).substring(with: m.range)
                let explicitTime = !matches(#"\d{1,2}:\d{2}|\d{1,2}\s*(?:AM|PM)|(?:at|um)\s+\d{1,2}"#, phrase).isEmpty
                let date = explicitTime ? detectedDate : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: detectedDate)!
                candidates.append(Candidate(due: date, phrase: phrase, defaultTime: !explicitTime, title: String(cleaned.components(separatedBy: .newlines).first?.prefix(240) ?? "Reminder"), detectorDisagrees: false, ambiguousTime: false, priority: 0))
            }
        }
        let priority = candidates.map(\.priority).max() ?? 0
        return candidates.filter { $0.priority == priority }
    }
}
