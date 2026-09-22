import Foundation
import Testing
import SprigletCore
@testable import SprigletConversation

@Suite("Conversation controller")
@MainActor
struct ConversationControllerTests {
    @Test("Conversation starts off and never reaches the model or the pet while off")
    func offByDefault() async throws {
        let harness = try Harness()
        #expect(!harness.controller.isEnabled)
        let attention = harness.controller.beginAttention(surface: .siri)
        let outcome = await harness.controller.send(ConversationRequest(text: "Hello", surface: .siri))
        harness.controller.endAttention(attention)
        #expect(outcome == .failure(.disabled))
        #expect(harness.model.prompts.isEmpty)
        #expect(harness.model.preparedInstructions.isEmpty)
        #expect(harness.presence.events.isEmpty)
    }

    @Test("Enabling is an explicit, persisted choice; review copies cannot enable it")
    func enablingPersists() throws {
        try withIsolatedDefaults { defaults in
            let harness = Harness(defaults: defaults)
            harness.controller.setEnabled(true)
            #expect(harness.controller.isEnabled)
            #expect(ConversationPreferencesStore(defaults: defaults).load().isEnabled)

            let review = Harness(defaults: defaults, allowsChanges: false)
            review.controller.setEnabled(false)
            #expect(review.controller.isEnabled)
            #expect(ConversationPreferencesStore(defaults: defaults).load().isEnabled)
        }
    }

    @Test("A Siri turn holds the pet, answers in character, then gives the chosen gesture")
    func happyPath() async throws {
        let harness = try Harness(enabled: true)
        harness.presence.conversationSnapshot = CompanionSnapshot(
            profile: PetProfile(name: "Pip"), isSleeping: true, recentAffection: 0.6)
        harness.model.script = [.success(ReplyDraft(spokenText: "I'd love a cozy soup!", gesture: .cheerful))]

        let attention = harness.controller.beginAttention(surface: .siri)
        #expect(harness.controller.phase == .listening)
        #expect(harness.model.prewarmCount == 1)
        #expect(harness.presence.events == ["begin"])

        let outcome = await harness.controller.send(ConversationRequest(text: "What should I cook?", surface: .siri))
        #expect(outcome == .reply(ReplyDraft(spokenText: "I'd love a cozy soup!", gesture: .cheerful)))
        #expect(harness.presence.events == ["begin", "end:cheerful"])
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.hasHistory)
        #expect(harness.model.prompts.map(\.prompt) == ["What should I cook?"])
        #expect(harness.scheduler.pending[.purge] != nil)
        #expect(harness.scheduler.pending[.attentionTimeout] == nil)

