import Foundation

/// Limits sized for the macOS 26 on-device context of 4,096 tokens.
public struct ConversationPolicy: Equatable, Sendable {
    public let maximumTurns: Int
    public let carryOverTurns: Int
    public let idlePurgeSeconds: Double
    public let maximumPromptCharacters: Int
    public let maximumReplyCharacters: Int
    public let maximumResponseTokens: Int
    public let maximumTurnsPerMinute: Int
    public let attentionTimeoutSeconds: Double

    public static let standard = ConversationPolicy()

    public init(
        maximumTurns: Int = 8,
        carryOverTurns: Int = 2,
        idlePurgeSeconds: Double = 600,
        maximumPromptCharacters: Int = 1_000,
        maximumReplyCharacters: Int = 400,
        maximumResponseTokens: Int = 160,
        maximumTurnsPerMinute: Int = 12,
        attentionTimeoutSeconds: Double = 60
    ) {
        self.maximumTurns = max(1, maximumTurns)
        self.carryOverTurns = min(max(0, carryOverTurns), self.maximumTurns)
        self.idlePurgeSeconds = idlePurgeSeconds.isFinite ? max(1, idlePurgeSeconds) : 600
        self.maximumPromptCharacters = max(1, maximumPromptCharacters)
        self.maximumReplyCharacters = max(40, maximumReplyCharacters)
        self.maximumResponseTokens = max(16, maximumResponseTokens)
        self.maximumTurnsPerMinute = max(1, maximumTurnsPerMinute)
        self.attentionTimeoutSeconds = attentionTimeoutSeconds.isFinite ? max(1, attentionTimeoutSeconds) : 60
    }
}
