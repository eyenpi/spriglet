import Foundation
import Observation
import SprigletCore

/// The single conversation host. Every surface (Siri and Shortcuts now, a panel
/// later) calls this object, so there is one history, one policy, and one place
/// where model output becomes an effect.
@MainActor @Observable
public final class ConversationController {
    public enum Phase: Equatable, Sendable {
        case idle, listening, thinking
    }

    public private(set) var isEnabled: Bool
    public private(set) var availability: ModelAvailability
    public private(set) var phase: Phase = .idle
    public private(set) var hasHistory = false

    @ObservationIgnored private var engine: ConversationEngine
    @ObservationIgnored private let model: any ConversationModel
    @ObservationIgnored private let presence: any CompanionPresence
    @ObservationIgnored private let store: ConversationPreferencesStore
    @ObservationIgnored private let scheduler: any ConversationScheduling
    @ObservationIgnored private let clock: ConversationClock
    @ObservationIgnored private var waiting: [ConversationRequestID: CheckedContinuation<ConversationOutcome, Never>] = [:]
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var turnGeneration: UInt64 = 0
    @ObservationIgnored private var nextIdentifier: UInt64 = 0

    public init(model: any ConversationModel, presence: any CompanionPresence,
                store: ConversationPreferencesStore, scheduler: (any ConversationScheduling)? = nil,
                policy: ConversationPolicy = .standard, clock: ConversationClock = .system) {
        self.model = model
        self.presence = presence
        self.store = store
        self.scheduler = scheduler ?? TaskConversationScheduler(now: clock.monotonicNow)
        self.clock = clock
        engine = ConversationEngine(policy: policy)
        isEnabled = store.load().isEnabled
        availability = model.availability
    }

    public var companionName: String { presence.conversationSnapshot.profile.name }
    public var allowsChanges: Bool { store.allowsChanges }

    /// Only an explicit Settings choice calls this. Turning off forgets immediately.
    public func setEnabled(_ value: Bool) {
        guard value != isEnabled, store.save(ConversationPreferences(isEnabled: value)) else { return }
        isEnabled = value
        if !value { forget() }
        refreshAvailability()
    }

    /// Reads the model's state on demand; nothing polls.
    public func refreshAvailability() {
        let current = model.availability
        if current != availability { availability = current }
    }

    /// Why any request would fail before model work, or nil when ready. Surfaces
    /// check this first so nobody is asked a question that cannot be answered.
    public func readinessFailure() -> ConversationFailure? {
        refreshAvailability()
        guard isEnabled else { return .disabled }
        if case .unavailable(let reason) = availability { return .unavailable(reason) }
        return nil
    }

    /// Called when a surface starts waiting for the person to speak or type.
    public func beginAttention(surface: ConversationSurface) -> AttentionID {
        let id = AttentionID(mintIdentifier())
        refreshAvailability()
        apply(engine.handle(.attentionBegan(id, at: clock.monotonicNow(), enabled: isEnabled, availability: availability)))
        return id
    }

    public func endAttention(_ id: AttentionID) {
        apply(engine.handle(.attentionEnded(id)))
    }

    /// Always returns exactly one outcome, including when the caller is cancelled.
    public func send(_ request: ConversationRequest) async -> ConversationOutcome {
        let id = ConversationRequestID(mintIdentifier())
        refreshAvailability()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[id] = continuation
                apply(engine.handle(.request(id, text: request.text, at: clock.monotonicNow(),
                                             enabled: isEnabled, availability: availability)))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    public func forget() {
        apply(engine.handle(.forget))
    }

    /// Session inactive or system asleep: nothing said survives a lock or sleep.
    public func systemDidDeactivate() {
        forget()
    }

    /// The name or traits changed; the next turn uses fresh instructions.
    public func companionDidChange() {
        apply(engine.handle(.companionChanged))
    }

    // MARK: Effects

    private func cancel(_ id: ConversationRequestID) {
        apply(engine.handle(.cancelRequest(id)))
    }

    private func apply(_ effects: [ConversationEngine.Effect]) {
        for effect in effects {
            switch effect {
            case .prepareSession(let carryOver):
                prepareSession(carryingOver: carryOver)
            case .prewarm:
                model.prewarm()
            case .presenceBegan:
                presence.conversationAttentionBegan()
            case .presenceEnded(let gesture):
                presence.conversationAttentionEnded(with: gesture)
            case .startTurn(let turn):
                start(turn)
            case .cancelTurn:
                turnGeneration &+= 1
                turnTask?.cancel()
                turnTask = nil
            case let .deliver(id, outcome):
                waiting.removeValue(forKey: id)?.resume(returning: presentable(outcome))
            case let .schedule(key, deadline):
                scheduler.schedule(key, at: deadline) { [weak self] in self?.deadlineFired(key) }
            case .cancel(let key):
                scheduler.cancel(key)
            case .discardSession:
                model.discardSession()
            }
        }
        project()
    }

    private func prepareSession(carryingOver turns: [ConversationTurn]) {
        let companion = presence.conversationSnapshot
        let grounding = ConversationGrounding(date: clock.wallNow(), timeZone: clock.timeZone(), companion: companion)
        let instructions = CompanionPersona(profile: companion.profile).instructions(grounding: grounding, earlier: turns)
        model.prepareSession(instructions: instructions)
    }

    private func start(_ turn: ConversationEngine.Turn) {
        turnGeneration &+= 1
        let generation = turnGeneration
        let maximumTokens = engine.policy.maximumResponseTokens
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            let event: ConversationEngine.Event
            do throws(ConversationFailure) {
                let draft = try await model.respond(to: turn.prompt, plainText: turn.plainText,
                                                    maximumResponseTokens: maximumTokens)
                event = .replied(turn.id, draft, at: clock.monotonicNow())
            } catch {
                event = .failed(turn.id, error, at: clock.monotonicNow())
            }
            if generation == turnGeneration { turnTask = nil }
            apply(engine.handle(event))
        }
    }

    private func deadlineFired(_ key: ConversationDeadline) {
        apply(engine.handle(.deadline(key, at: clock.monotonicNow())))
    }

    /// A decline is an ordinary in-character answer, not an error.
    private func presentable(_ outcome: ConversationOutcome) -> ConversationOutcome {
        guard outcome == .failure(.declined) else { return outcome }
        return .reply(ReplyDraft(spokenText: ConversationCopy.declineReply, gesture: .none))
    }

    private func project() {
        let current: Phase = switch engine.phase {
        case .idle: .idle
        case .attending: .listening
        case .responding: .thinking
        }
        if phase != current { phase = current }
        if hasHistory == engine.history.isEmpty { hasHistory = !engine.history.isEmpty }
    }

    private func mintIdentifier() -> UInt64 {
        nextIdentifier &+= 1
        return nextIdentifier
    }
}
