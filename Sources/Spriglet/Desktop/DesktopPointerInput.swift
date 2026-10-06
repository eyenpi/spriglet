import CompanionCore

enum DesktopPointerInput {
    case pressed(Point)
    case dragged(Point)
    case released(Point)

    var globalPoint: Point {
        switch self {
        case .pressed(let point), .dragged(let point), .released(let point): point
        }
    }
}
