import Foundation

/// App-level identity and resource location. Playback reads size, timing and
/// capabilities from the manifest, never from a character-name switch.
/// Only one definition is shipped; there is deliberately no picker or catalog.
public struct PetAssetDefinition: Equatable, Sendable {
    public let id: String
    public let title: String
    public let defaultName: String
    public let resourceName: String

    public static let acornHopper = Self(id: "acorn-hopper", title: "Acorn Hopper",
                                        defaultName: "Acorn", resourceName: "AcornHopper")

    public init(id: String, title: String, defaultName: String, resourceName: String) {
        self.id = id; self.title = title; self.defaultName = defaultName; self.resourceName = resourceName
    }

    public func resourceDirectory(in bundle: Bundle) -> URL? {
        bundle.url(forResource: resourceName, withExtension: nil)
    }
}
