import Foundation
import SprigletCore

/// Pure conversation state machine. It owns no clock, task, or model; the
/// controller performs the returned effects in order.
///
/// Guarantees: at most one turn in flight; every request is delivered exactly
/// once; presence begin and end are strictly paired; a purge deadline exists
/// only while unforgotten text exists.
public struct ConversationEngine: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let id: ConversationRequestID
        public let prompt: String
        public let attempt: Int
        public let plainText: Bool
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case attending(AttentionID, since: MonotonicTimestamp)
        case responding(Turn)
    }

    public enum Event: Equatable, Sendable {
        case attentionBegan(AttentionID, at: MonotonicTimestamp, enabled: Bool, availability: ModelAvailability)
        case attentionEnded(AttentionID)
        case request(ConversationRequestID, text: String, at: MonotonicTimestamp, enabled: Bool, availability: ModelAvailability)
        case replied(ConversationRequestID, ReplyDraft, at: MonotonicTimestamp)
        case failed(ConversationRequestID, ConversationFailure, at: MonotonicTimestamp)
        case cancelRequest(ConversationRequestID)
        case deadline(ConversationDeadline, at: MonotonicTimestamp)
        case forget
        case companionChanged
    }

    public enum Effect: Equatable, Sendable {
        case prepareSession(carryOver: [ConversationTurn])
        case prewarm
        case presenceBegan
        case presenceEnded(CompanionGesture)
        case startTurn(Turn)
        case cancelTurn
        case deliver(ConversationRequestID, ConversationOutcome)
        case schedule(ConversationDeadline, at: MonotonicTimestamp)
        case cancel(ConversationDeadline)
        case discardSession
    }

    public let policy: ConversationPolicy
    public private(set) var phase: Phase = .idle
    public private(set) var history = ConversationHistory()
    public private(set) var lastActivity: MonotonicTimestamp?
    public private(set) var hasSession = false
    public private(set) var isPresenceActive = false
    private var invalidateAfterTurn = false
    private var acceptedRequestTimes: [MonotonicTimestamp] = []

    public init(policy: ConversationPolicy = .standard) {
        self.policy = policy
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .attentionBegan(id, at, enabled, availability):
            return attentionBegan(id, at: at, enabled: enabled, availability: availability)
        case let .attentionEnded(id):
            return attentionEnded(id)
        case let .request(id, text, at, enabled, availability):
            return request(id, text: text, at: at, enabled: enabled, availability: availability)
        case let .replied(id, draft, at):
            return replied(id, draft, at: at)
        case let .failed(id, failure, at):
            guard case .responding(let turn) = phase, turn.id == id else { return [] }
            return failed(turn, failure, at: at)
        case let .cancelRequest(id):
            guard case .responding(let turn) = phase, turn.id == id else { return [] }
            return [.cancelTurn] + endTurn(turn, failure: .cancelled, at: nil)
        case let .deadline(key, at):
            return deadline(key, at: at)
        case .forget:
            return forget()
        case .companionChanged:
            if case .responding = phase {
                invalidateAfterTurn = true
                return []
            }
            return discardSessionIfPresent()
        }
    }

    // MARK: Attention

    private mutating func attentionBegan(_ id: AttentionID, at: MonotonicTimestamp,
                                         enabled: Bool, availability: ModelAvailability) -> [Effect] {
        switch phase {
        case .responding:
            return []
        case .attending:
            phase = .attending(id, since: at)
            return [.schedule(.attentionTimeout, at: adding(policy.attentionTimeoutSeconds, to: at))]
        case .idle:
            // A request that will fail must not wake or hold the pet.
            guard enabled, availability == .available else { return [] }
            var effects = expireIfStale(at)
            effects += ensureSession()
            phase = .attending(id, since: at)
            effects += beginPresence()
            effects += [.prewarm, .schedule(.attentionTimeout, at: adding(policy.attentionTimeoutSeconds, to: at))]
            return effects
        }
    }

    private mutating func attentionEnded(_ id: AttentionID) -> [Effect] {
        guard case .attending(let current, _) = phase, current == id else { return [] }
        phase = .idle
        return [.cancel(.attentionTimeout)] + endPresence(.none) + schedulePurgeIfNeeded()
    }

    // MARK: Turns

    private mutating func request(_ id: ConversationRequestID, text: String, at: MonotonicTimestamp,
                                  enabled: Bool, availability: ModelAvailability) -> [Effect] {
        if case .responding = phase { return [.deliver(id, .failure(.busy))] }
        guard enabled else { return reject(id, .disabled) }
        if case .unavailable(let reason) = availability { return reject(id, .unavailable(reason)) }
        guard let prompt = ReplySanitizer.prompt(text, limit: policy.maximumPromptCharacters) else {
            return reject(id, .emptyPrompt)
        }
        acceptedRequestTimes.removeAll { at.seconds - $0.seconds >= 60 || $0 > at }
        guard acceptedRequestTimes.count < policy.maximumTurnsPerMinute else { return reject(id, .busy) }
        acceptedRequestTimes.append(at)

        var effects: [Effect] = []
        if case .attending = phase { effects.append(.cancel(.attentionTimeout)) }
        effects += expireIfStale(at)
        effects += ensureSession()
        effects += beginPresence()
        let turn = Turn(id: id, prompt: prompt, attempt: 1, plainText: false)
        phase = .responding(turn)
        effects += [.cancel(.purge), .startTurn(turn)]
        return effects
    }

    /// Refuses before any model work. Only ending attention changes anything else:
    /// the pet is released, and a purge deferred while listening is restored.
    private mutating func reject(_ id: ConversationRequestID, _ failure: ConversationFailure) -> [Effect] {
        var effects: [Effect] = []
        if case .attending = phase {
            phase = .idle
            effects.append(.cancel(.attentionTimeout))
            effects += endPresence(.none)
            effects += schedulePurgeIfNeeded()
        }
        effects.append(.deliver(id, .failure(failure)))
        return effects
    }

    private mutating func replied(_ id: ConversationRequestID, _ draft: ReplyDraft, at: MonotonicTimestamp) -> [Effect] {
        guard case .responding(let turn) = phase, turn.id == id else { return [] }
        guard let spoken = ReplySanitizer.spoken(draft.spokenText, limit: policy.maximumReplyCharacters) else {
            return failed(turn, .unknown, at: at)
        }
        phase = .idle
        history.append(ConversationTurn(prompt: turn.prompt, reply: spoken, at: at), limit: policy.maximumTurns)
        lastActivity = at
        var effects = settleSessionAfterTurn()
        effects += endPresence(draft.gesture)
        effects += schedulePurgeIfNeeded()
        effects.append(.deliver(id, .reply(ReplyDraft(spokenText: spoken, gesture: draft.gesture))))
        return effects
    }

    private mutating func failed(_ turn: Turn, _ failure: ConversationFailure, at: MonotonicTimestamp) -> [Effect] {
        switch failure {
        case .contextOverflow where turn.attempt == 1:
            // Rebuild with a short carry-over and try the same question once more.
            hasSession = false
            invalidateAfterTurn = false
            let retry = Turn(id: turn.id, prompt: turn.prompt, attempt: 2, plainText: turn.plainText)
            phase = .responding(retry)
            return ensureSession() + [.startTurn(retry)]
        case .unknown where turn.attempt == 1 && !turn.plainText:
            // A malformed structured reply retries once as plain text.
            let retry = Turn(id: turn.id, prompt: turn.prompt, attempt: 2, plainText: true)
            phase = .responding(retry)
            return [.startTurn(retry)]
        default:
            return endTurn(turn, failure: failure, at: at)
        }
    }

    /// Ends a turn without a reply. The session is discarded because its
    /// transcript may hold a refused, partial, or oversized exchange.
    private mutating func endTurn(_ turn: Turn, failure: ConversationFailure, at: MonotonicTimestamp?) -> [Effect] {
        phase = .idle
        invalidateAfterTurn = false
        var effects = discardSessionIfPresent()
        if failure == .contextOverflow {
            history = ConversationHistory()
            lastActivity = nil
            effects.append(.cancel(.purge))
        } else if failure == .declined, let at, !history.isEmpty {
            lastActivity = at
        }
        effects += endPresence(.none)
        effects += schedulePurgeIfNeeded()
        effects.append(.deliver(turn.id, .failure(failure)))
        return effects
    }

    // MARK: Deadlines and forgetting

    private mutating func deadline(_ key: ConversationDeadline, at: MonotonicTimestamp) -> [Effect] {
        switch key {
        case .attentionTimeout:
            guard case .attending(let id, let since) = phase else { return [] }
            let due = adding(policy.attentionTimeoutSeconds, to: since)
            guard at >= due else { return [.schedule(.attentionTimeout, at: due)] }
            return attentionEnded(id)
        case .purge:
            guard case .idle = phase, let lastActivity else { return [] }
            let due = adding(policy.idlePurgeSeconds, to: lastActivity)
            guard at >= due else { return [.schedule(.purge, at: due)] }
            return forget()
        }
    }

    private mutating func forget() -> [Effect] {
        var effects: [Effect] = []
        var interrupted: Turn?
        switch phase {
        case .responding(let turn):
            interrupted = turn
            effects.append(.cancelTurn)
        case .attending:
            effects.append(.cancel(.attentionTimeout))
        case .idle:
            break
        }
        phase = .idle
        history = ConversationHistory()
        lastActivity = nil
        invalidateAfterTurn = false
        effects += discardSessionIfPresent()
        effects.append(.cancel(.purge))
        effects += endPresence(.none)
        if let interrupted { effects.append(.deliver(interrupted.id, .failure(.cancelled))) }
        return effects
    }

    /// A purge deadline still pending afterwards is harmless: with no activity it does nothing.
    private mutating func expireIfStale(_ at: MonotonicTimestamp) -> [Effect] {
        guard let lastActivity, at >= adding(policy.idlePurgeSeconds, to: lastActivity) else { return [] }
        history = ConversationHistory()
        self.lastActivity = nil
        return discardSessionIfPresent()
    }

    // MARK: Helpers

    private mutating func ensureSession() -> [Effect] {
        guard !hasSession else { return [] }
        hasSession = true
        return [.prepareSession(carryOver: history.carryOver(policy.carryOverTurns))]
    }

    private mutating func discardSessionIfPresent() -> [Effect] {
        guard hasSession else { return [] }
        hasSession = false
        return [.discardSession]
    }

    private mutating func settleSessionAfterTurn() -> [Effect] {
        guard invalidateAfterTurn else { return [] }
        invalidateAfterTurn = false
        return discardSessionIfPresent()
    }

    private mutating func beginPresence() -> [Effect] {
        guard !isPresenceActive else { return [] }
        isPresenceActive = true
        return [.presenceBegan]
    }

    private mutating func endPresence(_ gesture: CompanionGesture) -> [Effect] {
        guard isPresenceActive else { return [] }
        isPresenceActive = false
        return [.presenceEnded(gesture)]
    }

    private func schedulePurgeIfNeeded() -> [Effect] {
        guard case .idle = phase, !history.isEmpty, let lastActivity else { return [] }
        return [.schedule(.purge, at: adding(policy.idlePurgeSeconds, to: lastActivity))]
    }

    private func adding(_ seconds: Double, to timestamp: MonotonicTimestamp) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: timestamp.seconds + seconds) ?? timestamp
    }
}
