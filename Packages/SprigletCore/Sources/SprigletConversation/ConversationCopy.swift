import Foundation

/// Every sentence the person can hear or read about conversation state.
/// Each surface renders from here, so wording stays consistent and testable.
public enum ConversationCopy {
    public static func questionPrompt(name: String) -> String {
        "What would you like to ask \(name)?"
    }

    /// Spoken in character, as an ordinary reply rather than an error. The system
    /// model's guardrails decline some health and money questions outright, so the
    /// decline itself carries the referral the persona would otherwise give.
    public static let declineReply = "That's something I can't help with. Someone you trust, or a professional, would be a better person to ask."

    public static func text(for failure: ConversationFailure, name: String) -> String {
        switch failure {
        case .disabled:
            "Talking with \(name) is off. Turn it on in Spriglet Settings, in the Conversation tab."
        case .unavailable(let reason):
            text(for: reason, name: name)
        case .busy, .rateLimited:
            "\(name) is still thinking about the last question."
        case .emptyPrompt:
            "I didn't catch a question. Try asking again."
        case .declined:
            declineReply
        case .contextOverflow:
            "Let's start fresh. What would you like to talk about?"
        case .timedOut, .unknown:
            "Something went wrong while \(name) was thinking. Please try again."
        case .cancelled:
            "Okay, never mind."
        }
    }

    public static func text(for reason: ModelUnavailableReason, name: String) -> String {
        switch reason {
        case .deviceNotEligible:
            "Talking needs a Mac that supports Apple Intelligence. \(name) can still keep you company."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings to talk with \(name)."
        case .modelNotReady:
            "Apple Intelligence is still getting ready on this Mac. Try again in a little while."
        case .unsupportedLanguage:
            "\(name) can't chat in your current language yet."
        }
    }

    /// Settings status when macOS will not deliver Siri or Shortcuts actions to this build.
    public static let siriUnreachable = "Siri can't reach this preview build."
    public static let siriUnreachableDetail = "Siri and Shortcuts work only with builds signed by a developer, such as App Store releases. This copy can't receive them."

    /// A short status line for Settings.
    public static func status(for availability: ModelAvailability, name: String) -> String {
        switch availability {
        case .available: "Ready"
        case .unavailable(let reason): text(for: reason, name: name)
        }
    }
}
