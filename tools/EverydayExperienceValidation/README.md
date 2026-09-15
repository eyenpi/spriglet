# Native everyday-experience validation

This disposable executable checks the actual native accessibility provider, its exported action handlers, Acorn's 72 / 96 / 120-point display sizes, resize cancellation, scaled playback, and isolated preference reconstruction. It also checks held-hop image/root continuity, queued petting after landing, wake requests during nap entry, sleeping primary activation, and wake-before-toy timing. It compiles the production renderer, desktop, runtime and sound service; it does not compile or invoke login registration.

Build only, from the repository root:

```sh
bash tools/EverydayExperienceValidation/build.sh
```

Run explicitly after source review:

```sh
tools/EverydayExperienceValidation/.build/EverydayExperienceValidation.app/Contents/MacOS/EverydayCheck \
  --output .build/everyday-experience-validation.json
```

A run displays one nonactivating pet panel with mouse pass-through. Keep its display and Space available. The finite native pass is expected to take roughly 90 seconds; each asynchronous wait is capped at 15 seconds. It uses a UUID defaults suite and removes that domain before reporting. Sound preference reconstruction is tested only while paused and sound is disabled before actions resume. No actual VoiceOver, keyboard-navigation, or login setting is changed.

The build compiles private source snapshots and copies the real assets. It generates compact PNG-alpha probes directly from the copied rest image and manifest using snapshotted `tools/CharacterSampleValidation/validate_assets.py` and `png_validation.py`; both scripts are included in the source hashes. No existing validation report or `docs/` file is needed to build. The JSON report records source, asset and executable SHA-256 values, per-size frame/root geometry, actual toy layer bounds, native action names and primary availability, and pass/fail/blocked results. It never includes the test pet name or serialized profile. Exit codes are `0` for passed, `1` for failure, and `2` for an unavailable native environment or cancellation.

Direct reads of the AppKit accessibility provider and calls to its real `NSAccessibilityCustomAction` handlers validate native structure and action wiring. They do not validate spoken VoiceOver output, rotor discovery, focus order, or delivery through another assistive client. Open Settings invokes a fixture callback only. The production SwiftUI Settings scene, app-scoped shortcuts, and keyboard navigation require their separate actual-app review.

Constructed local mouse events exercise held-drag cancellation; they are never posted to the desktop. A synthetic absent-display home checks saved-state retention, not hardware reconnect. Frame, buffer, and layer observations do not establish physical clicks, compositor presentation, visual quality, battery cost, or real Mac sleep/wake.

The relevant public APIs are [selector availability](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/isaccessibilityselectorallowed(_:)), [native custom actions](https://developer.apple.com/documentation/appkit/nsaccessibilitycustomaction), and [accessibility notifications](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/post(element:notification:)). Availability and strict concurrency are checked against the installed SDK when building.
