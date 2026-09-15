# Website deployment and operations

The app and website share the sources in `Configuration/Shared` and the app icon catalog. CI verifies the generated output before uploading a static artifact. Product page design remains separate; the current root redirects to support.

## Deployment flow

1. **Validate Spriglet** waits for the owner's [CI approval](../CI/README.md) on each PR revision. It builds and checks without Cloudflare or Apple secrets. Successful approved PR builds upload `website-static` and `app-packages`, retained for seven days.
2. **Deploy website preview** follows only a successful approved PR workflow. Failed or canceled runs are filtered before allocating a runner. The uploader uses trusted code from protected `main`, checks the originating workflow, current PR commit, artifact identity/digest, and permitted files, and never executes PR source or artifact scripts/configuration.
3. A PR gets `meetspriglet-pr-N` on the account's `workers.dev` subdomain. The preview keeps shared artwork and content with trusted security headers and `noindex`. A new commit needs new CI approval before updating it. At most 20 previews may exist; remove closed previews using the cleanup command below.
4. Production updates and rollback are explicit local operations. Pushes, release tags, PR closure, and schedules do not launch deployment runners. Existing production content stays live until an explicit deployment.

The new `website-preview.yml` handler becomes active when merged into the default branch. The registered legacy build/security/deploy/monitor workflows remain disabled. External-contributor workflow approval is separate from the owner's `ci-review` approval; neither gives PR code deployment secrets.

## GitHub configuration

Create `website-preview` and `website-production` environments, each restricted to the `main` branch. Each needs:

- Environment secret `CLOUDFLARE_API_TOKEN`.
- Environment variable `CLOUDFLARE_ACCOUNT_ID`.

Use separate account-scoped API tokens. Preview needs Workers Scripts edit and Account Settings read. Production also needs the zone read and Workers Routes edit permissions required to maintain the custom domain, restricted to the production zone. Confirm the exact permissions against the deployment command and Cloudflare's current token UI. Avoid a global API key. A Workers edit token may affect all Workers in its permitted account; separate preview and production accounts provide a stronger boundary than distinct token names in the same account.

Keep Apple signing/upload secrets in the separate `app-store` environment, with owner approval. They are not used by website workflows. Do not put deployment secrets at repository scope or add them to PR build jobs. Review workflow/deployment changes as privileged code.

Set a 90-day token expiry and record its renewal date privately. Rotate each environment independently before expiry, verify a deployment using the replacement, then revoke the old token. Never commit tokens, paste them into issues, or use a personal Wrangler OAuth token as a CI credential.

The deployment tools use Node 24 in CI, pinned Wrangler, and `npm ci --ignore-scripts` from the lockfile. Dependency installation occurs before the step that receives the Cloudflare secret. Update dependencies through reviewed Dependabot PRs.

## Checks

```sh
python3 -m unittest discover -s tools/WebsiteDeployment -p 'test_*.py'
python3 tools/Security/run.py actionlint
npm ci --ignore-scripts --no-audit --no-fund --prefix tools/WebsiteDeployment
python3 tools/AppStore/website/check_http.py https://meetspriglet.com
```

Tests cover artifact traversal/links/duplicates/size limits, trusted headers, shared content preservation, workflow provenance, fork identity, stale/closed PRs, rollback restrictions, and cleanup of reopened PRs. The uploader also verifies the downloaded archive's SHA-256 against GitHub and checks exact public bytes after upload. A preview is untrusted public content; `noindex` is not authentication.

## Local publishing, cleanup, monitoring, and rollback

After merging and validating the intended production revision, use the authenticated local Cloudflare setup:

```sh
scripts/deploy-website.sh
python3 tools/AppStore/website/check_http.py https://meetspriglet.com
python3 tools/WebsiteDeployment/monitor.py
```

These commands do not start GitHub Actions. There is no periodic GitHub availability workflow. For a new production version, keep the validated revision and public output with the release records. Restore a known-good revision in an isolated checkout and run the same local deployment/HTTP checks; review its domain and security headers first.

Cleanup is also explicit. With the existing GitHub and scoped preview Cloudflare credentials supplied securely in the local environment (`GH_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`), run:

```sh
python3 tools/WebsiteDeployment/deploy.py cleanup --pr PR_NUMBER
```

The tool checks that the PR is closed and targets only its `meetspriglet-pr-N` Worker. It refuses to remove a reopened PR. A preview is retained until this cleanup; closing a PR alone no longer starts CI.

For recovery of deployments from before the CI migration, the local `deploy.py deploy --run RUN_ID --target production --rollback` command still accepts an unexpired successful legacy `validate.yml` main-push artifact after verifying its security checks. New PR artifacts cannot be used as production rollback. No workflow-dispatch handler remains.

When changing a domain or route design, review the deployment policy in `deploy.py`, the shared configuration, and HTTP checks together. The trusted route/header policy always comes from current `main`, including during rollback. Installed apps require an app release to receive changed bundled content; website deployment alone does not update them.

## Initial activation acceptance

- All required GitHub checks pass and branch rules enforce them.
- Both environments have scoped credentials and reject unauthorized refs.
- An approved PR creates a preview; a new commit waits for approval; local cleanup removes a closed preview.
- Malicious artifact/configuration fixtures are rejected before Cloudflare is called.
- Explicit local production deployment and restoration pass HTTP checks.
- Support mail works in both directions; domain renewal/recovery are configured.
- Local public availability checks succeed.

References: [GitHub workflow privileges](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows), [secure workflow design](https://docs.github.com/en/actions/reference/security/secure-use), [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [Cloudflare Actions setup](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/).
