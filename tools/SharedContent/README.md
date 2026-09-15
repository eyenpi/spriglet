# Shared app and website content

Edit the source once; app builds and website builds generate the copies they need. Generated files are committed so the website, public documents, and store listing are reviewable. CI rejects stale output before building.

## Where to edit

| Change | Authoritative source | Updates |
| --- | --- | --- |
| App logo | [AppIcon asset catalog](../../Sources/Spriglet/Assets.xcassets/AppIcon.appiconset/Contents.json) | Native app icon; website header and favicon |
| Name, publisher, copyright year, domain, email | [brand.json](../../Configuration/Shared/brand.json) | App links/display name; support and privacy copy; website header/footer; App Store metadata; Cloudflare domain |
| Shared help/control labels and About text | [en-US.json](../../Configuration/Shared/en-US.json) | Native controls; matching labels in support/privacy/review text |
| Privacy policy | [privacy.md](../../Configuration/Shared/privacy.md) | Root `PRIVACY.md`; offline app policy; website privacy page |
| Support/help content | [support.md](../../Configuration/Shared/support.md) | Offline Help & Support window; website help; public support Markdown |
| Product copy draft | [product.md](../../Configuration/Shared/product.md) | Prepared product Markdown; product page design remains deferred |
| App Store-specific description and review notes | [app-store.en-US.json](../../Configuration/Shared/app-store.en-US.json) | Importable App Store metadata, with shared names, URLs, email, and control labels resolved |
| License | [LICENSE](../../LICENSE) | Bundled license |
| App bundle metadata | [Info.plist template](../../Configuration/Shared/Info.plist) | Build input `Configuration/Info.plist` with shared display name/copyright |

Templates use `{{name}}` substitutions such as `{{supportEmail}}`, `{{privacyPolicyURL}}`, and `{{playWithFirefly}}`. Unknown or unfinished substitutions fail generation. Website HTML escapes the resolved text. Swift labels are generated into `SharedContent.generated.swift`; keep resource filenames and window IDs stable when changing labels.

The icon exporter at `art/sprout/public-preview/export_icon_catalog.sh` builds all ten app icon sizes from the existing Blender-rendered master, then synchronizes the website. The website uses the catalog's 128-point 1× slot for its 44-pixel header and favicon. Update the catalog through the exporter when changing the master artwork; changing only a different size slot is not a complete app icon update.

## Automatic integration

- **Xcode Build/Archive:** the first target build phase synchronizes shared content before compilation and resource copying. Script sandboxing stays enabled, with declared inputs and outputs in `Configuration/SharedContent.*.xcfilelist`.
- **Build/archive scripts:** synchronize before preflight checks.
- **Icon export:** refreshes website artwork after exporting the app catalog.
- **Website deployment script:** `./scripts/deploy-website.sh` regenerates before Wrangler reads the custom domain. `--dry-run` checks the deployment without publishing.
- **Wrangler dev/deploy:** its custom build regenerates shared files before preparing static assets. Run it inside the Git checkout; the command locates the worktree root. Preview watches shared text, icon, license, and renderer inputs.
- **CI:** verifies generated files, runs propagation tests, and checks the final app/archive resources.

To refresh everything without building an app:

```sh
python3 tools/SharedContent/sync.py
python3 tools/SharedContent/sync.py --check
python3 tools/AppStore/website/build.py --check
python3 -m unittest discover -s tools/SharedContent -p 'test_*.py'
```

Commit the sources and generated outputs together. If an input filename or generated output is added, update the Xcode file lists too; tests check their coverage. Generation leaves unchanged files untouched, avoiding needless Swift recompilation.

This shares source content at build time. A published website changes after deployment; an installed app changes after a new app release. The app continues to work offline and never downloads remote text or code. App Store Connect metadata still needs to be entered/uploaded through Apple's submission workflow. UI-specific prose and website layout stay in their respective views/templates; shared facts and labels belong in the files above.

## Verification references

The build integration follows Apple's [custom build script guidance](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build) with explicit dependencies and the installed Xcode 26.6 build system. The native help uses the existing [SwiftUI openWindow API](https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow). Website regeneration uses [Wrangler custom builds](https://developers.cloudflare.com/workers/wrangler/custom-builds/), checked with Wrangler 4.131.2.
