# Website and email setup

The app and App Store listing use **meetspriglet.com**. Activate these destinations before sending a build to App Review.

| Destination | Content or purpose |
| --- | --- |
| `https://meetspriglet.com` | Product page using [product-page.md](product-page.md) |
| `https://meetspriglet.com/support` | Public support page using [support-page.md](support-page.md) |
| `https://meetspriglet.com/privacy` | The exact current [PRIVACY.md](../../PRIVACY.md), formatted for the website |
| `support@meetspriglet.com` | One address for app support, privacy questions, and deletion requests |

## Domain and hosting

1. Register the domain under the publisher's account and retain control of renewal and DNS.
2. Connect the apex domain to the selected website host using that host's actual DNS instructions. Set up HTTPS with a valid certificate and redirect HTTP to HTTPS.
3. Publish the three pages at the exact paths above, including mobile-readable layout and working navigation. Configure redirects if the host uses trailing slashes. The root product page must link to support and privacy.
4. If `www.meetspriglet.com` is configured, redirect it to the canonical apex domain. The app does not depend on `www`.
5. Keep support and privacy publicly readable without sign-in, a purchase, or a broken consent overlay. Match the policy to the binary being reviewed. Add applicable publisher/contact disclosures for the chosen territories before submission.
6. Avoid adding advertising or analytics while the privacy answers describe the current local app and simple support flow. Reassess policy disclosures if website services change.

No registrar, hosting provider, DNS target, or email vendor is assumed. Use the DNS values supplied by the services you actually choose. Page content is prepared here; hosting and DNS activation are not performed by this repository.

## Mailbox

Create **support@meetspriglet.com** as a mailbox, or an alias/forwarder that also permits replies using that address. A second privacy address is unnecessary: support and privacy requests use this same monitored inbox.

- Configure the provider's MX, SPF, DKIM, and DMARC instructions. Avoid creating conflicting SPF records if another service already uses the domain.
- Send a message from an unrelated provider to the address and confirm delivery.
- Reply from `support@meetspriglet.com` and check that the recipient receives the reply with the intended sender address.
- Confirm somebody will monitor it during App Review and after release. Apply the support-correspondence retention/deletion policy in `PRIVACY.md`.
- Never commit mailbox credentials or account recovery details. The public email address itself is intentionally included in the app and metadata.

App Review can use the same email address once monitored. Enter the review contact name **Ali Nabipour** and a real reachable telephone number privately in App Store Connect. The telephone number is still needed; it is not invented here. EU trader contact information and any other legally required disclosures must reflect the actual publisher and be completed in the account.

## Before marking these destinations ready

- [ ] HTTPS opens all three pages without a certificate error or sign-in.
- [ ] `/support` visibly includes a working email link and useful help.
- [ ] `/privacy` matches `PRIVACY.md` and the bundled `PrivacyPolicy.md` in the reviewed build.
- [ ] Support mail delivery and replies have been tested.
- [ ] The app's Read Online, Get Support, and Email Support controls open the expected destinations.
- [ ] Any required publisher/trader disclosures are present and accurate.
- [ ] After approval, add the real App Store product link to the product page. Do not invent an App Store ID or claim that the app is already available before release.

Apple requires a support URL with contact information and a public privacy-policy URL: [platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information), [app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).
