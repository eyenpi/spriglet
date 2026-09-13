# GitHub Copilot CLI contribution

On September 13, 2026, GitHub Copilot CLI **1.0.83** implemented the public preview's first-run welcome and compact everyday controls in an isolated checkout of Spriglet. The CLI was downloaded from the [official release](https://github.com/github/copilot-cli/releases/tag/v1.0.83), and its archive digest was verified before execution.

The contribution covers three app files: `SprigletApp.swift`, `PrototypeView.swift`, and `PetRuntime.swift`. It adds an explicit Get Started flow, a reusable welcome presentation, collapsed diagnostics, clearer motion-state explanations, and temporary welcome-review behavior. Review caught and corrected persistence and menu-reopening edge cases before integration.

The coordinating development session applied a few integration changes: the Controls menu explicitly leaves welcome, lifecycle logging follows the public app identity, and visible copy uses the product name. The [contribution record](copilot-contribution.json) identifies the exact CLI-produced patch and source hashes before and after those adjustments. Debug and Release builds and native UI inspection were performed after integration; the restricted CLI session itself did not run Xcode.

The app's existing desktop host, playback engine, grounded motion, Blender character, and animation pipeline were developed earlier with other AI assistance. This record does not attribute the entire project to Copilot.

The CLI ran with file tools for the bounded app task, without shell, account, publishing, or contest-entry tools. Raw sessions stay in the private development workspace because they contain machine-specific context. No contest post was submitted by automation.

The [public preview's release notes](public-preview.md) describe the resulting app and validation. The exact contest rules and manual entry materials are maintained separately from the app itself.
