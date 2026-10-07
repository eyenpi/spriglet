# Spriglet website

Static pages for **meetspriglet.com**, hosted with Cloudflare Workers Static Assets. The homepage introduces Mallow and leads visitors to the available Mac download. It uses the existing shared content generator, app identity and character palette, without a framework, analytics, form, database or email service.

## Content

- `/support`: [shared support source](../../../Configuration/Shared/support.md), also bundled as an offline resource. Mallow has a focus-preserving Help panel.
- `/privacy`: [shared privacy source](../../../Configuration/Shared/privacy.md), also rendered to root `PRIVACY.md` and the offline app policy.
- `/`: responsive homepage, generated from `home.html` and the shared website copy.
- Unknown paths: a proper `404` page with support and privacy links.

`public/` is the deployment directory. `build.py` invokes the [shared content generator](../../SharedContent/README.md), which renders the shared text and copies the app icon. Branding/contact details come from `Configuration/Shared/brand.json`; website introductions and companion naming come from `Configuration/Shared/website.en-US.json`. Spriglet is the app, spriglets are its companions, and Mallow is the first available spriglet. The homepage follows a warm paper and field-guide direction with self-hosted Instrument Serif headings and original inline Mallow vectors. Support and privacy retain their existing reading layout and system light/dark preference. The checked-in output is verified in CI. Semantic landmarks, a skip link, visible keyboard focus, reduced-motion handling and local assets are included. Security headers in `_headers` allow only local scripts/fonts; outbound connections and inline scripts/styles are blocked. Support and privacy remain script-free and explicitly block scripts.

## Homepage behavior and availability

`home.css` owns the responsive design. `home.js` reads only the visitor’s local clock. Morning is 05:00–11:59, afternoon 12:00–17:59, evening 18:00–21:59 and night 22:00–04:59. It updates at minute boundaries and refreshes after the tab returns; hidden tabs have no recurring clock timer. The website Mallow’s expression and palette are independent of the Mac app. Clicking or keyboard-activating Mallow gives a brief greeting; Reduce Motion keeps it still. Without JavaScript, the page retains an afternoon palette, static copy and working links; the decorative greeting button is disabled.

`home.storeURL` in `Configuration/Shared/website.en-US.json` is deliberately null until a real, released App Store listing is verified. The primary action scrolls to the download section, which links to the existing 0.3.0 GitHub preview and explains its signing and feature limitations. Set a verified, queryless `https://apps.apple.com/…/id…` product URL to switch the download text/link to the store and installation help. Never use a fabricated App Store ID. Availability copy belongs in the same source file.

Mallow SVG coordinates and colors follow the native artwork; they are website illustrations rather than a simulation of app physics. Fonts total about 54 KiB and are preloaded, self-hosted and licensed in `FONT-LICENSE.txt`; there are no raster hero images or remote font requests. SVG dimensions, reserved decorative space and `font-display: optional` avoid late font/layout swaps. See [artwork](../../../ASSETS.md).

## Edit and check

Run from the repository root:

```sh
python3 tools/AppStore/website/build.py
python3 tools/AppStore/website/build.py --check
python3 tools/AppStore/validate.py
python3 -m unittest discover -s tools/AppStore/website -p 'test_*.py'
python3 -m unittest discover -s tools/SharedContent -p 'test_*.py'
python3 -m unittest discover -s tools/WebsiteDeployment -p 'test_*.py'
./scripts/deploy-website.sh --dry-run
```

Edit `Configuration/Shared/privacy.md` to change the policy. Regeneration updates the root policy, bundled copy, and website together. Rebuild the app and prepare a new archive before submission. The website and reviewed binary must describe the same practices.

Website presentation copy is separate from the shared support and privacy documents. Changing the website's framing or CSS does not change the bundled policies or the submitted build. Preserve the reviewed support instructions and data practices when changing the presentation.

The favicon uses the current app icon, with a URL version derived from its image bytes. Icon changes refresh favicon references on every page automatically; ordinary regeneration keeps the URL stable. Local link checks resolve the URL's path independently of its query and fragment.

## Preview

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix tools/WebsiteDeployment
WRANGLER_SEND_METRICS=false tools/WebsiteDeployment/node_modules/.bin/wrangler dev -c tools/AppStore/website/wrangler.jsonc --ip 127.0.0.1 --port 8787
```

Open `http://127.0.0.1:8787/`. In a second terminal:

```sh
python3 tools/AppStore/website/check_http.py http://127.0.0.1:8787
```

## Browser checks

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix tools/AppStore/website
tools/AppStore/website/node_modules/.bin/playwright install chromium webkit
npm test --prefix tools/AppStore/website -- --workers=4
```

The test runner starts local Wrangler if it is not already running; no Cloudflare login or deployment is involved. It covers navigation and recovery, preview availability, keyboard greeting/skip/focus, rapid repeated greetings, clock/day boundaries, reduced motion, disabled JavaScript, 320px reflow and enlarged body copy, local requests, layout shifts, and axe WCAG A/AA checks across all four time palettes. Chromium runs at 390px, 768px and 1440px; WebKit runs at 1440px. Mac WebKit uses Option-Tab for links when Full Keyboard Access is off. Traces and logs go under ignored `.build/homepage/`. Manual screen-reader and physical-device acceptance are separate from these checks.

These checks run inside the existing owner-approved PR validation job; approval gates are unchanged. Changes to `_headers` require restarting an already-running Wrangler preview.

## Deploy to Cloudflare

Use the account that owns the active `meetspriglet.com` zone. Confirm the domain has no existing site that would be replaced. Authenticate Wrangler using Cloudflare's normal login flow; keep credentials outside the repository. If more than one account is available, set `CLOUDFLARE_ACCOUNT_ID` to the actual owning account for the command.

```sh
./scripts/deploy-website.sh
python3 tools/AppStore/website/check_http.py https://meetspriglet.com
```

Wrangler runs the shared generator automatically before dev/deploy; do not use `--no-bundle` to bypass the build. The deploy script also regenerates before Wrangler reads its configuration, so domain changes apply to the same deployment. The generated custom-domain configuration creates the Worker domain, its DNS record, and certificate through Cloudflare. Do not manually guess an origin IP or DNS target. `workers.dev` is disabled. Domain changes can take time to propagate; a successful deploy alone does not prove the public URLs work. Keep Cloudflare Web Analytics and optional content-injection features disabled for this local-only static site.

Check HTTP-to-HTTPS behavior and the public URLs after deployment. Support mailbox setup and a real send/reply check remain separate; see [website-setup.md](../website-setup.md). The [deployment workflow](../../WebsiteDeployment/README.md) builds isolated previews after approved PR validation. Publishing production content is a separate local operation with deployment credentials; merging or tagging an app release does not publish the website.

The root redirect has been removed. Preserve `/support` and `/privacy`, which are already used by the app and App Store metadata. The deployment allowlist includes the homepage CSS, local clock script and fonts; review it together with headers when adding assets. See the deployment README for the first-PR preview limitation while protected `main` still has the legacy allowlist.

## Official references

- [Cloudflare Static Assets](https://developers.cloudflare.com/workers/static-assets/get-started/)
- [Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
- [Redirects](https://developers.cloudflare.com/workers/static-assets/redirects/) and [headers](https://developers.cloudflare.com/workers/static-assets/headers/)
- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)

Wrangler 4.147.0 is pinned in the deployment lockfile and local publishing script. These references were checked on September 15, 2026.
