import AppKit
import CompanionCore

@MainActor enum IntakeDropReader {
    static func read(_ board: NSPasteboard) throws -> IntakeItem? {
        // Files and URLs take precedence over their textual pasteboard representation.
        if let string = board.string(forType: .fileURL), let url = URL(string: string), url.isFileURL {
            return try IntakeFileAccess.item(for: url)
        }
        if let data = board.data(forType: NSPasteboard.PasteboardType("public.png")) ?? board.data(forType: .tiff), data.count <= 20 * 1024 * 1024 {
            return IntakeItem(source: .image, name: "Dropped image", image: data)
        }
        if let string = board.string(forType: .URL), let url = URL(string: string) {
            return IntakeItem(source: .url, text: string, url: url)
        }
        if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return IntakeItem(source: .url, text: text, url: url)
            }
            return IntakeItem(source: .text, text: text)
        }
        return nil
    }
}
