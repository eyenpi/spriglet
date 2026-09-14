# Candidate Review

A separate visible macOS app for comparing the Acorn Hopper and Moss Mouse prototypes. It compiles the actual Spriglet renderer and decoder; no alternate animation player is used for the native review.

See the [candidate workflow](../../art/candidates/README.md) for editing, rendering, playback, and verification commands.

`CandidateReview.swift` uses an AppKit parent view whose 224-unit bounds map to a 96-point frame. The child renderer retains its existing 224-unit contract. Each authored frame's root displacement is converted by the same ratio before committing the image. The check measures the child's rectangle in the board coordinate system and its actual backing-store dimensions, rather than assuming a Retina scale. The two source canvases remain 448-pixel RGBA exports.

The tool verifies eight finite sequences: two candidates × two backgrounds × two directions. It records accepted frames, completion, buffering, effective root placement, native size, and quiet rest. Its JSON does not claim separate desktop-panel behavior, atomic compositor presentation, every-frame screen presentation, energy measurements, or artistic acceptance. Closing the window cancels playback. No preferences or services are registered.

The snapshot uses the review view's own cached drawing; it does not capture other apps or request Screen Recording. `RenderMedia` separately composes labeled offline comparison media from the export manifests. Runtime playback evidence and offline media are deliberately identified in their outputs.

Platform APIs were checked against the installed macOS SDK and current official documentation: [setBoundsSize](https://developer.apple.com/documentation/appkit/nsview/setboundssize(_:)), [convertToBacking](https://developer.apple.com/documentation/appkit/nsview/converttobacking(_:)-3zors), and [cacheDisplay](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)). Builds use Swift 6 strict concurrency with warnings treated as errors, targeting macOS 26.
