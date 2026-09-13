# Spriglet 0.1.0 public preview

Sprout is now presented as a small usable Mac companion: a first-run welcome explains click-to-pet, dragging, and the leaf menu; everyday controls keep technical diagnostics collapsed until requested. The app icon comes from the same editable character. Code and artwork are released together under MIT.

The sample plays idle → a short walk → petting reaction → settle. Both walking directions coordinate character poses with desktop movement. Quiet behavior, static naps, saved home placement, pause/hide, click-through, and accessible placement controls remain available.

## Availability

This is a **source preview for Apple silicon and macOS 26 or later**. It builds locally with full Xcode. The public launch includes source, editable Blender artwork, a demo video, and reproduction tools. There is no signed, notarized public app download yet: this development Mac has no valid Developer ID signing identity. The [distribution tooling](distribution.md) prepares and verifies artifacts and refuses to claim trusted distribution without the required signing and notarization checks.

The public source is published as a clean snapshot in [eyenpi/spriglet-public](https://github.com/eyenpi/spriglet-public). Private development history and raw Copilot sessions are not part of that repository. Publication removes local machine-path metadata without changing the character pixels, animation, or code behavior. The [snapshot tool](../tools/PublicRelease/README.md) documents the proof and provenance recorded for those changes.

## Verification

The [local integration record](results/public-preview/integration.json) identifies the current UI sources and Debug/Release binaries. Both configurations build successfully. Swift Testing passes 61 test functions in eight suites; the asset validators pass 11 regression tests and the release verifier passes 12. The Release app contains the sandbox entitlement and no debugging entitlement.

Native UI review checks the actual welcome artwork and instructions, Get Started, compact controls, collapsed diagnostics, changing Nap/Wake labels, and the paused-state explanation. Temporary welcome review leaves the app's welcome and pet preferences unchanged. The [isolated normal-launch review](results/public-preview/launch-review.json) passes nine checks, including first launch and remembered completion after quitting and relaunching. Reopening Welcome from the leaf menu remains a manual UI follow-up because the automation surface did not expose that menu item. The [current Release runtime probe](results/public-preview/runtime-probe.json) passes all 22 checks. The [local packaging check](results/public-preview/local-package.json) passes bundle and signature validation for a clearly labelled unsigned local artifact; it is not a notarization result. Clean exported assets receive separate fresh validation before publication.

The existing character validation covers all 244 PNGs, the editable groom/rig, grounded contact, both directions, cancellation, matched image/movement timing, and a 100-cycle soak. Its original source and binary hashes remain historical: those measurements are not silently relabelled as runs against this later app build. Fresh public-export checks establish the metadata-cleaned assets separately.

## Known limits

The full personality and animation library are still ahead. Transparent window margins can affect underlying clicks, with whole-window Pass Clicks Through as the explicit fallback. Wider Spaces/full-screen/Stage Manager, monitor changes, real sleep/wake, long-duration performance, and battery acceptance remain separate work. Short test observations are not battery or memory guarantees.

The social demo is assembled from the app's exact animation assets and motion data. It is labelled as an animation asset demo, not presented as a screen recording. GitHub Copilot CLI's welcome and controls contribution is recorded [here](copilot-contribution.md).
