import Foundation
import Testing
import SprigletCore
@testable import SprigletConversation

@Suite("Companion persona and grounding")
struct CompanionPersonaTests {
    private let utc = TimeZone(identifier: "UTC")!
    // Monday 21 September 2026, 00:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_789_948_800)

    private func grounding(hour: Int = 18, sleeping: Bool = false, affection: Double = 0) -> ConversationGrounding {
        ConversationGrounding(
            date: monday.addingTimeInterval(Double(hour) * 3_600),
            timeZone: utc,
            companion: CompanionSnapshot(profile: PetProfile(), isSleeping: sleeping, recentAffection: affection)
        )
    }

    @Test("Instructions name the companion, state its limits, and forbid invented perception")
    func coreInstructions() {
        let text = CompanionPersona(profile: PetProfile(name: "Pip")).instructions(grounding: grounding())
        #expect(text.hasPrefix("You are \"Pip\", a tiny, round acorn sprite"))
        #expect(text.contains("You cannot see the screen, read files or other apps, use the internet"))
        #expect(text.contains("first say plainly that you can't"))
        #expect(text.contains("Never claim to see, hear, or sense anything around the person, and don't guess or imagine what is around them either."))
        #expect(text.contains("don't give advice; kindly suggest talking with a trusted person or a professional."))
        #expect(text.contains("Answer everyday questions directly when you know the answer"))
        #expect(text.contains("Always reply in the same language as the person's message."))
        #expect(text.contains("Never use lists, headings, markdown, or emoji."))
        #expect(text.hasSuffix("Right now it is Monday evening. You are awake and resting nearby."))
        #expect(!text.contains("Earlier in this conversation"))
    }

    @Test("Every trait band produces its own temperament", arguments: [0.1, 0.5, 0.9])
    func temperamentBands(curiosity: Double) {
        var temperaments = Set<String>()
        for sociability in [0.1, 0.5, 0.9] {
            for playfulness in [0.1, 0.5, 0.9] {
                let traits = PetTraits(curiosity: curiosity, sociability: sociability, playfulness: playfulness)
                temperaments.insert(CompanionPersona(profile: PetProfile(traits: traits)).temperament)
            }
        }
        #expect(temperaments.count == 9)
    }

    @Test("Temperament uses the same thresholds as the visible trait summary")
    func temperamentMatchesSummary() {
        let persona = CompanionPersona(profile: PetProfile(traits: .sprout))
        #expect(persona.temperament == "curious, friendly, and gently playful")
        #expect(PetTraits.sprout.summary == "Curious, friendly, and gently playful.")
    }

    @Test("Quotes in a name cannot break out of the instruction's quoting")
    func quotedName() {
        let text = CompanionPersona(profile: PetProfile(name: "Mr \"Nut\"")).instructions(grounding: grounding())
        #expect(text.hasPrefix("You are \"Mr 'Nut'\""))
    }

    @Test("Carried-over turns are quoted, flattened, and bounded")
    func earlierTurns() {
        let long = String(repeating: "a", count: 250)
        let turns = [
            ConversationTurn(prompt: "Say \"hi\"", reply: "Hi!", at: MonotonicTimestamp(seconds: 1)!),
            ConversationTurn(prompt: long, reply: "Okay.", at: MonotonicTimestamp(seconds: 2)!)
        ]
        let text = CompanionPersona(profile: PetProfile()).instructions(grounding: grounding(), earlier: turns)
        let block = String(text.split(separator: "\n\n").last!)
        #expect(block.hasPrefix("Earlier in this conversation: They said \"Say 'hi'\" and you replied \"Hi!\"."))
        #expect(block.contains(String(repeating: "a", count: 200) + "…\""))
        #expect(!block.contains(String(repeating: "a", count: 201)))
    }

    @Test("Part of day changes at the documented hours", arguments: [
        (4, ConversationGrounding.PartOfDay.night), (5, .morning), (11, .morning), (12, .afternoon),
        (16, .afternoon), (17, .evening), (20, .evening), (21, .night), (0, .night)
    ])
    func partOfDay(hour: Int, expected: ConversationGrounding.PartOfDay) {
        #expect(grounding(hour: hour).partOfDay == expected)
    }

    @Test("Weekday follows the person's time zone, not UTC")
    func weekdayInTimeZone() {
        let tokyo = ConversationGrounding(
            date: monday.addingTimeInterval(20 * 3_600),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            companion: CompanionSnapshot(profile: PetProfile(), isSleeping: false, recentAffection: 0)
        )
        #expect(tokyo.weekday == "Tuesday")
        #expect(tokyo.partOfDay == .morning)
    }

