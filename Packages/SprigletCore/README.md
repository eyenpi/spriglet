# Spriglet Core

Spriglet keeps behavior and geometry independent of the AppKit window and rendering layers. The package uses Swift value types and owns no event monitor, timer, display link, file writer, or network client.

## World and behavior

`PetStimulus` carries one semantic fact with a `MonotonicTimestamp`. `WorldReducer` returns an immutable `PetWorldSnapshot`, rejects older events, and applies equal-time events in delivery order. Suspension causes accumulate independently, so display wake cannot override a user pause or an inactive session. `WorldReducer.replay` accepts a finite sequence supplied by a test; the app retains only its current snapshot.

`BehaviorDirector` separates planning from execution feedback. `LegacyBehaviorDirector` preserves the existing planner's seeded selection, delays, quiet periods, and movement cooldowns. The runtime keeps one cancellable deadline and checks policy again when it fires. Direct interactions retain the renderer's one-current/one-pending request contract.

Pointer movement passes through `PointerPerception` and `PointerAttention` before
entering the world. These values retain only the newest ephemeral sample and
derived approach, dwell, and departure facts. `PointerIntentDirector` maps the
world to normalized gaze and lean commands after direct interaction, suspension,
and macro-animation policy checks. No coordinate is persisted or logged. Dwell
can mature while the pointer is still, using a semantic deadline rather than
polling. The native coordinator and autonomous behavior share one replaceable
earliest-deadline task. Event coalescing is capped at 15 Hz, or 10 Hz in Low Power.

`HabitatProvider` supplies validated value geometry with a stable display UUID. The initial `ConservativeFloorHabitatProvider` delegates to `PetPlacement`, preserving existing placement at screen edges, negative display coordinates, and tight usable areas. The host rebuilds geometry from current screens rather than retaining `NSScreen` instances.

## Rendering boundary

`CharacterPackage` validates schema 3 geometry, paths, capabilities, channel ranges,
parent relationships, pose routes, safe markers, and decoded resource budgets.
`CharacterClipID` is a validated string, so new characters and clips do not need
new enum cases. Schemas 1 and 2 adapt into the same model without changing their
timing or root motion. Unknown required features fail closed; explicitly optional
extensions can be ignored. `CharacterTimeline` pairs frames and exact root values,
including mixed frame rates, and `CharacterAnimationGraph` resolves finite routes
and semantic motion-policy fallbacks.

Acorn's schema-3 sidecar adds a small cropped rest rig. Stable layered poses and
finite baked clips have exclusive visual ownership. Blink, breath, and gaze
phrases use finite Core Animation animations; only baked frames use a display
link. The rig has no timer or idle loop. Autonomous continuous breathing is not
enabled without GPU/WindowServer energy evidence.

`PetSceneRenderer` accepts commands and reports finite scene activity without exposing a platform view. The existing `PetRenderView` adapter retains the authored frame/root pairing, twelve-frame decode buffer, interruption semantics, and clock-free settled pose. The composition root connects the renderer's callbacks to the desktop host. Legacy clip identifiers remain an explicit migration boundary for existing character packages.

Platform notifications live in `AppKitEnvironmentSource`. Its typed observation tokens are released at stop; a generation guard rejects queued callbacks from an older lifetime. Wake and resource-policy listeners remain available while animation is suspended. There is no new polling or visible behavior in this foundation.

## Validation

Run `./scripts/test.sh` from the repository root. Tests replay environment traces, cover independent suspension causes and autonomy blockers, and compare the adapter's exact suggestions and feedback with the legacy planner. Habitat tests cover malformed and negative-coordinate geometry. Native lifecycle validation lives in [EnvironmentValidation](../../tools/EnvironmentValidation/README.md), with full runtime regressions in [EverydayExperienceValidation](../../tools/EverydayExperienceValidation/README.md) and [PersonalityValidation](../../tools/PersonalityValidation/README.md).

AppKit lifecycle integration uses current [NotificationCenter messages](https://developer.apple.com/documentation/foundation/notification-center-messages) and [NSWorkspace notifications](https://developer.apple.com/documentation/appkit/nsworkspace). App and harness builds enforce Swift 6 concurrency against the selected SDK, targeting macOS 26 or later.
