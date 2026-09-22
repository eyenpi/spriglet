# Mac App Store submission

This is the repeatable submission workflow for Spriglet, a **free macOS app for Apple silicon, requiring macOS 26 or later**. Local checks establish specific build properties; they do not establish Apple acceptance or complete the account and device checks below.

## Current preparation

The repository includes a sandbox entitlement, complete Mac app icon catalog, Entertainment category, encryption declaration, privacy manifest, offline Privacy Policy and MIT license, accessible support links, English listing copy, and a local archive validator. The listing in [`metadata/en-US.json`](metadata/en-US.json) is a draft for App Store Connect. The build identifier remains `dev.spriglet.app`; register and confirm that exact identifier with the intended Developer team before uploading.

**Before submission:** verify the public support and privacy pages at **meetspriglet.com**, activate **support@meetspriglet.com**, finish Apple Developer signing, capture screenshots, and complete the account forms and final device acceptance. The app and listing already use these final URLs; their live operation remains a release gate. The [Cloudflare website](website/README.md) temporarily directs the root to support; product page design is deferred. Use the [website and email handoff](website-setup.md) to finish setup.

The code has no purchases, subscriptions, accounts, analytics, ads, third-party runtime SDKs, or network client. Store price is Free. A free release still requires Apple Developer Program membership.

## 1. Account and identity

- [ ] Confirm Developer Program membership, the publishing team, and the account's current agreements in App Store Connect. An Account Holder handles agreements and legal declarations.
- [ ] Confirm the app name is available in App Store Connect. The candidate display name is **Spriglet: Desktop Companion**, with **meetspriglet.com** as the selected domain. Domain availability does not establish App Store name availability or rights to a name.
- [ ] Register the explicit App ID, then create a **macOS** app record with the same bundle identifier, English primary language, and a unique internal SKU. Do not change the bundle ID after the first uploaded build without considering app identity and saved preferences.
- [ ] Add the team account in Xcode Settings > Accounts and configure valid signing credentials. Keep certificates, private keys, profiles, and account details out of Git.
- [ ] Set **Free** pricing and choose the intended territories. Complete trader/non-trader status for EU availability based on the publisher's actual circumstances; being free does not answer that question.

Apple references: [App Store Connect workflow](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow), [add an app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app), [EU trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).

## 2. Build and validate locally

