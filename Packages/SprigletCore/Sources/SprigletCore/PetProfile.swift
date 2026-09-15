import Foundation

/// A small local identity. Traits stay fixed unless a profile is explicitly replaced.
public struct PetProfile: Codable, Equatable, Sendable {
    public static let defaultName = PetAssetDefinition.acornHopper.defaultName
    public static let maximumNameLength = 32
    public let name: String
    public let traits: PetTraits
    public var traitSummary: String { traits.summary }

    public init(name: String = Self.defaultName, traits: PetTraits = .sprout) {
        self.name = Self.sanitizedName(name)
        self.traits = traits
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: (try? values.decode(String.self, forKey: .name)) ?? Self.defaultName,
                  traits: (try? values.decode(PetTraits.self, forKey: .traits)) ?? .sprout)
    }

    /// String.prefix counts extended grapheme clusters, preserving composed names and emoji.
    public static func sanitizedName(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: continue
            case .format where scalar.value != 0x200C && scalar.value != 0x200D:
                // Strip invisible formatting/bidi controls, preserving natural joiners.
                continue
            default: scalars.append(scalar)
            }
        }
        let compact = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(compact.prefix(maximumNameLength)).trimmingCharacters(in: .whitespaces)
        let hasVisibleContent = name.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .format, .spaceSeparator, .nonspacingMark, .enclosingMark, .spacingMark: false
            default: true
            }
        }
        return hasVisibleContent ? name : defaultName
    }

    private enum CodingKeys: String, CodingKey { case name, traits }
}

/// Stable, bounded variation; recent interactions influence planning separately.
public struct PetTraits: Codable, Equatable, Sendable {
    public static let sprout = PetTraits(curiosity: 0.65, sociability: 0.60, playfulness: 0.45)
    public let curiosity: Double
    public let sociability: Double
    public let playfulness: Double

    public init(curiosity: Double = 0.65, sociability: Double = 0.60, playfulness: Double = 0.45) {
        self.curiosity = Self.bounded(curiosity, fallback: 0.65)
        self.sociability = Self.bounded(sociability, fallback: 0.60)
        self.playfulness = Self.bounded(playfulness, fallback: 0.45)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(curiosity: (try? values.decode(Double.self, forKey: .curiosity)) ?? 0.65,
                  sociability: (try? values.decode(Double.self, forKey: .sociability)) ?? 0.60,
                  playfulness: (try? values.decode(Double.self, forKey: .playfulness)) ?? 0.45)
    }

    public var summary: String {
        let curiosity = curiosity >= 0.60 ? "Curious" : curiosity <= 0.30 ? "Content to watch" : "Gently curious"
        let sociability = sociability >= 0.60 ? "friendly" : sociability <= 0.30 ? "independent" : "quietly affectionate"
        let playfulness = playfulness >= 0.65 ? "playful" : playfulness <= 0.30 ? "unhurried" : "gently playful"
        return "\(curiosity), \(sociability), and \(playfulness)."
    }

    private static func bounded(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
    private enum CodingKeys: String, CodingKey { case curiosity, sociability, playfulness }
}
