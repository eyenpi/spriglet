# Spriglet Core

Spriglet keeps behavior and geometry independent of the AppKit window and rendering layers. The package uses Swift value types and owns no event monitor, timer, display link, file writer, or network client.

## World and behavior

`PetStimulus` carries one semantic fact with a `MonotonicTimestamp`. `WorldReducer` returns an immutable `PetWorldSnapshot`, rejects older events, and applies equal-time events in delivery order. Suspension causes accumulate independently, so display wake cannot override a user pause or an inactive session. `WorldReducer.replay` accepts a finite sequence supplied by a test; the app retains only its current snapshot.

`BehaviorDirector` separates planning from execution feedback. `LegacyBehaviorDirector` preserves the existing planner's seeded selection, delays, quiet periods, and movement cooldowns. The runtime keeps one cancellable deadline and checks policy again when it fires. Direct interactions retain the renderer's one-current/one-pending request contract.

`HabitatProvider` supplies validated value geometry with a stable display UUID. The initial `ConservativeFloorHabitatProvider` delegates to `PetPlacement`, preserving existing placement at screen edges, negative display coordinates, and tight usable areas. The host rebuilds geometry from current screens rather than retaining `NSScreen` instances.

## Rendering boundary

`PetSceneRenderer` accepts commands and reports finite scene activity without exposing a platform view. The existing `PetRenderView` adapter retains the authored frame/root pairing, twelve-frame decode buffer, interruption semantics, and clock-free settled pose. The composition root connects the renderer's callbacks to the desktop host. Legacy clip identifiers remain an explicit migration boundary for existing character packages.

Platform notifications live in `AppKitEnvironmentSource`. Its typed observation tokens are released at stop; a generation guard rejects queued callbacks from an older lifetime. Wake and resource-policy listeners remain available while animation is suspended. There is no new polling or visible behavior in this foundation.

## Conversation

The `SprigletConversation` library holds the platform-independent part of optional conversation with the companion. It imports neither FoundationModels nor AppIntents; the app supplies a language-model adapter and the pet's presence through the `ConversationModel` and `CompanionPresence` protocols.

`ConversationEngine` is a pure reducer. It runs at most one turn at a time and delivers every request exactly once, including cancelled ones. Presence begin and end are strictly paired, and requests are rate-limited to twelve a minute. After a context overflow it retries once with a two-turn carry-over; after a malformed structured reply it retries once as plain text. `ConversationController` performs the engine's effects on the main actor, with one cancellable deadline per purpose.

Conversation text lives only in memory. `ConversationTurn` and `ConversationHistory` are deliberately not `Codable`. History is bounded to eight turns and forgotten after ten quiet minutes, on explicit forget, when conversation is disabled, and when the controller is told the system deactivated. `ConversationPreferencesStore` keeps one versioned choice under its own defaults key. That choice is off by default and cannot be written by review or validation launches. `CompanionPersona` derives instructions from the pet's name and stable traits. `ConversationGrounding` adds only the local weekday and part of day, whether the pet was napping, and a coarse recent-petting bucket. `GesturePolicy` maps semantic reactions onto existing authored routines, only when the pet may visibly act. `PetStimulus.Event.conversing` keeps autonomous behavior still during a conversation.

## Validation

Run `./scripts/test.sh` from the repository root. Tests replay environment traces, cover independent suspension causes and autonomy blockers, and compare the adapter's exact suggestions and feedback with the legacy planner. Habitat tests cover malformed and negative-coordinate geometry. Conversation tests cover:

- every engine transition, plus seeded event traces that check presence pairing and single delivery
- the controller, using a fake model, presence, and scheduler
- persona and grounding text, speakable-text sanitizing, and copy length
- gesture eligibility and preference recovery

None of them needs Apple Intelligence. Native lifecycle validation lives in [EnvironmentValidation](../../tools/EnvironmentValidation/README.md), with full runtime regressions in [EverydayExperienceValidation](../../tools/EverydayExperienceValidation/README.md) and [PersonalityValidation](../../tools/PersonalityValidation/README.md).

AppKit lifecycle integration uses current [NotificationCenter messages](https://developer.apple.com/documentation/foundation/notification-center-messages) and [NSWorkspace notifications](https://developer.apple.com/documentation/appkit/nsworkspace). App and harness builds enforce Swift 6 concurrency against the selected SDK, targeting macOS 26 or later.
