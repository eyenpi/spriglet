import Foundation
import FoundationModels
import Testing
@testable import SprigletIntelligence

/// These checks construct framework errors directly, so they never need
/// Apple Intelligence and run on CI runners.
@Suite("On-device intelligence")
struct OnDeviceIntelligenceTests {
    @Test("Every system availability state maps to a reason, or to ready", arguments: [
        (SystemLanguageModel.Availability.available, true, IntelligenceUnavailableReason?.none),
        (.available, false, .unsupportedLanguage),
        (.unavailable(.deviceNotEligible), true, .deviceNotEligible),
        (.unavailable(.appleIntelligenceNotEnabled), true, .appleIntelligenceNotEnabled),
        (.unavailable(.modelNotReady), true, .modelNotReady)
    ])
    func availability(system: SystemLanguageModel.Availability, supportsLocale: Bool,
                      expected: IntelligenceUnavailableReason?) {
        #expect(OnDeviceIntelligence.unavailableReason(system, supportsLocale: supportsLocale) == expected)
    }

    @Test("macOS 26 generation errors map to failures")
    func generationErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        let cases: [(LanguageModelSession.GenerationError, IntelligenceFailure)] = [
            (.exceededContextWindowSize(context), .contextOverflow),
            (.assetsUnavailable(context), .unavailable(.modelNotReady)),
            (.guardrailViolation(context), .declined),
            (.unsupportedGuide(context), .unknown),
            (.unsupportedLanguageOrLocale(context), .unavailable(.unsupportedLanguage)),
            (.decodingFailure(context), .unknown),
            (.rateLimited(context), .rateLimited),
            (.concurrentRequests(context), .busy)
        ]
        for (error, expected) in cases {
            #expect(IntelligenceFailure(error) == expected)
        }
        #expect(IntelligenceFailure(CancellationError()) == .cancelled)
        #expect(IntelligenceFailure(CocoaError(.fileNoSuchFile)) == .unknown)
    }

    @Test("The project's pinned Xcode 27 SDK compiles the macOS 27 error mapping")
    func modernMappingCompiled() {
        #expect(IntelligenceFailure.modernErrorMappingCompiled, "Build with the Xcode pinned in tools/CI/toolchains.json.")
    }

    #if compiler(>=6.4) && canImport(FoundationModels, _version: 2)
    @Test("macOS 27 errors map to the same failures")
    @available(macOS 27.0, *)
    func modernErrors() {
        let note = "test"
        let cases: [(any Error, IntelligenceFailure)] = [
            (LanguageModelError.contextSizeExceeded(.init(contextSize: 8_192, tokenCount: 9_000, debugDescription: note)), .contextOverflow),
            (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: note)), .rateLimited),
            (LanguageModelError.guardrailViolation(.init(debugDescription: note)), .declined),
            (LanguageModelError.refusal(.init(explanation: note, debugDescription: note)), .declined),
            (LanguageModelError.unsupportedCapability(.init(capability: .vision, debugDescription: note)), .unknown),
            (LanguageModelError.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: note)), .unknown),
            (LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: note)), .unknown),
            (LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: Locale.LanguageCode("xx"), debugDescription: note)),
             .unavailable(.unsupportedLanguage)),
            (LanguageModelError.timeout(.init(debugDescription: note)), .timedOut),
            (LanguageModelSession.Error.concurrentRequests, .busy),
            (LanguageModelSession.Error.transcriptMutationWhileResponding, .unknown),
            (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: note)), .unavailable(.modelNotReady))
        ]
        for (error, expected) in cases {
            #expect(IntelligenceFailure(error) == expected)
        }
    }
    #endif
}
