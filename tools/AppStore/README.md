# App Store preparation

The current Mallow rewrite is a local preview. It has not been submitted to Apple. Prepared metadata and policy are generated from `Configuration/Shared`; local validation does not constitute Apple approval.

```sh
python3 tools/SharedContent/sync.py --check
python3 tools/AppStore/validate.py
scripts/archive-app-store.sh --unsigned --check
scripts/archive-app-store.sh --unsigned --output .build/app-store/NEW_DIRECTORY
```

An unsigned archive rehearsal validates architecture, minimum OS, icon slots, sandboxing, privacy declarations, bundled documents and app version. It makes no upload. A signed archive requires the appropriate Apple account and signing configuration; never put certificates, profiles or credentials in Git.

Use screenshots of the actual Mallow app: default visible peek, hover response, invited body, weighted drag and a soft landing. Avoid unrelated apps and private desktop content. The app has no persistent menu-bar item, settings window, sound/login service or action cards. Right-click Mallow for Help → Meet Mallow or Quit Spriglet. Reopening it from Finder returns Mallow home without taking focus.

The privacy manifest declares monotonic timing for animation and app-local UserDefaults access (`CA92.1`) for the introduction's dismissal flag, following [Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). No demo progress or companion state is persisted. The app does not track global keyboard events, inspect other apps or enable plugins. Review both implementation and declarations before changing data handling or preparing a submission.

Before submitting, verify live notch and edge placement, click-through margins, drag/release/catch, focus preservation, display/session recovery, Reduce Motion, Low Power Mode, thermal suspension, accessibility and idle resource use. Developer tools and CI builds do not replace that acceptance pass.

Publishing is a separate explicit action. Keep support, privacy, metadata and screenshots aligned with the exact build being submitted.