    @Test("Only a coarse affection bucket reaches the model", arguments: [
        (0.0, ConversationGrounding.Affection.none), (0.14, .none), (0.15, .some), (0.49, .some), (0.5, .lots), (1.0, .lots),
        (Double.nan, .none), (7.0, .lots)
    ])
    func affectionBuckets(value: Double, expected: ConversationGrounding.Affection) {
        #expect(grounding(affection: value).affection == expected)
    }

    @Test("Napping and petting read naturally")
    func groundingSentence() {
        #expect(grounding(hour: 8, sleeping: true, affection: 0.3).sentence
            == "Right now it is Monday morning. You were napping and just woke up to talk. They petted you recently.")
    }
}

@Suite("Speakable text")
struct ReplySanitizerTests {
    @Test("Questions become one bounded line", arguments: [
        ("  Hello\n\nthere\t friend ", "Hello there friend"),
        ("a\u{0000}b", "a b"),
        ("\u{202E}right\u{200B}to\u{200D}left", "rightto\u{200D}left")
    ])
    func prompt(input: String, expected: String) {
        #expect(ReplySanitizer.prompt(input, limit: 100) == expected)
    }

    @Test("Empty and oversized questions are handled")
    func promptBounds() {
        #expect(ReplySanitizer.prompt(" \n ", limit: 10) == nil)
        #expect(ReplySanitizer.prompt(String(repeating: "x", count: 50), limit: 10)?.count == 10)
    }

    @Test("Markdown structure is removed for speech", arguments: [
        ("# Title\n- one\n- two", "Title one two"),
        ("**Bold** and __strong__ and `code`", "Bold and strong and code"),
        ("> Quote here", "Quote here"),
        ("1. First\n2) Second", "First Second"),
        ("See [the docs](https://example.com) now", "See the docs now")
    ])
    func markdown(input: String, expected: String) {
        #expect(ReplySanitizer.spoken(input, limit: 400) == expected)
    }

    @Test("Emoji are removed while ordinary symbols and scripts remain", arguments: [
        ("Hi 🌰!", "Hi!"),
        ("Sure 🌰 , friend", "Sure, friend"),
        ("Family 👨‍👩‍👧 time", "Family time"),
        ("Wave 👋🏽 hello", "Wave hello"),
        ("Flag 🇮🇷 here", "Flag here"),
        ("Keycap 1️⃣ gone, 1 stays", "Keycap gone, 1 stays"),
        ("Café #1 © 2026 — 你好", "Café #1 © 2026 — 你好")
    ])
    func emoji(input: String, expected: String) {
        #expect(ReplySanitizer.spoken(input, limit: 400) == expected)
    }

    @Test("Nothing speakable becomes nil")
    func unspeakable() {
        #expect(ReplySanitizer.spoken("🌰✨ ** -", limit: 400) == nil)
        #expect(ReplySanitizer.spoken("", limit: 400) == nil)
    }

    @Test("Long replies end at a sentence when one is near the limit")
    func sentenceCap() {
        let text = "First sentence is here. Second sentence runs on and on beyond the limit."
        #expect(ReplySanitizer.spoken(text, limit: 40) == "First sentence is here.")
    }

    @Test("Without a nearby sentence end, replies end at a word with an ellipsis")
    func wordCap() {
        let text = "one two three four five six seven eight nine ten"
        #expect(ReplySanitizer.spoken(text, limit: 20) == "one two three four…")
    }
}

@Suite("Conversation copy")
struct ConversationCopyTests {
    private let longestName = String(repeating: "W", count: PetProfile.maximumNameLength)

    @Test("Every failure has short, speakable copy", arguments: ConversationFailure.allCases)
    func failureCopy(failure: ConversationFailure) {
        let text = ConversationCopy.text(for: failure, name: longestName)
        #expect(!text.isEmpty)
        #expect(text.count <= 140)
        #expect(ReplySanitizer.spoken(text, limit: 400) == text)
    }

