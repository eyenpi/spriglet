# Candidate Review

A separate visible macOS app for comparing the Acorn Hopper and Moss Mouse prototypes. It compiles the actual Spriglet renderer and decoder; no alternate animation player is used for the native review.

See the [candidate workflow](../../art/candidates/README.md) for editing, rendering, playback, and verification commands.

`CandidateReview.swift` uses an AppKit parent view whose 224-unit bounds map to a 96-point frame. The child renderer retains its existing 224-unit contract. Each authored frame's root displacement is converted by the same ratio before committing the image. The check measures the child's rectangle in the board coordinate system and its actual backing-store dimensions, rather than assuming a Retina scale. The two source canvases remain 448-pixel RGBA exports.

The default assets are `art/candidates/transitions-v03`. A normal launch opens ready to play. Use `--check` for exhaustive verification and automatic exit: 24 finite sequences (six actions × two candidates × two backgrounds), every ordered pair of the five experiences (100 handovers), and latest-request replacement (four handovers). It also cancels a nap with a pending pet request and verifies that neither resumes after suspension. Reports go under `.build/candidate-transitions/`.

Interactive controls call the real renderer's additive `transition(to:)` method. It finishes the current finite clip sequence, retains one latest pending intent, and resolves sleep/wake bridges when playback actually begins. The host retains the last landed position. Hop/dash chooses the direction from the current action's projected landing; repeated movement stays within the review card. Wake/rest is a graceful request, not a hard reset. All states runs one finite demonstration; any other control replaces the remaining demo steps. Only automated fixture setup uses a pose/position reset.

The report records actual clip order, completion, buffering, effective root placement, native size, boundary displacement and quiet rest. Pose and expression matching are checked independently against the Blender actions and exports. Its JSON does not claim separate desktop-panel behavior, atomic compositor presentation, every-frame screen presentation, energy measurements, or artistic acceptance. Closing the window cancels active and pending playback. No preferences or services are registered.

The snapshot uses the review view's own cached drawing; it does not capture other apps or request Screen Recording. `RenderMedia` separately composes labeled offline comparison media from the export manifests. Runtime playback evidence and offline media are deliberately identified in their outputs.

Platform APIs were checked against the installed macOS SDK and current official documentation: [setBoundsSize](https://developer.apple.com/documentation/appkit/nsview/setboundssize(_:)), [convertToBacking](https://developer.apple.com/documentation/appkit/nsview/converttobacking(_:)-3zors), and [cacheDisplay](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)). Builds use Swift 6 strict concurrency with warnings treated as errors, targeting macOS 26.
