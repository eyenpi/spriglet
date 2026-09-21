import Foundation
import Testing
import SprigletCore
@testable import SprigletConversation

@Suite("Conversation engine")
struct ConversationEngineTests {
    private typealias Effect = ConversationEngine.Effect

    private func time(_ seconds: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(seconds: seconds)!
    }

    private func request(_ id: UInt64, _ text: String = "How are you?", at seconds: Double = 10,
                         enabled: Bool = true, availability: ModelAvailability = .available) -> ConversationEngine.Event {
        .request(ConversationRequestID(id), text: text, at: time(seconds), enabled: enabled, availability: availability)
    }

    private func reply(_ id: UInt64, _ text: String = "I'm cozy, thank you!", gesture: CompanionGesture = .cheerful,
                       at seconds: Double = 12) -> ConversationEngine.Event {
        .replied(ConversationRequestID(id), ReplyDraft(spokenText: text, gesture: gesture), at: time(seconds))
    }

    private func turn(_ id: UInt64, _ prompt: String = "How are you?", attempt: Int = 1, plainText: Bool = false) -> ConversationEngine.Turn {
        ConversationEngine.Turn(id: ConversationRequestID(id), prompt: prompt, attempt: attempt, plainText: plainText)
    }

    private func deliveries(_ effects: [Effect]) -> [ConversationRequestID] {
        effects.compactMap { if case let .deliver(id, _) = $0 { id } else { nil } }
    }

