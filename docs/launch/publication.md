# Public launch handoff

[Spriglet’s public source](https://github.com/eyenpi/spriglet-public) and [0.1.0 preview release](https://github.com/eyenpi/spriglet-public/releases/tag/v0.1.0-preview.1) are live. Code, documentation, editable Blender artwork, rendered frames, icon, and demo media use MIT.

The public repository is a clean one-commit snapshot on `codex/public-preview`, at `65b5bc0fd0d1aa76fb52dedb0d26e987e18f9318`. Its [macOS CI run](https://github.com/eyenpi/spriglet-public/actions/runs/34783864560) passed. Fresh exported-source checks also passed 61 Swift test functions, 38 Python tests, all 244 PNGs/contact checks, 22 app-probe checks, and 22 native lifecycle checks. The [receipt](publication-receipt.json) retains release assets, hashes, CI status, and publication scope.

The working public checkout is `../spriglet-public-export`. Keep private development history separate: never merge, mirror-push, or force-push private refs to the public repository. Future public updates should pass through the [clean snapshot workflow](../../tools/PublicRelease/README.md), followed by fresh validation of the resulting assets and builds.

This is a source preview for Apple silicon/macOS 26. A normal Mac download still needs a valid Developer ID identity, Apple notarization, and the distribution acceptance checks. The local unsigned ZIP was not uploaded. The leaf-menu Show Welcome action remains the small manual UI follow-up recorded in the launch review; broader desktop/battery acceptance remains future work.

## Contest handoff

No entry has been submitted. Manually publish the [prepared caption](contest-post.txt) with [the MP4](../media/spriglet-demo.mp4) once on a public X, Instagram, or LinkedIn account before **September 14, 2026 at 08:59 in Berlin**. The [official rules](https://github.com/katiejliu/github-copilot-day-sweepstakes/blob/main/README.md) prohibit automated participation; do not submit another entry if already entered. Read the [entry notes](contest-entry.md) for eligibility and attribution details.
