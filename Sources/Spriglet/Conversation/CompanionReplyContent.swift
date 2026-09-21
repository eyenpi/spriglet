import FoundationModels
import SprigletConversation

/// The structured reply requested from the on-device model. Constrained
/// decoding guarantees the gesture is one of the four known cases.
@Generable
nonisolated struct CompanionReplyContent {
    @Guide(description: "What you say aloud: one or two short, warm sentences. No lists, markdown, or emoji.")
    var spokenText: String

    @Guide(description: "Your small visible reaction. cheerful: greetings, jokes, compliments, or happy news. attentive: worries, sadness, tiredness, problems, or requests. curious: only when they share something new about themselves. none: anything else.")
    var gesture: CompanionGestureContent
}

@Generable
nonisolated enum CompanionGestureContent {
    case none, attentive, curious, cheerful

    var companionGesture: CompanionGesture {
        switch self {
        case .none: .none
        case .attentive: .attentive
        case .curious: .curious
        case .cheerful: .cheerful
        }
    }
}