Use the final source checkout and the pinned build toolchain: Xcode 27.0 (27A266a). Run `python3 tools/CI/select_xcode.py build --check` to confirm yours matches. CI builds, packages, and rehearses the unsigned archive with the same pin; see [CI toolchains](../CI/README.md#toolchains). Only CodeQL's Swift analysis uses Xcode 26.6. Apple opened [App Store submissions for Xcode 27](https://developer.apple.com/news/?id=k1mtkt1k) on September 9, 2026. Recheck Apple's [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) on the actual upload date. SDK upload requirements and the app's minimum supported OS are separate: Spriglet remains Apple silicon only with a macOS 26 minimum.

```sh
./scripts/test.sh
python3 -m unittest discover -s tools/AppStore -p 'test_*.py'
python3 tools/AppStore/validate.py
./scripts/build.sh Debug
./scripts/build.sh Release
python3 tools/AppStore/validate.py --app .build/xcode/Build/Products/Release/Spriglet.app
```

Record changes in the [changelog workflow](../ReleaseNotes/README.md). Use a numeric app version and increase the build before uploading changed binaries. The archive uses the checked-in version/build and verifies the bundled changelog; the script cannot silently override them.

Rehearse an archive without credentials:

```sh
scripts/archive-app-store.sh --unsigned --check
scripts/archive-app-store.sh --unsigned --output .build/app-store/rehearsal
```

The output contains `Spriglet.xcarchive`, a build log, and `local-validation.json`. An `UNSIGNED-REHEARSAL.txt` file identifies the non-uploadable archive. Failed operations retain `INCOMPLETE`. Output directories are never reused. Generated files and machine-specific reports stay under ignored `.build/`.

The validator checks:

- Metadata lengths, HTTPS URL shape, free pricing, and agreement with in-app links.
- Sandbox policy, Entertainment category, no non-exempt encryption, and the menu-bar app declaration.
- The audited privacy reasons, exact bundled policy/license/changelog, and all ten Mac icon slots.
- Source-to-bundle character resource equality, a single arm64 executable, macOS deployment target, and absence of quarantine attributes.
- Archive metadata and matching executable/dSYM UUIDs. The signed mode additionally checks a trusted team signature, sandboxing, and absence of debug entitlements.

It does not validate URL content, certificate availability in a source-only preflight, provisioning at Apple, screenshot truthfulness, support contacts, name rights, legal forms, or real-world accessibility. The report deliberately never declares `submissionReady: true`.

## 3. Create the signed archive

With a real ten-character team ID and the registered app ID:

```sh
scripts/archive-app-store.sh --team-id TEAM_ID --bundle-id dev.spriglet.app \
  --output .build/app-store/signed
```

Replace `TEAM_ID` before running. If Xcode needs to create or refresh profiles, add `--allow-provisioning-updates`; this explicitly permits Xcode to contact Apple for signing. The signed archive path uses Xcode automatic development signing. Organizer handles distribution signing with the App Store team. It does not use the separate Developer ID notarization ZIP workflow.

1. Open `Spriglet.xcarchive` in Xcode Organizer.
2. Run **Validate App** for App Store Connect and resolve every error and relevant warning.
3. Generate and review Xcode's privacy report for the exact archive, including all bundled code.
4. Choose **Distribute App > App Store Connect** and review the signing and upload summary.
5. Upload the intended build, wait for processing, and resolve processing warnings. Keep its symbols and source commit.

The script never exports or uploads. For a signed archive it writes `ExportOptions.plist` with the current `app-store-connect` method, automatic signing, the selected team, symbol upload, and automatic version changes disabled. For command-line local export, use Xcode's `-exportArchive` with that file. Signed export and upload require a real account and are not covered by unsigned rehearsal.

Use the standard App Store Connect distribution route if the build will later be submitted. **TestFlight Internal Only** builds cannot be submitted to the App Store. References: [distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [TestFlight restrictions](https://developer.apple.com/tutorials/develop-in-swift/test-your-beta-app).

## 4. Privacy and other declarations

### App privacy

For the audited implementation, the proposed App Privacy answer is **Data Not Collected**. Apple distinguishes processing that stays on device from data collection. Reassess if any service, SDK, automatic reporting, or network communication is added. The privacy manifest and the App Store privacy questionnaire are separate requirements. [Apple's definitions](https://developer.apple.com/app-store/app-privacy-details/).

| Access | Source and purpose | Manifest reason |
| --- | --- | --- |
| App preferences | `PetPreferencesStore` and first-run guide; only Spriglet's own defaults | `CA92.1` |
| System uptime | `ProcessSample`, `RuntimeProbe`, `SoakProbe`; elapsed time between in-app events and timeout calculations | `35F9.1` |

Only elapsed durations are included in optional copied reports; absolute system uptime is not exported. Raw report files can include local paths and process details, so review them before sharing. No third-party SDK manifest is needed for the current dependency inventory. Apple's [required-reason API list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons) governs the reasons; inspect any future API addition rather than treating the current allowlist as universal.

- [ ] Publish the final privacy policy at a public HTTPS URL that works without sign-in. Its content must match the build's behavior and bundled copy.
- [ ] Publish a public support page with actual contact information. Apple's [Support URL requirements](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) call for contact details; an issue tracker alone is not the completed plan.
- [ ] Edit policy text in `Configuration/Shared/privacy.md` and run `python3 tools/SharedContent/sync.py`. The app, root policy, and website are generated together; the validator rejects stale output. See the [shared content guide](../SharedContent/README.md).
- [ ] Complete the App Store Connect privacy answers after auditing the final binary and all dependencies.

### Age rating, content rights, encryption, and accessibility

- [ ] Complete the **current** age-rating questionnaire. The present app has no public user-generated content, chat, advertising, unrestricted embedded web browsing, gambling, contests, mature themes, or medical advice. Naming one's local pet is not public user-generated content. Answer the actual form; Apple calculates the rating. Do not select Kids Category merely because the artwork is cute. [Set an age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating).
- [ ] Answer the social-media capability questions now required by the current age-rating form. The audited app has no social feed, public sharing, or interaction with user-generated content. Reassess these answers if those capabilities are added. [Apple's questionnaire update](https://developer.apple.com/news/?id=tlur8uvi).
- [ ] Confirm content rights for code, artwork, sound, icon, and screenshots using [ASSETS.md](../../ASSETS.md) and the bundled MIT license. Choose any custom store license deliberately; no custom EULA is supplied here.
- [ ] Confirm export-compliance answers for the final implementation. `ITSAppUsesNonExemptEncryption = false` records that it does not use non-exempt encryption; it is not a blanket exemption for future features. [Encryption declaration](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption).
- [ ] Complete any currently requested regulatory forms from actual product facts. No medical function is present.
- [ ] Publish Accessibility Nutrition Labels only after testing each claimed feature against Apple's criteria, including the entire relevant user journey. Native accessibility APIs alone do not establish a VoiceOver claim. [Accessibility labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels).

## 5. Listing and screenshots

Copy the English fields from [`metadata/en-US.json`](metadata/en-US.json) into App Store Connect after product/name/contact review. Category is Entertainment. The description explains Apple silicon and macOS 26 requirements, menu-bar access, and actual shipped functionality. It contains no preview or beta promises. No sign-in information or purchase setup is needed.

Capture the **actual final app** on a clean desktop with no private content. Use 1–10 screenshots, consistently at one supported 16:10 size: **1280×800, 1440×900, 2560×1600, or 2880×1800**. For this workflow, export 8-bit RGB PNGs without alpha. Apple also accepts JPEG. A video preview is optional. The existing asset-assembled animation demo is not a screenshot of the app. [Screenshot dimensions](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), [upload requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots).

Suggested sequence:

| Image | Actual app content to capture |
| --- | --- |
| 01 — Quiet company | Sprout at its normal size on an uncluttered desktop, with the leaf menu visible |
| 02 — Make it yours | Companion Settings showing name, size, frequency, and Parked Mode |
| 03 — A moment of play | Actual firefly interaction with a clearly visible companion |
| 04 — Stay in control | Desktop Settings with Pause, Hide, Pass Clicks Through, and placement controls |
| 05 — Local by design | General Settings with optional sound/login and Privacy Policy access |

Do not present prototypes from `art/candidates` as shipped choices. Avoid unrelated apps, wallpaper you cannot use commercially, private menu-bar details, and features that are only planned. Store screenshots must be reviewed visually even after the file checks pass.

```sh
python3 tools/AppStore/validate.py --screenshots .build/app-store/screenshots/en-US
```

The screenshot command checks PNG dimensions, count, color format, and decoding. It fails for a missing or empty directory. It does not create screenshots or label missing media as complete.

## 6. Final device acceptance

Use the signed TestFlight build installed in a stable location, including a clean user account and another Apple silicon Mac. Record evidence by version, build, hardware, and OS under ignored `.build/` or `docs/`. A previous development build is not evidence for a new submitted build.

- [ ] First launch: Quick Guide appears once; Get Started, leaf menu, Settings, and Quit are discoverable without a Dock icon.
- [ ] Pet, drag, all sizes, firefly, parked/unparked activity, home, and next display behave correctly.
- [ ] Pause, hide, click-through, and Reduce Motion immediately stop the appropriate work. Controls remain reachable with the pet hidden.
- [ ] Restart preserves intended choices; clear recent preferences does not restore old values from the recovery copy.
- [ ] Small and large displays, Retina scaling, dock/menu-bar positions, display unplug/replug, Spaces, and full-screen apps keep placement and controls usable.
- [ ] Real sleep/wake, lock/unlock, fast user switching if supported, Low Power Mode, and extended idle do not cause runaway animation or CPU use.
- [ ] Check the release with Instruments/Activity Monitor over a representative session, including prolonged idle and battery operation. The finite soak below does not certify battery impact.
- [ ] With consent on the test Mac, verify actual sound quality and enable/disable login registration. Test the next login, approval-pending state, and disabling the item. Do not change the development machine's login state merely to run a unit test.
- [ ] Complete real VoiceOver reading/action navigation, full keyboard navigation, contrast, light/dark appearance, and Reduce Motion checks before making store accessibility claims.
- [ ] Verify Privacy Policy and License offline; verify support and online policy in a logged-out browser. Confirm direct contact information on the support page.
- [ ] No crashes, permission surprises, broken links, placeholder content, or advertised-but-unavailable functionality.

Existing local regression commands, after quitting any running Spriglet copy:

```sh
./scripts/probe.sh > .build/probe.json
./scripts/soak.sh > .build/soak.json
bash tools/EverydayServicesValidation/build.sh
tools/EverydayServicesValidation/.build/EverydayServicesCheck \
  --resources Sources/Spriglet/Resources/PetSounds --output .build/everyday-services.json
```

The probe and 100-cycle soak exercise local runtime behavior with saved-choice changes suppressed. Silent service checks use test adapters. Neither replaces actual login, listening, physical lifecycle, or VoiceOver acceptance.

## 7. Submit

- [ ] Select the processed build that passed acceptance; finish metadata, screenshots, privacy, age rating, availability, and encryption questions.
- [ ] Enter an App Review contact name, email, and telephone number privately in App Store Connect. These are not repository metadata or the public support contact.
- [ ] Use the supplied review notes to explain menu-bar-only launch, the transparent pet window, consent-based login, Reduce Motion, and optional diagnostics.
- [ ] Choose a release option deliberately; manual release allows a final check after approval.
- [ ] Review Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), particularly completeness (2.1), accurate metadata (2.3), Mac sandbox/distribution requirements (2.4.5), sufficient functionality (4.2), and privacy (5.1.1). The companion should stand on its finished interactive experience.
- [ ] **Add for Review**, then open the draft submission and **Submit for Review**. Adding an app to a draft does not send it to Apple. [Submission steps](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).

After approval, verify the actual store page, price, download, support links, and installed app before announcing availability. Keep the archive, symbols, exact commit, and completed acceptance record for support.

## Platform references checked during implementation

In addition to the submission references above, the implementation uses current [SwiftUI Link](https://developer.apple.com/documentation/swiftui/link), [LSApplicationCategoryType](https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype), and [privacy-manifest structure](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest). The installed SwiftUI interface and Xcode 26.6 `xcodebuild -help` confirmed availability and the nondeprecated `app-store-connect` export method. Recheck these references when changing toolchains.