        let instructions = try #require(harness.model.preparedInstructions.first)
        #expect(instructions.contains("You are \"Pip\""))
        #expect(instructions.contains("You were napping and just woke up to talk."))
        #expect(instructions.contains("feel especially loved"))
        #expect(instructions.contains("Right now it is Monday evening."))
        harness.controller.endAttention(attention)
        #expect(harness.presence.events.count == 2)
    }

    @Test("A declined question is answered in character rather than as an error")
    func declineIsAReply() async throws {
        let harness = try Harness(enabled: true)
        harness.model.script = [.failure(.declined)]
        let outcome = await harness.controller.send(ConversationRequest(text: "Something refused", surface: .shortcuts))
        #expect(outcome == .reply(ReplyDraft(spokenText: ConversationCopy.declineReply, gesture: .none)))
        #expect(harness.model.discardCount == 1)
    }

    @Test("Readiness is known before anyone is asked for a question")
    func readiness() throws {
        let off = try Harness()
        #expect(off.controller.readinessFailure() == .disabled)

        let unavailable = try Harness(enabled: true)
        unavailable.model.availability = .unavailable(.appleIntelligenceNotEnabled)
        #expect(unavailable.controller.readinessFailure() == .unavailable(.appleIntelligenceNotEnabled))
        #expect(unavailable.controller.availability == .unavailable(.appleIntelligenceNotEnabled))

        let ready = try Harness(enabled: true)
        #expect(ready.controller.readinessFailure() == nil)
        #expect(ready.presence.events.isEmpty)
        #expect(ready.model.prewarmCount == 0)
    }

    @Test("Each unavailable reason is reported without calling the model", arguments: ModelUnavailableReason.allCases)
    func unavailable(reason: ModelUnavailableReason) async throws {
        let harness = try Harness(enabled: true)
        harness.model.availability = .unavailable(reason)
        let outcome = await harness.controller.send(ConversationRequest(text: "Hi", surface: .siri))
        #expect(outcome == .failure(.unavailable(reason)))
        #expect(harness.controller.availability == .unavailable(reason))
        #expect(harness.model.prompts.isEmpty)
    }

    @Test("Only one turn runs at a time")
    func busy() async throws {
        let harness = try Harness(enabled: true)
        harness.model.holdsResponses = true
        let first = Task { await harness.controller.send(ConversationRequest(text: "First", surface: .siri)) }
        try await waitUntil { harness.model.heldCount == 1 }
        #expect(harness.controller.phase == .thinking)

        let second = await harness.controller.send(ConversationRequest(text: "Second", surface: .panel))
        #expect(second == .failure(.busy))

        harness.model.releaseHeld(.success(ReplyDraft(spokenText: "Done.", gesture: .none)))
        #expect(await first.value == .reply(ReplyDraft(spokenText: "Done.", gesture: .none)))
        #expect(harness.model.prompts.map(\.prompt) == ["First"])
    }

    @Test("A cancelled caller gets one outcome and the pet is released")
    func callerCancellation() async throws {
        let harness = try Harness(enabled: true)
        harness.model.holdsResponses = true
        let task = Task { await harness.controller.send(ConversationRequest(text: "Wait", surface: .siri)) }
        try await waitUntil { harness.model.heldCount == 1 }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
        #expect(harness.presence.events == ["begin", "end:none"])
        #expect(harness.controller.phase == .idle)
        harness.model.releaseHeld(.success(ReplyDraft(spokenText: "Too late.", gesture: .cheerful)))
        try await waitUntil { harness.model.heldCount == 0 }
        #expect(!harness.controller.hasHistory)
    }

    @Test("Forget, deactivation, and disabling all erase the conversation", arguments: [0, 1, 2])
    func erasure(trigger: Int) async throws {
        let harness = try Harness(enabled: true)
        _ = await harness.controller.send(ConversationRequest(text: "Remember this?", surface: .siri))
        #expect(harness.controller.hasHistory)
        switch trigger {
        case 0: harness.controller.forget()
        case 1: harness.controller.systemDidDeactivate()
        default: harness.controller.setEnabled(false)
        }
        #expect(!harness.controller.hasHistory)
        #expect(harness.model.discardCount == 1)
        #expect(harness.scheduler.pending.isEmpty)
    }

    @Test("Disabling mid-turn cancels the waiting request")
    func disableWhileThinking() async throws {
        let harness = try Harness(enabled: true)
        harness.model.holdsResponses = true
        let task = Task { await harness.controller.send(ConversationRequest(text: "Hmm", surface: .siri)) }
        try await waitUntil { harness.model.heldCount == 1 }
        harness.controller.setEnabled(false)
        #expect(await task.value == .failure(.cancelled))
        harness.model.releaseHeld(.success(ReplyDraft(spokenText: "Ignored.", gesture: .none)))
    }

    @Test("Ten quiet minutes forget the conversation through the single purge deadline")
    func idlePurge() async throws {
        let harness = try Harness(enabled: true)
        _ = await harness.controller.send(ConversationRequest(text: "Hello", surface: .siri))
        let deadline = try #require(harness.scheduler.pending[.purge]?.deadline)
        #expect(deadline.seconds == harness.time.seconds + 600)
        harness.time.seconds += 600
        harness.scheduler.fire(.purge)
        #expect(!harness.controller.hasHistory)
        #expect(harness.scheduler.pending.isEmpty)
    }

    @Test("A continued conversation reuses one session; a renamed companion gets fresh instructions")
    func sessionReuse() async throws {
        let harness = try Harness(enabled: true)
        _ = await harness.controller.send(ConversationRequest(text: "One", surface: .siri))
        _ = await harness.controller.send(ConversationRequest(text: "Two", surface: .siri))
        #expect(harness.model.preparedInstructions.count == 1)

        harness.presence.conversationSnapshot = CompanionSnapshot(profile: PetProfile(name: "Moss"), isSleeping: false, recentAffection: 0)
        harness.controller.companionDidChange()
        _ = await harness.controller.send(ConversationRequest(text: "Three", surface: .siri))
        #expect(harness.model.preparedInstructions.count == 2)
        let refreshed = try #require(harness.model.preparedInstructions.last)
        #expect(refreshed.contains("You are \"Moss\""))
        #expect(refreshed.contains("Earlier in this conversation:"))
    }

    // MARK: Support

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition was not met")
        throw CancellationError()
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "dev.spriglet.tests.conversation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