    @Test("Attention prepares a session, holds the pet, prewarms, and bounds how long it listens")
    func attentionBegins() {
        var engine = ConversationEngine()
        let effects = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        #expect(effects == [
            .prepareSession(carryOver: []),
            .presenceBegan,
            .prewarm,
            .schedule(.attentionTimeout, at: time(65))
        ])
        #expect(engine.phase == .attending(AttentionID(1), since: time(5)))
    }

    @Test("A request that will fail never wakes or holds the pet", arguments: [
        (false, ModelAvailability.available),
        (true, ModelAvailability.unavailable(.appleIntelligenceNotEnabled)),
        (true, ModelAvailability.unavailable(.deviceNotEligible))
    ])
    func attentionRefusedWhenUnusable(enabled: Bool, availability: ModelAvailability) {
        var engine = ConversationEngine()
        #expect(engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: enabled, availability: availability)).isEmpty)
        #expect(engine.phase == .idle)
        #expect(!engine.isPresenceActive)
    }

    @Test("A spoken question after attention starts one turn without re-preparing or re-waking")
    func requestAfterAttention() {
        var engine = ConversationEngine()
        _ = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        let effects = engine.handle(request(1, "  What should I\n cook tonight?  "))
        #expect(effects == [
            .cancel(.attentionTimeout),
            .cancel(.purge),
            .startTurn(turn(1, "What should I cook tonight?"))
        ])
    }

    @Test("A reply is sanitized, remembered, delivered once, and schedules one purge")
    func replyCompletesTurn() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        let effects = engine.handle(reply(1, "**Hello!** 🌰 I'm here.", gesture: .cheerful, at: 12))
        #expect(effects == [
            .presenceEnded(.cheerful),
            .schedule(.purge, at: time(612)),
            .deliver(ConversationRequestID(1), .reply(ReplyDraft(spokenText: "Hello! I'm here.", gesture: .cheerful)))
        ])
        #expect(engine.history.turns == [ConversationTurn(prompt: "How are you?", reply: "Hello! I'm here.", at: time(12))])
        #expect(engine.phase == .idle)
        #expect(!engine.isPresenceActive)
    }

    @Test("A request without prior attention wakes the pet itself")
    func requestWithoutAttention() {
        var engine = ConversationEngine()
        let effects = engine.handle(request(1))
        #expect(effects == [.prepareSession(carryOver: []), .presenceBegan, .cancel(.purge), .startTurn(turn(1))])
    }

    @Test("A second request while responding is refused without disturbing the turn")
    func busyWhileResponding() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        #expect(engine.handle(request(2, at: 11)) == [.deliver(ConversationRequestID(2), .failure(.busy))])
        #expect(engine.phase == .responding(turn(1)))
    }

    @Test("Disabled, unavailable, and empty requests fail before any model work", arguments: [
        (false, ModelAvailability.available, "Hi", ConversationFailure.disabled),
        (true, ModelAvailability.unavailable(.modelNotReady), "Hi", ConversationFailure.unavailable(.modelNotReady)),
        (true, ModelAvailability.available, " \n\t ", ConversationFailure.emptyPrompt)
    ])
    func rejectedRequests(enabled: Bool, availability: ModelAvailability, text: String, failure: ConversationFailure) {
        var engine = ConversationEngine()
        let effects = engine.handle(request(1, text, enabled: enabled, availability: availability))
        #expect(effects == [.deliver(ConversationRequestID(1), .failure(failure))])
        #expect(!engine.hasSession)
    }

    @Test("Rejecting a question ends the attention the pet was holding")
    func rejectionEndsAttention() {
        var engine = ConversationEngine()
        _ = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        let effects = engine.handle(request(1, ""))
        #expect(effects == [.cancel(.attentionTimeout), .presenceEnded(.none), .deliver(ConversationRequestID(1), .failure(.emptyPrompt))])
        #expect(engine.phase == .idle)
    }

    @Test("Twelve turns a minute are accepted; the thirteenth waits for the window to pass")
    func rateLimit() {
        var engine = ConversationEngine()
        for index in 1...12 {
            let seconds = Double(index)
            _ = engine.handle(request(UInt64(index), at: seconds))
            _ = engine.handle(reply(UInt64(index), at: seconds + 0.5))
        }
        #expect(engine.handle(request(13, at: 30)) == [.deliver(ConversationRequestID(13), .failure(.busy))])
        let later = engine.handle(request(14, at: 61.5))
        #expect(later.contains(.startTurn(turn(14))))
    }

    @Test("Context overflow rebuilds with a short carry-over and retries once, then starts fresh")
    func overflowRecovery() {
        var engine = ConversationEngine()
        for index in 1...3 {
            _ = engine.handle(request(UInt64(index), "Question \(index)", at: Double(index * 10)))
            _ = engine.handle(reply(UInt64(index), "Answer \(index).", at: Double(index * 10 + 1)))
        }
        _ = engine.handle(request(4, "Question 4", at: 40))
        let retry = engine.handle(.failed(ConversationRequestID(4), .contextOverflow, at: time(41)))
        let carried = Array(engine.history.turns.suffix(2))
        #expect(retry == [.prepareSession(carryOver: carried), .startTurn(turn(4, "Question 4", attempt: 2))])

        let final = engine.handle(.failed(ConversationRequestID(4), .contextOverflow, at: time(42)))
        #expect(final == [
            .discardSession,
            .cancel(.purge),
            .presenceEnded(.none),
            .deliver(ConversationRequestID(4), .failure(.contextOverflow))
        ])
        #expect(engine.history.isEmpty)
        #expect(engine.lastActivity == nil)
    }

    @Test("A malformed structured reply retries once as plain text before failing")
    func plainTextRetry() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        #expect(engine.handle(.failed(ConversationRequestID(1), .unknown, at: time(11))) == [.startTurn(turn(1, attempt: 2, plainText: true))])
        let final = engine.handle(.failed(ConversationRequestID(1), .unknown, at: time(12)))
        #expect(final == [.discardSession, .presenceEnded(.none), .deliver(ConversationRequestID(1), .failure(.unknown))])
    }

    @Test("A reply with nothing speakable is treated like a malformed reply")
    func unspeakableReply() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        #expect(engine.handle(reply(1, "🌰✨ **")) == [.startTurn(turn(1, attempt: 2, plainText: true))])
    }

    @Test("A declined question discards the session and keeps the conversation alive")
    func declinedTurn() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        _ = engine.handle(reply(1, at: 12))
        _ = engine.handle(request(2, "Something refused", at: 20))
        let effects = engine.handle(.failed(ConversationRequestID(2), .declined, at: time(21)))
        #expect(effects == [
            .discardSession,
            .presenceEnded(.none),
            .schedule(.purge, at: time(621)),
            .deliver(ConversationRequestID(2), .failure(.declined))
        ])
        #expect(engine.history.turns.count == 1)
        let next = engine.handle(request(3, "Tell me a joke", at: 30))
        #expect(next.first == .prepareSession(carryOver: engine.history.turns))
    }

    @Test("Cancelling a turn delivers once, and its late reply is ignored")
    func cancellation() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        let effects = engine.handle(.cancelRequest(ConversationRequestID(1)))
        #expect(effects == [.cancelTurn, .discardSession, .presenceEnded(.none), .deliver(ConversationRequestID(1), .failure(.cancelled))])
        #expect(engine.handle(reply(1)).isEmpty)
        #expect(engine.handle(.cancelRequest(ConversationRequestID(1))).isEmpty)
        #expect(engine.history.isEmpty)
    }

    @Test("Forgetting mid-turn cancels it, delivers once, and leaves nothing behind")
    func forgetWhileResponding() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        _ = engine.handle(reply(1))
        _ = engine.handle(request(2, at: 20))
        let effects = engine.handle(.forget)
        #expect(effects == [
            .cancelTurn,
            .discardSession,
            .cancel(.purge),
            .presenceEnded(.none),
            .deliver(ConversationRequestID(2), .failure(.cancelled))
        ])
        #expect(engine.history.isEmpty)
        #expect(!engine.hasSession)
        #expect(engine.handle(reply(2, at: 22)).isEmpty)
    }

    @Test("Forgetting while listening releases the pet")
    func forgetWhileAttending() {
        var engine = ConversationEngine()
        _ = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        #expect(engine.handle(.forget) == [.cancel(.attentionTimeout), .discardSession, .cancel(.purge), .presenceEnded(.none)])
        #expect(engine.phase == .idle)
    }

    @Test("The purge deadline forgets exactly after ten quiet minutes")
    func purgeDeadline() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        _ = engine.handle(reply(1, at: 12))
        #expect(engine.handle(.deadline(.purge, at: time(300))) == [.schedule(.purge, at: time(612))])
        let effects = engine.handle(.deadline(.purge, at: time(612)))
        #expect(effects == [.discardSession, .cancel(.purge)])
        #expect(engine.history.isEmpty)
    }

    @Test("A purge deadline during a turn waits for the turn to finish")
    func purgeDuringTurn() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        _ = engine.handle(reply(1, at: 12))
        _ = engine.handle(request(2, at: 600))
        #expect(engine.handle(.deadline(.purge, at: time(612))).isEmpty)
        #expect(engine.handle(reply(2, at: 613)).contains(.schedule(.purge, at: time(1213))))
        #expect(engine.history.turns.count == 2)
    }

    @Test("A stale conversation is forgotten before the next question uses it")
    func staleHistoryExpiresOnRequest() {
        var engine = ConversationEngine()
        _ = engine.handle(request(1))
        _ = engine.handle(reply(1, at: 12))
        let effects = engine.handle(request(2, at: 700))
        #expect(effects == [
            .discardSession,
            .prepareSession(carryOver: []),
            .presenceBegan,
            .cancel(.purge),
            .startTurn(turn(2))
        ])
        #expect(engine.history.isEmpty)
    }

    @Test("Listening ends by itself if the surface never asks")
    func attentionTimeout() {
        var engine = ConversationEngine()
        _ = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        #expect(engine.handle(.deadline(.attentionTimeout, at: time(30))) == [.schedule(.attentionTimeout, at: time(65))])
        #expect(engine.handle(.deadline(.attentionTimeout, at: time(65))) == [.cancel(.attentionTimeout), .presenceEnded(.none)])
        #expect(engine.phase == .idle)
    }

    @Test("A stale attention identifier cannot end newer attention")
    func staleAttentionEnd() {
        var engine = ConversationEngine()
        _ = engine.handle(.attentionBegan(AttentionID(1), at: time(5), enabled: true, availability: .available))
        _ = engine.handle(.attentionBegan(AttentionID(2), at: time(6), enabled: true, availability: .available))
        #expect(engine.handle(.attentionEnded(AttentionID(1))).isEmpty)
        #expect(engine.isPresenceActive)
    }

    @Test("History keeps only the newest turns")
    func boundedHistory() {
        var engine = ConversationEngine(policy: ConversationPolicy(maximumTurns: 3, maximumTurnsPerMinute: 100))
        for index in 1...5 {
            _ = engine.handle(request(UInt64(index), "Q\(index)", at: Double(index)))
            _ = engine.handle(reply(UInt64(index), "A\(index).", at: Double(index) + 0.5))
        }
        #expect(engine.history.turns.map(\.prompt) == ["Q3", "Q4", "Q5"])
    }

    @Test("A changed companion refreshes instructions now, or after the current turn")
    func companionChanged() {
        var idle = ConversationEngine()
        _ = idle.handle(request(1))
        _ = idle.handle(reply(1))
        #expect(idle.handle(.companionChanged) == [.discardSession])
        #expect(idle.handle(request(2, at: 20)).first == .prepareSession(carryOver: idle.history.turns))

        var busy = ConversationEngine()
        _ = busy.handle(request(1))
        #expect(busy.handle(.companionChanged).isEmpty)
        #expect(busy.handle(reply(1)).first == .discardSession)
    }

    @Test("Under arbitrary event orders, presence stays paired and each request is delivered at most once")
    func pairingInvariants() {
        var generator = SplitMix(seed: 0x5EED)
        for _ in 0..<300 {
            var engine = ConversationEngine()
            var presenceDepth = 0
            var delivered: [ConversationRequestID: Int] = [:]
            var issued: [UInt64] = []
            var clock = 1.0
            for _ in 0..<40 {
                clock += Double(generator.next() % 400) / 10
                let id = UInt64(generator.next() % 6) + 1
                let failures: [ConversationFailure] = [.contextOverflow, .unknown, .declined, .busy]
                let event: ConversationEngine.Event
                switch generator.next() % 9 {
                case 0: event = .attentionBegan(AttentionID(id), at: time(clock), enabled: generator.next() % 5 != 0, availability: .available)
                case 1: event = .attentionEnded(AttentionID(id))
                case 2, 3:
                    issued.append(id)
                    event = request(id, "Question \(id)", at: clock)
                case 4: event = reply(id, "Answer.", at: clock)
                case 5: event = .failed(ConversationRequestID(id), failures[Int(generator.next() % 4)], at: time(clock))
                case 6: event = .cancelRequest(ConversationRequestID(id))
                case 7: event = .deadline(generator.next() % 2 == 0 ? .purge : .attentionTimeout, at: time(clock))
                default: event = .forget
                }
                for effect in engine.handle(event) {
                    switch effect {
                    case .presenceBegan: presenceDepth += 1
                    case .presenceEnded: presenceDepth -= 1
                    case .deliver(let id, _): delivered[id, default: 0] += 1
                    default: break
                    }
                    #expect((0...1).contains(presenceDepth))
                }
                if case .responding = engine.phase { #expect(engine.isPresenceActive) }
            }
            for effect in engine.handle(.forget) {
                if case .presenceEnded = effect { presenceDepth -= 1 }
                if case .deliver(let id, _) = effect { delivered[id, default: 0] += 1 }
            }
            #expect(presenceDepth == 0)
            #expect(engine.history.isEmpty && engine.phase == .idle && !engine.hasSession)
            // Identifiers are reused by this generator, so each may be delivered once per issue.
            for (id, count) in delivered {
                #expect(count <= issued.filter { $0 == id.value }.count)
            }
        }
    }
}

/// Deterministic, dependency-free generator for replaying the same traces.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
