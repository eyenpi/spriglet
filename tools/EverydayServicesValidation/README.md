# Optional everyday services

`PetSoundService` provides two original finite chimes. It is disabled until the runtime enables the user's sound preference. Enabling or clearing suspension never plays or resumes audio; a finite user interaction must request a cue. Disabling, suspension, and shutdown stop and release the player. A completion callback also releases it, with a generation guard against stale callbacks. At most one player is retained; repeated requests inside two seconds are ignored. There is no audio engine, scheduled loop, metering, polling timer, or global input observer.

The cooldown measures elapsed time from an in-process `ContinuousClock` origin. It neither reads system boot time nor persists clock instants; the injected elapsed-time closure makes its boundaries deterministic in tests.

The `greeting.wav` and `play.wav` assets live in `Sources/Spriglet/Resources/PetSounds/` and must be bundled as the `PetSounds` folder. They are original deterministic sine partials with finite attack/decay envelopes, created by [generate_chimes.py](generate_chimes.py), without external recordings. Both are mono 48 kHz, 16-bit PCM: 0.44 and 0.62 seconds. Their peak amplitude is approximately 0.10 full scale; the native player uses volume 0.20 and zero loops. These numbers bound the mix level; perceived loudness depends on the output device and system volume. [chime-provenance.json](chime-provenance.json) retains exact hashes and dimensions. Run the generator only to intentionally rebuild assets.

`LoginItemService` uses current `SMAppService.mainApp` status and explicit register/unregister calls. Initialization and `refresh()` are read-only. `requiresApproval` remains a distinct registered-but-not-yet-eligible state, so the settings UI can keep the registration toggle on and offer **Open Login Items**. Opening System Settings is its own explicit action. Errors retain actual status readback; a method return is never substituted for macOS's state.

The default service rejects login mutations for nonapplication validation executables and explicit probe/soak/review/acceptance flags. Normal source builds are not rejected based on directory: Apple does not require `/Applications` for the main application login item. A stable Applications installation is useful because a development build can be replaced or deleted. Current Apple documentation requires a signed app, and real registration remains subject to macOS authorization. No login choice is persisted in app preferences as a substitute for system status.

## Build and verify without side effects

From the repository root:

```sh
tools/EverydayServicesValidation/build.sh

tools/EverydayServicesValidation/.build/EverydayServicesCheck \
  --resources Sources/Spriglet/Resources/PetSounds \
  --output tools/EverydayServicesValidation/.build/results.json

python3 -m unittest discover -s tools/EverydayServicesValidation -p 'test_*.py' -v
```

The build targets macOS 26 with Swift 6 strict concurrency and warnings as errors. It launches nothing. The standalone check injects fake login and audio players, covering explicit enable/disable, idempotence, approval, errors, external status readback, diagnostic guards, no implicit audio, throttling, cancellation, finite completion, stale callbacks, and failure cleanup. Real WAVs are parsed with `AVAudioPlayer(contentsOf:)` but neither `play()` nor `prepareToPlay()` is called. It performs **no OS login registration/unregistration, System Settings opening, or sound output**. The two Python tests check the PCM format, bounded sample peak, silent endpoints, hashes, and exact regeneration in a temporary directory.

These tests do not certify actual macOS login acceptance, next-login launch, or listening quality. Those require separate explicitly authorized review. The service itself never runs a registration test on launch.

## Production dependencies

- `Sources/Spriglet/Services/PetSoundService.swift`: Foundation and AVFAudio. Every fixture that compiles `PetRuntime` must include this file and link AVFAudio.
- `Sources/Spriglet/Services/LoginItemService.swift`: Foundation, Observation, and ServiceManagement. The app target includes it; runtime-only fixtures do not need it.
- Both WAVs in a bundled `PetSounds` folder. No change to the authored `SproutSample` resources is necessary.

The new classes add no broad filesystem or microphone entitlement. Audio reads only bundled assets; login registration uses the system API and user approval.

## Verified current references

Checked against official Apple documentation and the installed Xcode 26.6 / macOS 26.5 SDK headers on 14 September 2026:

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), and [unregister()](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()). The signed-app requirement is also explicit in `ServiceManagement.framework/Headers/SMAppService.h`.
- [Service status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum) and [Open Login Items](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems()).
- [AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer), [play()](https://developer.apple.com/documentation/avfaudio/avaudioplayer/play()), [stop()](https://developer.apple.com/documentation/avfaudio/avaudioplayer/stop()), and [numberOfLoops](https://developer.apple.com/documentation/avfaudio/avaudioplayer/numberofloops). The installed `AVFAudio.framework/Headers/AVAudioPlayer.h` confirms zero loops means one finite playback and stopping releases playback setup.
- [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) and [Duration components](https://developer.apple.com/documentation/swift/duration/components) provide the two-second local elapsed-time comparison.
