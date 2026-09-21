import Foundation
import FoundationModels
import SprigletConversation

/// The only production type that reaches Apple's on-device model. It holds at
/// most one session; the conversation engine decides when to rebuild it.
@MainActor
final class SystemConversationModel: ConversationModel {
    private let model: SystemLanguageModel
    private var session: LanguageModelSession?

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    var availability: ModelAvailability {
        Self.availability(model.availability, supportsLocale: model.supportsLocale())
    }

    func prepareSession(instructions: String) {
        session = LanguageModelSession(model: model, instructions: instructions)
    }

    func prewarm() {
        session?.prewarm()
    }

    func discardSession() {
        session = nil
    }

    func respond(to prompt: String, plainText: Bool, maximumResponseTokens: Int) async throws(ConversationFailure) -> ReplyDraft {
        guard let session else { throw .unknown }
        let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)
        do {
            if plainText {
                let response = try await session.respond(to: prompt, options: options)
                return ReplyDraft(spokenText: response.content, gesture: .none)
            }
            let response = try await session.respond(to: prompt, generating: CompanionReplyContent.self, options: options)
            return ReplyDraft(spokenText: response.content.spokenText, gesture: response.content.gesture.companionGesture)
        } catch {
            throw Self.failure(for: error)
        }
    }

    nonisolated static func availability(_ availability: SystemLanguageModel.Availability, supportsLocale: Bool) -> ModelAvailability {
        switch availability {
        case .available:
            return supportsLocale ? .available : .unavailable(.unsupportedLanguage)
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.modelNotReady)
            }
        }
    }

    /// Every framework error becomes a `ConversationFailure`; nothing else escapes.
    nonisolated static func failure(for error: any Error) -> ConversationFailure {
        if error is CancellationError { return .cancelled }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextOverflow
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unavailable(.unsupportedLanguage)
            case .rateLimited: return .rateLimited
            case .concurrentRequests: return .busy
            case .unsupportedGuide, .decodingFailure: return .unknown
            @unknown default: return .unknown
            }
        }
        // The macOS 27 error types exist only in the Xcode 27 SDK; CI still builds with Xcode 26.
        #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
        if #available(macOS 27.0, *), let failure = modernFailure(for: error) { return failure }
        #endif
        return .unknown
    }

    #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
    @available(macOS 27.0, *)
    private nonisolated static func modernFailure(for error: any Error) -> ConversationFailure? {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextOverflow
            case .rateLimited: return .rateLimited
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unavailable(.unsupportedLanguage)
            case .timeout: return .timedOut
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: return .unknown
            @unknown default: return .unknown
            }
        }
        if let error = error as? LanguageModelSession.Error {
            switch error {
            case .concurrentRequests: return .busy
            case .transcriptMutationWhileResponding: return .unknown
            @unknown default: return .unknown
            }
        }
        if error is SystemLanguageModel.Error { return .unavailable(.modelNotReady) }
        return nil
    }
    #endif
}
