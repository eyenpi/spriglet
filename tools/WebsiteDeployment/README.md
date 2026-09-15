# Website deployment and operations

The app and website share the sources in `Configuration/Shared` and the app icon catalog. CI verifies the generated output before uploading a static artifact. Product page design remains separate; the current root redirects to support.

## Deployment flow

1. **Validate Spriglet** builds and checks pull requests without Cloudflare or Apple secrets. Successful PR and `main` builds upload `website-static` (7-day PR retention, 90-day production retention).
2. **Deploy website** runs trusted code from protected `main`. It checks the originating workflow, run result, repository, current PR commit, artifact identity/digest, and permitted files. It never checks out PR source or runs artifact scripts/configuration.
3. A PR gets `meetspriglet-pr-N` on the configured account's `workers.dev` subdomain. The preview keeps the shared artwork and content, with trusted security headers and `noindex`. Closing the PR removes its preview. At most 20 previews may exist; close unused PRs to free capacity.
4. Production updates `meetspriglet-support` at the domain in `Configuration/Shared/brand.json`, after the current `main` validation and all security checks succeed. GitHub deployment status and the workflow summary show the published URL and commit. Each target is serialized, and stale runs are rechecked before publication.

Both deployment and cleanup workflows must be merged into the default branch before GitHub activates their event handlers. Same-repository PRs run automatically. GitHub requires maintainer approval for workflows from external contributors under this repository's configured fork policy. Approval of a build does not give its code deployment secrets.

## GitHub configuration

Create `website-preview` and `website-production` environments, each restricted to the `main` branch. Each needs:

- Environment secret `CLOUDFLARE_API_TOKEN`.
- Environment variable `CLOUDFLARE_ACCOUNT_ID`.

Use separate account-scoped API tokens. Preview needs Workers Scripts edit and Account Settings read. Production also needs the zone read and Workers Routes edit permissions required to maintain the custom domain, restricted to the production zone. Confirm the exact permissions against the deployment command and Cloudflare's current token UI. Avoid a global API key. A Workers edit token may affect all Workers in its permitted account; separate preview and production accounts provide a stronger boundary than distinct token names in the same account.

Keep Apple signing/upload secrets in the separate `app-store` environment, with owner approval. They are not used by website workflows. Do not put deployment secrets at repository scope or add them to PR build jobs. Review workflow/deployment changes as privileged code.

The deployment tools use Node 24 in CI, pinned Wrangler, and `npm ci --ignore-scripts` from the lockfile. Dependency installation occurs before the step that receives the Cloudflare secret. Update dependencies through reviewed Dependabot PRs.

## Checks

```sh
python3 -m unittest discover -s tools/WebsiteDeployment -p 'test_*.py'
python3 tools/Security/run.py actionlint
npm ci --ignore-scripts --no-audit --no-fund --prefix tools/WebsiteDeployment
python3 tools/AppStore/website/check_http.py https://meetspriglet.com
```

Tests cover artifact traversal/links/duplicates/size limits, trusted headers, shared content preservation, workflow provenance, fork identity, stale/closed PRs, rollback restrictions, and cleanup of reopened PRs. The uploader also verifies the downloaded archive's SHA-256 against GitHub and checks exact public bytes after upload. A preview is untrusted public content; `noindex` is not authentication.

## Monitor and rollback

After the initial public HTTPS check succeeds, set repository variable `WEBSITE_LIVE=true`. **Website availability** checks the domain every six hours and can be run manually. It checks routes, TLS, HTTPS redirection, and security headers without expecting every new `main` commit to be deployed immediately. Enable GitHub Actions failure notifications for the maintainer; inspect the run's failed step when notified. This is a periodic availability check, not an uptime SLA.

To retry the current production deployment, run **Deploy website** manually on `main` with an empty `run_id`. To restore a previous release, supply the numeric ID of a successful **Validate Spriglet** run triggered by a push to `main` whose artifact is still retained. PR/feature-branch builds cannot be promoted using rollback. Required security checks for the restored commit must have passed. Keep the known-good run ID with release records, and verify HTTPS after restoration. Download a production artifact before its retention expires if longer-term recovery is needed.

When changing a domain or route design, review the deployment policy in `deploy.py`, the shared configuration, and HTTP checks together. The trusted route/header policy always comes from current `main`, including during rollback. Installed apps require an app release to receive changed bundled content; website deployment alone does not update them.

## Initial activation acceptance

- All required GitHub checks pass and branch rules enforce them.
- Both environments have scoped credentials and reject unauthorized refs.
- A PR preview is created, updates after another commit, and is removed on closure.
- Malicious artifact/configuration fixtures are rejected before Cloudflare is called.
- Production deployment and restoration of a retained successful run pass HTTP checks.
- Support mail works in both directions; domain renewal/recovery are configured.
- Public availability workflow succeeds and failure notifications are configured.

References: [GitHub workflow privileges](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows), [secure workflow design](https://docs.github.com/en/actions/reference/security/secure-use), [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [Cloudflare Actions setup](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/).
