# Contributing

Spriglet is an early public preview for Apple silicon Macs running macOS 26 or later. Small, focused contributions and reproducible bug reports are welcome.

For a bug, include your macOS version, Mac model, what you did, what you expected, and whether Reduce Motion, Pause, or Pass Clicks Through was enabled. Remove local paths and other personal information from optional diagnostic reports. Please do not include screenshots of unrelated apps or private desktop content.

Build with full Xcode selected, then run `./scripts/test.sh` and the checks relevant to your change. App changes should build in Debug and Release. Animation changes should preserve the manifest timing, contact, transparency, and resource validation described in [the character pipeline](docs/character-sample.md).

Use current supported Swift and Apple APIs and verify new choices against official documentation and the installed SDK. Keep the companion local and quiet. Avoid introducing third-party services or permanent polling for work that can be event-driven.

Code and artwork contributions are provided under the repository's MIT license. Keep third-party material out of a contribution unless its license and attribution are compatible and documented.
