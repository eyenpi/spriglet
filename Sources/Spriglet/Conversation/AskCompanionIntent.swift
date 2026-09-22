import AppIntents
import SprigletConversation

/// Siri and Shortcuts reach the conversation only through the shared controller.
struct AskCompanionIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Spriglet"
    static let description = IntentDescription("Ask your desktop companion something. Apple Intelligence answers on this Mac.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Question")
    var question: String?

    @Dependency
    private var conversation: ConversationController

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        if let failure = await conversation.readinessFailure() {
            throw ConversationIntentError(message: ConversationCopy.text(for: failure, name: await conversation.companionName))
        }
        let attention = await conversation.beginAttention(surface: .siri)
        let text: String
        do {
            if let question, !question.isEmpty {
                text = question
            } else {
                let prompt = ConversationCopy.questionPrompt(name: await conversation.companionName)
                text = try await $question.requestValue("\(prompt)")
            }
        } catch {
            await conversation.endAttention(attention)
            throw error
        }
        switch await conversation.send(ConversationRequest(text: text, surface: .siri)) {
        case .reply(let draft):
            return .result(value: draft.spokenText, dialog: "\(draft.spokenText)")
        case .failure(let failure):
            throw ConversationIntentError(message: ConversationCopy.text(for: failure, name: await conversation.companionName))
        }
    }
}

/// Siri speaks this message; Shortcuts reports the action as failed.
nonisolated struct ConversationIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
