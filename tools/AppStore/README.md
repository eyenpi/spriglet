# App Store preparation

The current Mallow rewrite is a local preview. It has not been submitted to Apple. Prepared metadata and policy are generated from `Configuration/Shared`; local validation does not constitute Apple approval.

```sh
python3 tools/SharedContent/sync.py --check
python3 tools/AppStore/validate.py
scripts/archive-app-store.sh --unsigned --check
scripts/archive-app-store.sh --unsigned --output .build/app-store/NEW_DIRECTORY
```

An unsigned archive rehearsal validates architecture, minimum OS, icon slots, sandboxing, privacy declarations, bundled documents and app version. It makes no upload. A signed archive requires the appropriate Apple account and signing configuration; never put certificates, profiles or credentials in Git.

Use screenshots of the actual Mallow app: default visible peek, hover response, invited body, weighted drag and a soft landing. Avoid unrelated apps and private desktop content. The persistent leaf menu offers visibility, pause, Bring Home, Settings, offline Help and Quit. Settings and Help preserve the current app’s keyboard focus. Reopening from Finder recovers hidden Mallow without activating Spriglet or clearing Pause. No sound/login service or action cards are included.

The privacy manifest declares monotonic timing for animation. The retired UserDefaults declaration is removed; app-owned code has no preferences store. The app does not persist companion data, track global keyboard events, inspect other apps or enable plugins. Review both implementation and declarations before changing data handling or preparing a submission.

Before submitting, verify live notch and edge placement, click-through margins, drag/release/catch, focus preservation, display/session recovery, Reduce Motion, Low Power Mode, thermal suspension, accessibility and idle resource use. Developer tools and CI builds do not replace that acceptance pass.

Publishing is a separate explicit action. Keep support, privacy, metadata and screenshots aligned with the exact build being submitted.
