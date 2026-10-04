# App Store preparation

The current Mallow rewrite is a local preview. It has not been submitted to Apple. Prepared metadata and policy are generated from `Configuration/Shared`; local validation does not constitute Apple approval.

```sh
python3 tools/SharedContent/sync.py --check
python3 tools/AppStore/validate.py
scripts/archive-app-store.sh --unsigned --check
scripts/archive-app-store.sh --unsigned --output .build/app-store/NEW_DIRECTORY
```

An unsigned archive rehearsal validates architecture, minimum OS, icon slots, sandboxing, privacy declarations, bundled documents and app version. It makes no upload. A signed archive requires the appropriate Apple account and signing configuration; never put certificates, profiles or credentials in Git.

Use screenshots of the actual Mallow app: default visible peek, hover response, invited body, weighted drag and a soft landing. Avoid unrelated apps and private desktop content. The app has no persistent menu-bar item, settings window, sound service or action cards. Reopening it from Finder returns Mallow home without requesting keyboard focus. Its right-click menu provides Launch at Login, current macOS registration status, Login Items settings and Quit Spriglet.

Launch at login is off for a new installation. An explicit menu choice registers or unregisters the main app through `SMAppService.mainApp`. The menu reads actual macOS registration instead of a saved boolean, distinguishes enabled and approval-required states, and reports unavailable states and failed changes. Approval is reviewed through System Settings > General > Login Items & Extensions; a pending registration cannot launch the app until macOS reports it as enabled. Startup never registers automatically or restores an old login preference, and there is no helper app or launch-agent service. Disabling the option keeps the current companion running; quitting preserves registration.

The privacy manifest declares monotonic timing for animation. The retired UserDefaults declaration is removed; app-owned code has no preferences store. The app does not persist companion data, track global keyboard events, inspect other apps or enable plugins. Review both implementation and declarations before changing data handling or preparing a submission.

Before submitting, verify live notch and edge placement, click-through margins, drag/release/catch, focus preservation, display/session recovery, Reduce Motion, Low Power Mode, thermal suspension, accessibility and idle resource use. Also verify default-off login launch, explicit registration and removal, approval and failure feedback, external changes in System Settings, and exactly one companion after signing out and back in. Complete these checks on the distributed signed build. Developer tools and CI builds do not replace that acceptance pass.

Publishing is a separate explicit action. Keep support, privacy, metadata and screenshots aligned with the exact build being submitted.
