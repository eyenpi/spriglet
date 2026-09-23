# Native interaction regression check

Build the actual pet input view, desktop window, renderer, and runtime into a disposable native executable:

```sh
bash tools/DesktopAcceptanceValidation/build-interaction-check.sh
tools/DesktopAcceptanceValidation/.build/interaction/InteractionCheck.app/Contents/MacOS/InteractionCheck --output .build/interaction-check.json
```

The check uses constructed local events against the app's own handlers, including the eyes-only drag sequence, the body-to-eyes shape preview, and restoration when a drag ends below the docking threshold. It does not post physical input, type into another app, change Spaces, disconnect a display, or put the Mac to sleep. Those need separate physical acceptance checks.

Whole-window **Pass Clicks Through** is the supported transparent-area fallback. In interactive mode, transparent margins may intercept input. Spriglet may remain visible over full-screen apps; Hide Pet and pass-through remain available from Settings and the leaf menu.

Reports and build products stay under ignored `.build/` directories.