@MainActor
private final class Harness {
    let model = FakeModel()
    let presence = FakePresence()
    let scheduler = ManualScheduler()
    let time = TestTime()
    let controller: ConversationController
    /// Owned temporary defaults domain, removed when the harness ends.
    private let ownedSuiteName: String?

    init(enabled: Bool = false) throws {
        let suiteName = "dev.spriglet.tests.conversation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        ownedSuiteName = suiteName
        if enabled { ConversationPreferencesStore(defaults: defaults).save(ConversationPreferences(isEnabled: true)) }
        controller = Self.makeController(model: model, presence: presence, scheduler: scheduler, time: time,
                                         store: ConversationPreferencesStore(defaults: defaults))
    }

    init(defaults: UserDefaults, allowsChanges: Bool = true) {
        ownedSuiteName = nil
        controller = Self.makeController(model: model, presence: presence, scheduler: scheduler, time: time,
                                         store: ConversationPreferencesStore(defaults: defaults, allowsChanges: allowsChanges))
    }

    deinit {
        if let ownedSuiteName { UserDefaults(suiteName: ownedSuiteName)?.removePersistentDomain(forName: ownedSuiteName) }
    }

    private static func makeController(model: FakeModel, presence: FakePresence, scheduler: ManualScheduler,
                                       time: TestTime, store: ConversationPreferencesStore) -> ConversationController {
        // Monday 21 September 2026, 18:30 UTC.
        let wall = Date(timeIntervalSince1970: 1_790_015_400)
        let clock = ConversationClock(
            monotonicNow: { MonotonicTimestamp(seconds: time.seconds)! },
            wallNow: { wall },
            timeZone: { TimeZone(identifier: "UTC")! }
        )
        return ConversationController(model: model, presence: presence, store: store, scheduler: scheduler, clock: clock)
    }
}

final class TestTime: @unchecked Sendable {
    var seconds: Double = 100
}

@MainActor
final class FakeModel: ConversationModel {
    var availability: ModelAvailability = .available
    var script: [Result<ReplyDraft, ConversationFailure>] = []
    var holdsResponses = false
    private(set) var preparedInstructions: [String] = []
    struct Prompt: Equatable {
        let prompt: String
        let plainText: Bool
    }

    private(set) var prompts: [Prompt] = []
    private(set) var prewarmCount = 0
    private(set) var discardCount = 0
    private var held: [CheckedContinuation<Result<ReplyDraft, ConversationFailure>, Never>] = []

    var heldCount: Int { held.count }

    func prepareSession(instructions: String) { preparedInstructions.append(instructions) }
    func prewarm() { prewarmCount += 1 }
    func discardSession() { discardCount += 1 }

    func respond(to prompt: String, plainText: Bool, maximumResponseTokens: Int) async throws(ConversationFailure) -> ReplyDraft {
        prompts.append(Prompt(prompt: prompt, plainText: plainText))
        let result: Result<ReplyDraft, ConversationFailure>
        if holdsResponses {
            result = await withCheckedContinuation { held.append($0) }
        } else {
            result = script.isEmpty ? .success(ReplyDraft(spokenText: "Hello there.", gesture: .attentive)) : script.removeFirst()
        }
        return try result.get()
    }

    func releaseHeld(_ result: Result<ReplyDraft, ConversationFailure>) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: result)
    }
}

@MainActor
final class FakePresence: CompanionPresence {
    var conversationSnapshot = CompanionSnapshot(profile: PetProfile(name: "Pip"), isSleeping: false, recentAffection: 0)
    private(set) var events: [String] = []

    func conversationAttentionBegan() { events.append("begin") }
    func conversationAttentionEnded(with gesture: CompanionGesture) { events.append("end:\(gesture.rawValue)") }
}

@MainActor
final class ManualScheduler: ConversationScheduling {
    private(set) var pending: [ConversationDeadline: (deadline: MonotonicTimestamp, action: @MainActor () -> Void)] = [:]

    func schedule(_ key: ConversationDeadline, at deadline: MonotonicTimestamp, _ action: @escaping @MainActor () -> Void) {
        pending[key] = (deadline, action)
    }

    func cancel(_ key: ConversationDeadline) { pending[key] = nil }

    func fire(_ key: ConversationDeadline) {
        pending.removeValue(forKey: key)?.action()
    }
}
