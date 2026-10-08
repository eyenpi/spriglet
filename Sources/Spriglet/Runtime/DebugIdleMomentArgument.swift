#if DEBUG
import CompanionCore

enum DebugIdleMomentArgument {
    static let name = "SprigletDebugIdleMoment"

    static func parse(arguments: [String]) -> IdleMoment? {
        guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return switch arguments[index + 1] {
        case "wander": .wander
        case "nap": .nap
        case "doodle": .doodle
        case "fidget": .fidget
        default: nil
        }
    }
}
#endif