    @Test("Availability status names the reason in Settings")
    func status() {
        #expect(ConversationCopy.status(for: .available, name: "Pip") == "Ready")
        #expect(ConversationCopy.status(for: .unavailable(.appleIntelligenceNotEnabled), name: "Pip")
            == "Turn on Apple Intelligence in System Settings to talk with Pip.")
        #expect(ConversationCopy.questionPrompt(name: "Pip") == "What would you like to ask Pip?")
    }

    @Test("The unsigned-build notice is short and plain", arguments: [ConversationCopy.siriUnreachable, ConversationCopy.siriUnreachableDetail])
    func unreachableCopy(text: String) {
        #expect(text.count <= 140)
        #expect(ReplySanitizer.spoken(text, limit: 400) == text)
    }
}

@Suite("Conversation gestures")
struct GesturePolicyTests {
    private func world(_ event: PetStimulus.Event?, sleeping: Bool = false) -> PetWorldSnapshot {
        var snapshot = PetWorldSnapshot(isSleeping: sleeping)
        if let event {
            snapshot = WorldReducer.reduce(snapshot, PetStimulus(timestamp: MonotonicTimestamp(seconds: 1)!, event: event))
        }
        return snapshot
    }

    @Test("Gestures resolve to existing authored routines")
    func mapping() {
        let awake = world(nil)
        #expect(GesturePolicy.command(for: .none, in: awake) == nil)
        #expect(GesturePolicy.command(for: .attentive, in: awake) == .routine(.observe))
        #expect(GesturePolicy.command(for: .curious, in: awake) == .routine(.observe))
        #expect(GesturePolicy.command(for: .cheerful, in: awake) == .routine(.greet))
    }

    @Test("Attention wakes only a sleeping pet")
    func attention() {
        #expect(GesturePolicy.attentionCommand(in: world(nil, sleeping: true)) == .action(.wakeUp))
        #expect(GesturePolicy.attentionCommand(in: world(nil)) == nil)
    }

    @Test("No reaction when the pet may not visibly act", arguments: [
        PetStimulus.Event.suspension(reason: .userPaused, active: true),
        .suspension(reason: .hidden, active: true),
        .suspension(reason: .thermalPressure, active: true),
        .reduceMotion(true),
        .interaction(true),
        .activeSpace(false),
        .moving(true)
    ])
    func blocked(event: PetStimulus.Event) {
        #expect(GesturePolicy.command(for: .cheerful, in: world(event)) == nil)
        #expect(GesturePolicy.attentionCommand(in: world(event, sleeping: true)) == nil)
    }

    @Test("A pet still asleep is never greeted")
    func sleepingPetIsNotGreeted() {
        #expect(GesturePolicy.command(for: .cheerful, in: world(nil, sleeping: true)) == nil)
    }
}

@Suite("Conversation preferences")
@MainActor
struct ConversationPreferencesTests {
    @Test("An empty domain means off, without writing anything")
    func defaultOff() throws {
        try withIsolatedDefaults { defaults in
            #expect(!ConversationPreferencesStore(defaults: defaults).load().isEnabled)
            #expect(defaults.object(forKey: ConversationPreferencesStore.storageKey) == nil)
        }
    }

    @Test("The choice survives a new store and never touches pet preferences")
    func roundTrip() throws {
        try withIsolatedDefaults { defaults in
            #expect(ConversationPreferencesStore(defaults: defaults).save(ConversationPreferences(isEnabled: true)))
            #expect(ConversationPreferencesStore(defaults: defaults).load().isEnabled)
            #expect(defaults.object(forKey: "dev.spriglet.preferences") == nil)
        }
    }

    @Test("Damaged, future, and oversized payloads read as off", arguments: [
        Data("not json".utf8),
        Data(#"{"version":2,"preferences":{"isEnabled":true}}"#.utf8),
        Data(#"{"version":1,"preferences":{"isEnabled":"yes"}}"#.utf8),
        Data(repeating: 0x20, count: 5_000)
    ])
    func unreadable(data: Data) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(data, forKey: ConversationPreferencesStore.storageKey)
            #expect(!ConversationPreferencesStore(defaults: defaults).load().isEnabled)
            #expect(defaults.data(forKey: ConversationPreferencesStore.storageKey) == data)
        }
    }

    @Test("Review and validation copies cannot write")
    func readOnly() throws {
        try withIsolatedDefaults { defaults in
            let store = ConversationPreferencesStore(defaults: defaults, allowsChanges: false)
            #expect(!store.save(ConversationPreferences(isEnabled: true)))
            #expect(defaults.object(forKey: ConversationPreferencesStore.storageKey) == nil)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "dev.spriglet.tests.conversation-preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
