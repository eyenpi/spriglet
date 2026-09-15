# Website and email setup

The app and App Store listing use **meetspriglet.com**. Activate these destinations before sending a build to App Review.

| Destination | Content or purpose |
| --- | --- |
| `https://meetspriglet.com` | Temporary redirect to support; product design is deferred |
| `https://meetspriglet.com/support` | Public support page using [support-page.md](support-page.md) |
| `https://meetspriglet.com/privacy` | The exact current [PRIVACY.md](../../PRIVACY.md), formatted for the website |
| `support@meetspriglet.com` | One address for app support, privacy questions, and deletion requests |

## Domain and hosting

1. The publisher has selected and added the domain to Cloudflare. Retain control of renewal and DNS.
2. Deploy the prepared [Cloudflare static website](website/README.md). Its custom-domain configuration manages DNS and certificates. Verify HTTPS and redirect HTTP to HTTPS.
3. Publish the support and privacy pages at the exact paths above, including mobile-readable layout and working navigation. The root temporarily redirects to support. When the product page is designed, keep support and privacy linked and preserve their URLs.
4. If `www.meetspriglet.com` is configured, redirect it to the canonical apex domain. The app does not depend on `www`.
5. Keep support and privacy publicly readable without sign-in, a purchase, or a broken consent overlay. Match the policy to the binary being reviewed. Add applicable publisher/contact disclosures for the chosen territories before submission.
6. Avoid adding advertising or analytics while the privacy answers describe the current local app and simple support flow. Reassess policy disclosures if website services change.

Cloudflare is the selected website host. The static website and deployment configuration are prepared in this repository. Live publication requires authenticated access to the owning Cloudflare account. An email vendor has not been chosen here; use the DNS values supplied by the chosen mail provider.

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
