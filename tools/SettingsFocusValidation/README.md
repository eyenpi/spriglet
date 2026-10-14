# Settings focus regression

This opt-in, interactive desktop test checks the production bundled daily-use fixture. It clicks the native leaf menu while TextEdit is active, selects Settings without clicking its window, and verifies system-wide focused application/element, active application, Tab, Shift-Tab, Space, Escape and Command-W. It repeats eight close → TextEdit → menu reopen cycles and checks reuse of the same window and delivery of all keyboard events to the fixture. Merely ordering a window or reporting per-app Accessibility focus cannot pass.

Run only on an idle logged-in desktop with Accessibility and input-monitoring permission already granted to the tool host. The test sends desktop-wide synthetic mouse and keyboard events; do not run concurrently with other desktop tests or use the keyboard/mouse during its sequence. Outside input, missing observation permission, wrong fixture path and absent/nonempty TextEdit probes fail the run. A failure before Settings is selected is a setup/menu failure, not evidence of a Settings activation defect.

1. Quit any existing daily-use fixture through its leaf menu. Do not rebuild a running fixture: the recorded executable checksum describes the file on disk.
2. Run `./scripts/test-desktop.sh --prepare-daily-use` and open the printed app using Finder or CUA. This fixture uses disposable preferences and fake login registration and exits after five minutes.
3. Open an empty, disposable Untitled TextEdit document. The test raises this probe, never writes document text, and leaves it open for serial repeats. Close it when finished.
4. Compile and run from the repository root:

```sh
mkdir -p .build/settings-focus
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  tools/SettingsFocusValidation/main.swift -o .build/settings-focus/settings-focus-validation
.build/settings-focus/settings-focus-validation \
  .build/lifecycle-validation/Daily-UseFixture.app .build/settings-focus/result.json
```

The result records the actual fixture path, executable SHA-256, macOS version, display count, global-focus checkpoints, keyboard event target PIDs and outside-input metadata. It captures only the Settings window in `result.png` beside the chosen JSON output. All results and screenshots remain local and ignored. The native runner also checks that Settings remains an ordinary window at normal level; existing lifecycle coverage checks passive companion actions independently.

Repeat after fresh fixture launches as well as within a single process. A clean synthetic pass establishes routing for that controlled sequence; physical keyboard, spoken VoiceOver, other macOS versions, fullscreen and Spaces acceptance remain separate.
