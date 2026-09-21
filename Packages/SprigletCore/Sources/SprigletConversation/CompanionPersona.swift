import Foundation
import SprigletCore

/// Renders the model's instructions from the pet's own identity.
/// Bump `version` whenever wording changes, so evaluation reports stay comparable.
public struct CompanionPersona: Equatable, Sendable {
    public static let version = 1
    static let maximumEarlierCharacters = 200

    public let name: String
    public let traits: PetTraits

    public init(profile: PetProfile) {
        name = profile.name.replacingOccurrences(of: "\"", with: "'")
        traits = profile.traits
    }

    public var temperament: String {
        let curiosity = traits.curiosity >= 0.60 ? "curious" : traits.curiosity <= 0.30 ? "content to watch the world" : "gently curious"
        let sociability = traits.sociability >= 0.60 ? "friendly" : traits.sociability <= 0.30 ? "independent" : "quietly affectionate"
        let playfulness = traits.playfulness >= 0.65 ? "playful" : traits.playfulness <= 0.30 ? "unhurried" : "gently playful"
        return "\(curiosity), \(sociability), and \(playfulness)"
    }

    public func instructions(grounding: ConversationGrounding, earlier: [ConversationTurn] = []) -> String {
        var paragraphs = [
            """
            You are "\(name)", a tiny, round acorn sprite with a wobbly cap who lives on this person's Mac desktop. \
            You are \(temperament).
            """,
            """
            Reply in one or two short sentences that sound natural when spoken aloud. \
            Never use lists, headings, markdown, or emoji. Be warm and kind, and reply in the language the person uses.
            """,
            """
            You can only talk. You cannot see the screen, read files or other apps, use the internet, set reminders, \
            or change settings. If you are asked to do or notice something you can't, say so simply. \
            Never pretend, and never claim to see, hear, or sense anything around the person.
            """,
            """
            You may be wrong, so say when you are not sure. You do not know recent news. \
            For worries about health, law, money, or safety, be kind and suggest talking with a trusted person or a professional.
            """,
            grounding.sentence
        ]
        if !earlier.isEmpty {
            let lines = earlier.map { turn in
                "They said \"\(Self.quoted(turn.prompt))\" and you replied \"\(Self.quoted(turn.reply))\"."
            }
            paragraphs.append((["Earlier in this conversation:"] + lines).joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\"", with: "'")
        guard flat.count > maximumEarlierCharacters else { return flat }
        return String(flat.prefix(maximumEarlierCharacters)) + "…"
    }
}
