# Mac App Store submission

Use the exact version/build and source revision in the archive's `local-validation.json`. The release changelog and App Store use the same numeric version. Confirm that the build number exceeds the last upload in App Store Connect before committing and archiving. Never submit a dirty rehearsal or reuse screenshots from another candidate.

## Account and build

Verify membership, app ownership, agreements and the registered `dev.spriglet.app` identifier in the owning Apple account. Account-only tax, banking, trader status and contact details must reflect the actual publisher; source validation cannot verify them. This app is free and has no purchases or subscriptions. Do not create or accept agreements as part of a local archive check.

Archive with the owning team, validate in Xcode Organizer, then export for App Store Connect. Do not let export change version or build. Verify the exported application's distribution signature with the validator, retain Apple's validation result and package checksum, and install/test that same exported build before uploading. After processing, select its matching build in App Store Connect. Choose manual release so approval can precede public availability.

## Listing and screenshots

Use `submission-metadata.en-US.json` and `review-notes.txt` from the archive output. They contain the exact description, keywords, category, free price, copyright, support/privacy URLs and account-free review instructions. Reviewer contact is Ali Nabipour; enter the reachable phone and monitored support email privately in App Store Connect. Do not fabricate a telephone number or demo credentials.

The icon catalog contains the opaque 1024-pixel Mac icon. Verify its provenance with `python3 art/app-icon/verify_icon.py`. Use 1–10 actual screenshots per locale at an Apple-supported 16:10 size: 1280×800, 1440×900, 2560×1600 or 2880×1800. Capture the exported build's resting peek, invited character, Settings and Meet Mallow on a clean desktop. Check every image for private content and inaccurate features, then run the screenshot validator. Save checksums and capture details with the archive records. Optional preview video is unnecessary for submission.

## Privacy and age rating answers

The app collects no data off the device and does not track. Choose **Data Not Collected** in App Privacy. It has no analytics, advertising, server, account, third-party SDK, purchase, screen capture or global keyboard monitor. Local size, movement/home preferences and introduction dismissal stay in app-owned UserDefaults. No interaction history is saved. The privacy manifest declares CA92.1 for app-owned defaults and 35F9.1 for elapsed animation timing. No camera, microphone, location, screen recording or Accessibility permission is requested. There is no ATT flow. The encryption declaration is `ITSAppUsesNonExemptEncryption = false`.

Answer the age-rating questionnaire for the actual content: no messaging/chat, user-generated content, advertising, unrestricted web access, parental controls, age assurance, medical/treatment content, gambling, contests, violence, weapons, sexual content, nudity, profanity, mature themes, horror or substance references. Use None for content-frequency questions and No for these capabilities; let Apple calculate the rating. There is no override or minimum-age gate. Support/privacy links are external help destinations, not an in-app browser.

Before upload, publish the generated support/privacy site and run `python3 tools/AppStore/website/check_http.py https://meetspriglet.com` against this revision. Verify the support mailbox receives and replies using its published address separately. A functioning URL alone does not prove the mailbox works. No permission descriptions or tracking domains should be added unless implementation begins using them.

## Acceptance of the packaged build

Record the package checksum, app version/build, source revision, Mac model, macOS version and display arrangement. Test the installed exported app, rather than the Xcode product or lifecycle fixture:

- Reach the leaf menu with Control-F8, arrows and Return. Open Settings and traverse every enabled control using Tab/Shift-Tab; choose popup values with arrows and operate buttons/checkboxes with Space. Verify Command-comma, Command-Shift-H/P/M and Command-W while active.
- With VoiceOver, find Mallow, hear its changing state and use Invite, Swing, Stretch, Bring Home, Pause/Resume, Hide, Settings and Meet Mallow. Recover after Hide through the leaf and Finder, without a precise drag. Test popup values, checkbox state and approval/error feedback in Settings.
- Turn Reduce Motion on before launch and during hover, invitation, wave/swing/stretch, grab, fall, catch, landing and return. Verify still transitions, responsive dragging, direct home recovery on release, blinking and still introduction steps. Turning it off must not replay cancelled travel.
- Test outside-click return, transparent margins, missed release, Hide/Pause, first/repeated launch, Settings persistence, quit/reopen, physical sleep/wake, screen lock/unlock, fullscreen/Spaces and display loss/reconnect. Recovery must preserve Pause and remain reachable through the menu.
- On the signed installation, test default-off login launch, explicit enable/disable, pending approval, external changes, error feedback and an actual sign-out/sign-in. Confirm one companion and inspect sustained idle resource use.

Synthetic native tests verify routing and policy; they do not establish spoken VoiceOver, physical transition delivery, signed login launch or battery use. Do not advertise an Accessibility Nutrition Label until Apple's evaluation criteria have been checked on this exported build. Retain failures and unresolved results, rather than marking them passed.

When all required evidence and account fields are complete, upload, wait for successful processing, confirm the version/build and screenshots, add the version to review and submit. Record the Apple submission identifier and visible status. Archive creation, upload and adding to review are separate from a successful submission.

References: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), [App Privacy](https://developer.apple.com/app-store/app-privacy-details/), [VoiceOver evaluation](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria), [Reduced Motion evaluation](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria), [submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).
