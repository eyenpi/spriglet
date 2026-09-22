# Spriglet Core

Spriglet keeps behavior and geometry independent of the AppKit window and rendering layers. The package uses Swift value types and owns no event monitor, timer, display link, file writer, or network client.

## World and behavior

`PetStimulus` carries one semantic fact with a `MonotonicTimestamp`. `WorldReducer` returns an immutable `PetWorldSnapshot`, rejects older events, and applies equal-time events in delivery order. Suspension causes accumulate independently, so display wake cannot override a user pause or an inactive session. `WorldReducer.replay` accepts a finite sequence supplied by a test; the app retains only its current snapshot.

`BehaviorDirector` separates planning from execution feedback. `LegacyBehaviorDirector` preserves the existing planner's seeded selection, delays, quiet periods, and movement cooldowns. The runtime keeps one cancellable deadline and checks policy again when it fires. Direct interactions retain the renderer's one-current/one-pending request contract.

`HabitatProvider` supplies validated value geometry with a stable display UUID. The initial `ConservativeFloorHabitatProvider` delegates to `PetPlacement`, preserving existing placement at screen edges, negative display coordinates, and tight usable areas. The host rebuilds geometry from current screens rather than retaining `NSScreen` instances.

## Rendering boundary

`PetSceneRenderer` accepts commands and reports finite scene activity without exposing a platform view. The existing `PetRenderView` adapter retains the authored frame/root pairing, twelve-frame decode buffer, interruption semantics, and clock-free settled pose. The composition root connects the renderer's callbacks to the desktop host. Legacy clip identifiers remain an explicit migration boundary for existing character packages.

Platform notifications live in `AppKitEnvironmentSource`. Its typed observation tokens are released at stop; a generation guard rejects queued callbacks from an older lifetime. Wake and resource-policy listeners remain available while animation is suspended. There is no new polling or visible behavior in this foundation.

## On-device intelligence

`SprigletIntelligence` is the one place Spriglet reaches Apple's on-device model, through FoundationModels. Unlike `SprigletCore`, it is a platform adapter.

`OnDeviceIntelligence.generate(_:instructions:prompt:)` turns input into one typed `@Generable` value in a fresh session and keeps nothing afterwards. There's no history and no chat. Capabilities use it to turn what a person shares into a structured action.

`unavailableReason` reports why the model can't run: an ineligible device, Apple Intelligence off, the model not ready, or an unsupported language. Every framework error becomes an `IntelligenceFailure`. On macOS 27, even macOS 26-style calls throw `LanguageModelError`, and only the pinned Xcode 27 SDK compiles that mapping. The tests build the framework's errors directly, so they don't need Apple Intelligence.

## Validation

Run `./scripts/test.sh` from the repository root. Tests replay environment traces, cover independent suspension causes and autonomy blockers, and compare the adapter's exact suggestions and feedback with the legacy planner. Habitat tests cover malformed and negative-coordinate geometry. Native lifecycle validation lives in [EnvironmentValidation](../../tools/EnvironmentValidation/README.md), with full runtime regressions in [EverydayExperienceValidation](../../tools/EverydayExperienceValidation/README.md) and [PersonalityValidation](../../tools/PersonalityValidation/README.md).

AppKit lifecycle integration uses current [NotificationCenter messages](https://developer.apple.com/documentation/foundation/notification-center-messages) and [NSWorkspace notifications](https://developer.apple.com/documentation/appkit/nsworkspace). App and harness builds enforce Swift 6 concurrency against the selected SDK, targeting macOS 26 or later.
