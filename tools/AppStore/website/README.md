# Support and privacy website

Static pages for **meetspriglet.com**, hosted with Cloudflare Workers Static Assets. The root temporarily redirects to `/support`; the product page will be designed separately. No framework, client script, analytics, form, database, or email service is included.

## Content

- `/support`: [shared support source](../../../Configuration/Shared/support.md), also bundled in the app's Help & Support window.
- `/privacy`: [shared privacy source](../../../Configuration/Shared/privacy.md), also rendered to root `PRIVACY.md` and the offline app policy.
- `/`: temporary `302` redirect to `/support`.
- Unknown paths: a proper `404` page with support and privacy links.

`public/` is the deployment directory. `build.py` invokes the [shared content generator](../../SharedContent/README.md), which renders the shared text and copies the app icon. Branding/contact details come from `Configuration/Shared/brand.json`. The checked-in output is verified in CI. Navigation, system fonts, light/dark colors, keyboard focus, and a skip link are included. Security headers are configured in `_headers`.

## Edit and check

Run from the repository root:

```sh
python3 tools/AppStore/website/build.py
python3 tools/AppStore/website/build.py --check
python3 tools/AppStore/validate.py
./scripts/deploy-website.sh --dry-run
```

Edit `Configuration/Shared/privacy.md` to change the policy. Regeneration updates the root policy, bundled copy, and website together. Rebuild the app and prepare a new archive before submission. The website and reviewed binary must describe the same practices.

## Preview

```sh
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.131.2 dev -c tools/AppStore/website/wrangler.jsonc --ip 127.0.0.1 --port 8787
```

Open `http://127.0.0.1:8787/support`. In a second terminal:

```sh
python3 tools/AppStore/website/check_http.py http://127.0.0.1:8787
```

## Deploy to Cloudflare

Use the account that owns the active `meetspriglet.com` zone. Confirm the domain has no existing site that would be replaced. Authenticate Wrangler using Cloudflare's normal login flow; keep credentials outside the repository. If more than one account is available, set `CLOUDFLARE_ACCOUNT_ID` to the actual owning account for the command.

```sh
./scripts/deploy-website.sh
python3 tools/AppStore/website/check_http.py https://meetspriglet.com
```

Wrangler runs the shared generator automatically before dev/deploy; do not use `--no-bundle` to bypass the build. The deploy script also regenerates before Wrangler reads its configuration, so domain changes apply to the same deployment. The generated custom-domain configuration creates the Worker domain, its DNS record, and certificate through Cloudflare. Do not manually guess an origin IP or DNS target. `workers.dev` is disabled. Domain changes can take time to propagate; a successful deploy alone does not prove the public URLs work. Keep Cloudflare Web Analytics and optional content-injection features disabled for this script-free site.

Check HTTP-to-HTTPS behavior and the public URLs after deployment. Support mailbox setup and a real send/reply check remain separate; see [website-setup.md](../website-setup.md). The [deployment workflow](../../WebsiteDeployment/README.md) builds isolated PR previews and publishes validated `main` builds after its default-branch activation and protected environment setup.

When the product design is ready, replace `index.html` generation and remove the temporary root redirect in `_redirects`. Preserve `/support` and `/privacy`, which are already used by the app and App Store metadata.

## Official references

- [Cloudflare Static Assets](https://developers.cloudflare.com/workers/static-assets/get-started/)
- [Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
- [Redirects](https://developers.cloudflare.com/workers/static-assets/redirects/) and [headers](https://developers.cloudflare.com/workers/static-assets/headers/)
- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)

Wrangler 4.131.2 and these references were checked on September 15, 2026.
