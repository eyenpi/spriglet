# Spriglet 0.1.0 public preview

Sprout is a small usable Mac companion: a first-run welcome explains click-to-pet, dragging, and the leaf menu; everyday controls keep technical diagnostics collapsed until requested. The app icon comes from the same editable character. Code and artwork use MIT.

The sample plays idle → a short walk → petting reaction → settle. Both walking directions coordinate character poses with desktop movement. Quiet behavior, static naps, saved home placement, pause/hide, click-through, and accessible placement controls remain available.

## Availability

Source, editable Blender artwork, demo media, and reproduction tools are maintained in [eyenpi/spriglet](https://github.com/eyenpi/spriglet), on `main`. This is a **source preview for Apple silicon and macOS 26 or later**, built locally with full Xcode. The repository owner controls when its visibility changes to public.

A signed, notarized app download is not included yet. The [distribution tooling](distribution.md) requires a valid Developer ID identity and successful Apple notarization before producing that download. The local unsigned ZIP is a development artifact.

This repository retains its original development history. Current assets include the verified removal of local path metadata; that file cleanup does not rewrite older commits. The [historical snapshot evidence](results/public-preview/snapshot-provenance.json) records the pixel/model identity proof used for that cleanup.

## Verification

The [repository preparation checks](results/repository-preparation/verification.json) cover the coherent asset/provenance import, fresh saved-model and icon verification, Swift and Python tests, and PNG/contact checks. The [GitHub workflow](https://github.com/eyenpi/spriglet/actions/workflows/validate.yml) checks `main` with the current stable macOS toolchain.

The [preview validation record](results/public-preview/public-validation.json) retains the earlier exact-source checks: Debug/Release builds, 61 Swift test functions, 38 Python tests, ten numerical asset/contact checks over 244 PNGs, 22 app-probe checks, and 22 native lifecycle checks. Both finite walking sequences recorded zero mismatched image/movement pairs and zero buffer underruns. Its input hashes identify the checked app code and animation assets; moving those same files into this repository does not turn that earlier run into a new run.

The [normal-launch review](results/public-preview/launch-review.json) passed nine checks, including first launch, Get Started, and remembered completion after quitting and relaunching. Temporary welcome review left normal preferences unchanged. Reopening Welcome through the leaf menu still needs a manual UI check because the automation surface did not expose that item. The [local package check](results/public-preview/local-package.json) verifies the ad hoc development artifact, not notarization.

Earlier character checks include the editable groom/rig, foot contact, both directions, cancellation, matched image/movement timing, and a 100-cycle soak. Historical source and binary hashes remain unchanged in those reports. The [evidence index](results/public-preview/README.md) distinguishes the former exported snapshot from this original repository and its history.

## Known limits

The full personality and animation library are still ahead. Transparent window margins can affect underlying clicks; whole-window Pass Clicks Through is available. Wider Spaces/full-screen/Stage Manager, monitor changes, real sleep/wake, long-duration performance, and battery acceptance remain separate work. Short test observations are not battery or memory guarantees.

The social demo is assembled from the app’s exact animation assets and motion data and is labelled as an animation asset demo. GitHub Copilot CLI’s welcome and controls contribution is recorded [here](copilot-contribution.md).
