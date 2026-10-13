/// The tucked body keeps the standard contour's six continuous segments, so
/// both drawing and picking can interpolate the same curves during emergence.
enum RelaxedMallow {
    static let bodyCurves: [CharacterCurve] = [
        CharacterCurve(start: Point(x: -87, y: -23), control1: Point(x: -78, y: -24), control2: Point(x: -68, y: -24), end: Point(x: -58, y: -24)),
        CharacterCurve(start: Point(x: -58, y: -24), control1: Point(x: -46, y: -25), control2: Point(x: -34, y: -25), end: Point(x: -22, y: -25)),
        CharacterCurve(start: Point(x: -22, y: -25), control1: Point(x: -4, y: -25), control2: Point(x: 16, y: -25), end: Point(x: 29, y: -25)),
        CharacterCurve(start: Point(x: 29, y: -25), control1: Point(x: 46, y: -25), control2: Point(x: 68, y: -24), end: Point(x: 87, y: -23)),
        CharacterCurve(start: Point(x: 87, y: -23), control1: Point(x: 64, y: -13), control2: Point(x: 34, y: -3), end: Point(x: 0, y: -3)),
        CharacterCurve(start: Point(x: 0, y: -3), control1: Point(x: -34, y: -3), control2: Point(x: -64, y: -13), end: Point(x: -87, y: -23)),
    ]
    static let outline = bodyCurves.flatMap { $0.outline.dropLast() }
}

extension CharacterCurve {
    func interpolated(to other: CharacterCurve, amount: Double) -> CharacterCurve {
        func blend(_ a: Point, _ b: Point) -> Point { a + (b - a) * amount }
        return CharacterCurve(start: blend(start, other.start), control1: blend(control1, other.control1),
                              control2: blend(control2, other.control2), end: blend(end, other.end))
    }
}
