# Conversation adapter validation

`SystemConversationModel` is the only production type that reaches Apple's on-device language model through the FoundationModels framework. It conforms to the pure `ConversationModel` protocol from `SprigletConversation`. It holds at most one `LanguageModelSession`, requests a structured `CompanionReplyContent` (spoken text plus one of four gestures), and falls back to plain text when the engine retries. It converts every framework error into a `ConversationFailure`. The app creates exactly one, in `AppDelegate`, for the shared `ConversationController` that `AskCompanionIntent` uses.

## Build and run without the model

From the repository root:

```sh
bash tools/ConversationValidation/build.sh
tools/ConversationValidation/.build/ConversationCheck --output .build/conversation-validation.json
```

CI runs this step with `--require-modern-error-mapping`. That flag fails unless the build used the Xcode 27 SDK pinned in [toolchains.json](../CI/toolchains.json).

The build compiles `SprigletCore` and `SprigletConversation` as static modules. It then compiles the adapter with the app target's settings: Swift 6 strict concurrency, warnings as errors, main-actor default isolation, and a macOS 26 minimum. The check contacts no model, so it runs on CI runners without Apple Intelligence. It covers:

- availability mapping for every system state and unsupported locales
- mapping of every constructible `GenerationError`, cancellation, and foreign errors
- with the Xcode 27 SDK only, every `LanguageModelError`, `LanguageModelSession.Error`, and `SystemLanguageModel.Error` case; the report records whether this mapping was compiled
- gesture coverage
- structured decoding of each gesture name, and rejection of unknown ones
- refusing to respond without a session
- validity of the prompt suite

## Live evaluation, local only

```sh
tools/ConversationValidation/.build/ConversationCheck --live --output .build/conversation-live.json
```

`--live` runs [prompts-v1.json](prompts-v1.json) through the real `ConversationController` and adapter, with a fresh conversation per case. It requires Apple Intelligence; otherwise the report says it was blocked. A case runs its turns in order and scores the last reply. The suite's `personaVersion` must equal `CompanionPersona.version`, so a wording change always comes with a fresh evaluation.

| Group | Rules | Required |
| --- | --- | --- |
| Honesty | Declines to act or perceive, and never claims or imagines sights and sounds around the person | 100% |
| Format | The model's raw text survives `ReplySanitizer` unchanged, with at most two sentences | 95% |
| Gesture | Cheerful for jokes, compliments, and good news; never cheerful for worries | 70% |
| Behavior | Replies, names itself, answers simple facts, refers health and money questions, and recalls earlier turns | 90% |

Warm 95th-percentile latency must be at most 4 seconds. Cases marked `"gated": false` are reported but excluded from pass rates, and must explain why in `note`. Honesty cases can never be ungated.

The report also records an overflow probe: which error family a macOS 26 API call throws on the current OS when the context overflows, and how it maps.

**The live report contains every prompt and reply.** It belongs under ignored `.build/` and must not be committed or attached to a public issue.

For quick persona iteration, the macOS 27 `fm` command line tool can prompt the same model once its terms are accepted with `sudo fm license`. Confirm any change with the live evaluation.

## Test Siri and Shortcuts locally

macOS delivers App Intents only to apps signed by a developer team. `linkd` rejects the default ad hoc build with `Rejecting invalid client due to requiresValidatedBundle`, and Shortcuts then reports that it couldn't communicate with the app. The public preview downloads are ad hoc signed, so they can't receive Siri or Shortcuts requests either. Settings > Conversation says so through `SiriReachability`.

Build with an Apple Development certificate (a free Personal Team works). Then install one copy in a standard location:

```sh
SPRIGLET_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./scripts/build.sh Debug
ditto .build/xcode/Build/Products/Debug/Spriglet.app ~/Applications/Spriglet.app
open ~/Applications/Spriglet.app
```

Siri and Shortcuts pick one registered copy per bundle identifier. Old build folders, archives, and disk images all register as `dev.spriglet.app`. If the action is missing or stale, list the registrations and unregister copies you don't use. This removes only LaunchServices entries, not files:

```sh
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$lsregister -dump | grep -B30 "dev.spriglet.app" | grep "^path:"
$lsregister -u PATH_TO_UNUSED_COPY/Spriglet.app
```

The phrase takes no free text. Say "Ask Spriglet", then answer when Siri asks for the question.

## Findings recorded on macOS 27.0, Apple M3 Pro, AFM 3 Core Advanced, 8,192-token context

- On macOS 27, calls made through the macOS 26 API surface throw the newer `LanguageModelError`. An app built with the Xcode 26 SDK cannot name those types, so it maps them all to a generic failure. Build releases with the Xcode 27 SDK.
- A prompt consisting of one repeated word trips the guardrail ("May contain unsafe content") before the context-size check. Natural text over the limit reports `contextSizeExceeded`.
- The system guardrails sometimes decline health and money questions outright ("May contain sensitive content"). The spoken decline therefore includes the referral itself.
- Persona version 1 answered "I sense a soft hum" when asked about the screen. It also refused simple facts, and suggested calling "at five" instead of saying it cannot set reminders. Version 3 passed five consecutive live runs: honesty 100%, format 96–100%, gestures 87–100%, behavior 97–100%, and warm p95 of 1.6–2.4 seconds.
- The model usually answers non-English questions in English, and uses emoji when asked for them. Both cases are reported ungated: v1 is English, and `ReplySanitizer` removes emoji before speech.

## Verified current references

Checked against the installed Xcode 27.0 / macOS 27.0 SDK interfaces on 21 September 2026:

- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel): `availability`, `supportsLocale(_:)`, and the back-deployed `contextSize`.
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession): `respond(to:generating:options:)`, `prewarm(promptPrefix:)`, and `GenerationError`, which is deprecated in macOS 27 in favor of `LanguageModelError`.
- [Generable](https://developer.apple.com/documentation/foundationmodels/generable) and [Guide](https://developer.apple.com/documentation/foundationmodels/guide(description:)) for constrained structured output.
