#if DEBUG
import Foundation
import CompanionCore

/// Explicit local demo input; uses the same asynchronous analysis and card path.
/// Image paths do not grant sandbox access. Use a readable temporary/container file.
enum DebugIntakeArgument {
    static func parse(arguments: [String]) -> IntakeItem? {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let text = value("-SprigletDebugIntakeText"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return IntakeItem(source: .text, text: text)
        }
        if let path = value("-SprigletDebugIntakeImage"),
           let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 20 * 1024 * 1024, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return IntakeItem(source: .image, name: "Debug demo image", image: data)
        }
        return nil
    }
}
#endif
