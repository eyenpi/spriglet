# App Store preparation

Version 0.3.5, build 11 prepares the next TestFlight candidate, adding the paper boat habits from PR #62 to the merged 0.3.4 source. Confirm the latest uploaded build in App Store Connect before archiving. Preserve the existing approved Store submission while preparing this TestFlight update. The published GitHub downloads are separate. Metadata and policy come from Configuration/Shared. Record upload, processing and beta review status privately with the exact archive.

The current candidate is 0.3.5, build 11. Small uses a hands-only boat gesture; Medium and Large can admire, adjust or doze beside the boat. Existing scheduling, power restrictions and motion preferences apply. This candidate includes the stable drawing changes from PR #60 and earlier size and Settings fixes. Preserve all historical changelog entries, the published v0.3.2 tag and its assets. Drop to Mallow from PR #45 remains excluded. Build and validate the exact integrated revision; earlier archives do not contain the boat habits.

```sh
python3 tools/SharedContent/sync.py --check
python3 tools/AppStore/validate.py
scripts/archive-app-store.sh --unsigned --check
scripts/archive-app-store.sh --unsigned --output .build/app-store/NEW_DIRECTORY
```

Archive from a clean committed revision. Both signed and unsigned archives reject source changes during the build, verify the checked-in bundle identifier and matching dSYM, verify non-root installation permissions, and record the executable and complete bundle checksums. The output includes exact bundled support, privacy and changelog documents, submission metadata, and reviewer notes prefixed with the archive's version/build. Keep these records with the candidate; a later source change requires a new archive and acceptance pass.

An unsigned archive rehearsal validates architecture, minimum OS, icon slots, sandboxing, privacy declarations, bundled documents and app version. It makes no upload. A signed archive requires the appropriate Apple account and signing configuration; never put certificates, profiles or credentials in Git. `--team-id` validation verifies the selected team; a development-signed archive still needs a distribution export and Apple validation.

For the exported application, use `python3 tools/AppStore/validate.py --app PATH --distribution --team-id TEAM`. This rejects development, Developer ID and ad hoc signatures as App Store exports. The report deliberately keeps `submissionReady` false: local verification cannot establish Apple processing, physical device acceptance or App Store Connect readiness. See [submission answers and acceptance](submission.md).

Use screenshots of the actual Mallow app: default visible peek, hover response, invited body, weighted drag and a soft landing. Avoid unrelated apps and private desktop content. Open the native Settings window from Settings in the leaf, Command-comma while Spriglet is active, or its VoiceOver custom action. The leaf menu contains only Settings and Quit; visibility, pause, Bring Home and login controls are in Settings and Spriglet’s native app menu. The native Help menu and offline Help provide Meet Mallow replay. Settings opens with keyboard focus; Help preserves the current app’s focus. The first-launch introduction uses short animations of the production character and remembers dismissal. Reopening from Finder recovers hidden Mallow without activation or clearing Pause. No sound service or action cards are included.

Launch at login is off for a new installation. An explicit shared-menu or Settings choice registers or unregisters the main app through `SMAppService.mainApp`. The shared menus and Settings read actual macOS registration instead of a saved boolean, distinguish enabled and approval-required states, and reports unavailable states and failed changes. Approval is reviewed through System Settings > General > Login Items & Extensions; a pending registration cannot launch the app until macOS reports it as enabled. Startup never registers automatically or restores an old login preference, and there is no helper app or launch-agent service. Disabling the option keeps the current companion running; quitting preserves registration.

The privacy manifest declares monotonic timing for animation. It also declares app-owned UserDefaults access for locally saved size, movement intensity, home choices and introduction dismissal. No demo progress is saved. The store uses a dedicated Mallow namespace and does not migrate retired preferences. The app does not persist interaction history, track global keyboard events, inspect other apps or enable plugins. Review both implementation and declarations before changing data handling or preparing a submission.

Before submitting, verify live notch and edge placement, click-through margins, drag/release/catch, focus preservation, display/session recovery, Reduce Motion, Low Power Mode, thermal suspension, accessibility and idle resource use. Verify default-off login launch, explicit registration/removal, approval and failure feedback, external changes in System Settings, and one companion after signing out and back in on the distributed signed build. Developer tools and CI builds do not replace that acceptance pass.

Publishing is a separate explicit action. Keep support, privacy, metadata and screenshots aligned with the exact build being submitted.
