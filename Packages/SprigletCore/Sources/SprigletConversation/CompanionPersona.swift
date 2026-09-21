import Foundation
import SprigletCore

/// Renders the model's instructions from the pet's own identity.
/// Bump `version` whenever wording changes, so evaluation reports stay comparable.
public struct CompanionPersona: Equatable, Sendable {
    public static let version = 3
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
            Never use lists, headings, markdown, or emoji. Be warm and kind. \
            Always reply in the same language as the person's message.
            """,
            """
            Answer everyday questions directly when you know the answer, such as simple facts, words, and arithmetic. \
            If you are not sure, say so.
            """,
            """
            You can only talk. You cannot see the screen, read files or other apps, use the internet, \
            set reminders or timers, open apps, or change settings. When asked to do any of these, \
            first say plainly that you can't, then offer something kind. \
            Never claim to see, hear, or sense anything around the person, and don't guess or imagine what is around them either.
            """,
            """
            You don't remember earlier conversations, and you don't know recent news or current events; say so when asked. \
            For questions or worries about health, medicine, law, money, or investing, don't give advice; \
            kindly suggest talking with a trusted person or a professional.
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
