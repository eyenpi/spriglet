import Foundation
import SprigletCore

/// Where a request came from. Surfaces render outcomes differently, but share one conversation.
public enum ConversationSurface: String, CaseIterable, Sendable {
    case siri, shortcuts, panel
}

public struct ConversationRequest: Equatable, Sendable {
    public let text: String
    public let surface: ConversationSurface

    public init(text: String, surface: ConversationSurface) {
        self.text = text
        self.surface = surface
    }
}

public struct ConversationRequestID: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

public struct AttentionID: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// One completed exchange. Deliberately not `Codable`: conversation text has no persistence path.
public struct ConversationTurn: Equatable, Sendable {
    public let prompt: String
    public let reply: String
    public let at: MonotonicTimestamp

    public init(prompt: String, reply: String, at: MonotonicTimestamp) {
        self.prompt = prompt
        self.reply = reply
        self.at = at
    }
}

/// A bounded, in-memory record of recent exchanges. Never `Codable`.
public struct ConversationHistory: Equatable, Sendable {
    public private(set) var turns: [ConversationTurn] = []

    public init() {}

    public var isEmpty: Bool { turns.isEmpty }

    public mutating func append(_ turn: ConversationTurn, limit: Int) {
        guard limit > 0 else {
            turns.removeAll()
            return
        }
        turns.append(turn)
        if turns.count > limit { turns.removeFirst(turns.count - limit) }
    }

    public func carryOver(_ count: Int) -> [ConversationTurn] {
        Array(turns.suffix(max(0, count)))
    }
}

/// A semantic reaction. `GesturePolicy` resolves it to authored content, so richer
/// character packages can add clips without changing conversation code.
public enum CompanionGesture: String, CaseIterable, Sendable {
    case none, attentive, curious, cheerful
}

public struct ReplyDraft: Equatable, Sendable {
    public let spokenText: String
    public let gesture: CompanionGesture

    public init(spokenText: String, gesture: CompanionGesture) {
        self.spokenText = spokenText
        self.gesture = gesture
    }
}

/// Mirrors the system model's reasons without importing FoundationModels.
public enum ModelUnavailableReason: String, CaseIterable, Sendable {
    case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unsupportedLanguage
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(ModelUnavailableReason)
}

public enum ConversationFailure: Error, Equatable, Sendable {
    case disabled
    case unavailable(ModelUnavailableReason)
    case busy
    case emptyPrompt
    case declined
    case contextOverflow
    case rateLimited
    case timedOut
    case cancelled
    case unknown

    public static let allCases: [ConversationFailure] = [
        .disabled, .busy, .emptyPrompt, .declined, .contextOverflow,
        .rateLimited, .timedOut, .cancelled, .unknown
    ] + ModelUnavailableReason.allCases.map { .unavailable($0) }
}

public enum ConversationOutcome: Equatable, Sendable {
    case reply(ReplyDraft)
    case failure(ConversationFailure)
}

/// What the conversation needs to know about the companion. Values only.
public struct CompanionSnapshot: Equatable, Sendable {
    public let profile: PetProfile
    public let isSleeping: Bool
    /// The decayed affection trace, 0...1. Its bucket, never its history, reaches the model.
    public let recentAffection: Double

    public init(profile: PetProfile, isSleeping: Bool, recentAffection: Double) {
        self.profile = profile
        self.isSleeping = isSleeping
        self.recentAffection = recentAffection.isFinite ? min(1, max(0, recentAffection)) : 0
    }
}
