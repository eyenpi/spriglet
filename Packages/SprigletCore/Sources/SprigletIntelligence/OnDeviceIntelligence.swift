import FoundationModels

public enum IntelligenceUnavailableReason: String, CaseIterable, Sendable {
    case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unsupportedLanguage
}

public enum IntelligenceFailure: Error, Equatable, Sendable {
    case unavailable(IntelligenceUnavailableReason)
    /// A guardrail or refusal.
    case declined
    case contextOverflow
    case rateLimited
    case busy
    case timedOut
    case cancelled
    case unknown
}

/// Single-shot structured generation with Apple's on-device model. Every call
/// uses a fresh session and keeps nothing, so shared content never outlives the
/// request that carried it.
public struct OnDeviceIntelligence: Sendable {
    private let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// Nil when the model can run now.
    public var unavailableReason: IntelligenceUnavailableReason? {
        Self.unavailableReason(model.availability, supportsLocale: model.supportsLocale())
    }

    public func generate<Output: Generable & Sendable>(
        _ type: Output.Type,
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int? = nil
    ) async throws(IntelligenceFailure) -> Output {
        if let reason = unavailableReason { throw .unavailable(reason) }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            return try await session.respond(
                to: prompt, generating: type,
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            ).content
        } catch {
            throw IntelligenceFailure(error)
        }
    }

    static func unavailableReason(_ availability: SystemLanguageModel.Availability,
                                  supportsLocale: Bool) -> IntelligenceUnavailableReason? {
        switch availability {
        case .available:
            return supportsLocale ? nil : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }
}

extension IntelligenceFailure {
    /// On macOS 27 even macOS 26-style calls throw `LanguageModelError`, which
    /// only the Xcode 27 SDK can name; older SDKs map those errors to `.unknown`.
    public static var modernErrorMappingCompiled: Bool {
        #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
        true
        #else
        false
        #endif
    }

    init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if let error = error as? LanguageModelSession.GenerationError {
            self = switch error {
            case .exceededContextWindowSize: .contextOverflow
            case .assetsUnavailable: .unavailable(.modelNotReady)
            case .guardrailViolation, .refusal: .declined
            case .unsupportedLanguageOrLocale: .unavailable(.unsupportedLanguage)
            case .rateLimited: .rateLimited
            case .concurrentRequests: .busy
            case .unsupportedGuide, .decodingFailure: .unknown
            @unknown default: .unknown
            }
            return
        }
        #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
        if #available(macOS 27.0, *), let failure = Self.modern(error) {
            self = failure
            return
        }
        #endif
        self = .unknown
    }

    #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
    @available(macOS 27.0, *)
    private static func modern(_ error: any Error) -> IntelligenceFailure? {
        if let error = error as? LanguageModelError {
            return switch error {
            case .contextSizeExceeded: .contextOverflow
            case .rateLimited: .rateLimited
            case .guardrailViolation, .refusal: .declined
            case .unsupportedLanguageOrLocale: .unavailable(.unsupportedLanguage)
            case .timeout: .timedOut
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: .unknown
            @unknown default: .unknown
            }
        }
        if let error = error as? LanguageModelSession.Error {
            return error == .concurrentRequests ? .busy : .unknown
        }
        if error is SystemLanguageModel.Error { return .unavailable(.modelNotReady) }
        return nil
    }
    #endif
}
