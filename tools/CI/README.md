# CI approval and runner usage

Only pull requests to `main` request CI. Opening, reopening, updating, or marking a PR ready creates a **Validate Spriglet** run that waits for approval. Branch pushes without a PR, `main` pushes, tags, schedules, comments, and reviews do not start builds. There is no manual workflow-dispatch bypass.

## Approve a PR run

1. Open the PR's **Checks** tab and the **Validate Spriglet** run.
2. Review the proposed commit, especially workflow and deployment changes.
3. Select **Review deployments**, select **ci-review**, then **Approve and deploy**.

GitHub uses deployment wording for this button. It approves CI execution; it does not publish an app release or change the production website. The owner (`eyenpi`) can approve their own run. Rejecting it stops the checks. Waiting for approval does not allocate a runner.

The first job (`security-checks`) runs credential checks, workflow lint, and the approval freshness tests. Only after it succeeds do the Mac validation/build/package job and CodeQL jobs run. A successful complete workflow supplies the website preview and installable preview artifacts. CI has no Apple or Cloudflare secrets.

A new commit cancels the previous pending/running workflow and requests new approval. Each job also checks the current PR head and base before expensive work; closed, draft, retargeted, or outdated PRs are refused. If `main` changes while a run waits, update the PR branch and approve the resulting run. Keep draft runs waiting until the PR is ready. A maintainer can retry failed jobs for the same approved commit from the Actions UI; stale retries are rejected by the freshness check.

## Toolchains

Every macOS job selects an explicit, pinned Xcode instead of the runner image's default. [toolchains.json](toolchains.json) is the single source of truth:

| Pin | Runner | Xcode | macOS SDK | Swift | Used by | Why |
| --- | --- | --- | --- | --- | --- | --- |
| `build` | `xcode-27` | 27.0 | 27.0 | 6.4 | `macos` | The documented release toolchain. Builds, tests, packages, and compiles the macOS 27 FoundationModels error mapping. |
| `codeql` | `macos-26` | 26.6 | 26.5 | 6.3 | `codeql-swift` | CodeQL analyzes Swift 5.4 through 6.3 only. This also proves the app still builds with the macOS 26 SDK. |

`python3 tools/CI/select_xcode.py <pin>` finds that Xcode and verifies the Xcode, SDK, and Swift versions. It then exports `DEVELOPER_DIR` for later steps, with no `sudo` and no `xcode-select`. A pin names a release line: `27.0` accepts 27.0.x but not 27.1. Any drift fails the job, listing each mismatched field. Separately, the `SprigletIntelligence` tests fail if the package is ever built without the Xcode 27 SDK.

Check a local toolchain against CI before a PR:

```sh
python3 tools/CI/select_xcode.py build --check
```

`xcode-27` is GitHub's preview image for Xcode 27. It may queue longer than `macos-26` until GitHub makes it generally available. The `.github/actionlint.yaml` file declares the label because the pinned actionlint predates it.

To upgrade a toolchain:

1. Change its entry in `toolchains.json` and the matching `runs-on` in [pr-ci.yml](../../.github/workflows/pr-ci.yml) in the same PR.
2. Update the build statement in the root README.

`test_select_xcode.py` fails if a pin and its workflow job disagree. It also fails if the build pin loses the Xcode 27 SDK, or if the CodeQL pin moves beyond CodeQL's supported Swift range.

The `macos` job uploads its JSON validation reports as the `validation-reports` artifact, even when a step fails. CI never runs the on-device model; its runners have no Apple Intelligence.

## Repository configuration

The `ci-review` environment is required infrastructure; configure it **before** enabling `.github/workflows/pr-ci.yml`:

- Required reviewer: repository owner `eyenpi`.
- Prevent self-review: off, so the owner can approve their own PR runs.
- Administrator bypass: off.
- Selected deployment branches: `refs/pull/*/merge`, type **branch**; no tag rules.
- No environment secrets or variables.

Do not remove the environment reference or job dependencies to unblock a PR. Environment settings are administered separately from Git; changes to them require repository administration. GitHub's external-contributor approval policy remains enabled and is separate from this CI gate.

Main branch rules continue to require `security-checks`, `macos`, `codeql-actions`, `codeql-python`, and `codeql-swift`, as well as the existing CodeQL security threshold. The old `validate.yml`, `security.yml`, `website-deploy.yml`, and `website-monitor.yml` workflows are retired. Disable their registered workflows during migration so old PR revisions cannot launch them. The replacement has a distinct workflow filename and can be reviewed without re-enabling those old triggers.

The new `website-preview.yml` handler becomes active when the replacement is merged into `main`. It runs only after successful PR validation, and checks the originating workflow file and current PR revision before uploading static files. Failed, canceled, or rejected validation allocates no deployment runner. See [website operations](../WebsiteDeployment/README.md).

Release tags do not trigger CI or publication. Build/publish a release explicitly using the [local packaging](../ReleaseValidation/README.md) and [release publisher](../ReleaseNotes/README.md). Production website publishing, preview cleanup, and availability checks are explicit local operations. Existing public releases and the live website remain available.

## Local checks for workflow changes

```sh
python3 -m unittest discover -s tools/CI -p 'test_*.py'
python3 tools/CI/select_xcode.py build --check
python3 -m unittest discover -s tools/Security -p 'test_*.py'
python3 -m unittest discover -s tools/WebsiteDeployment -p 'test_*.py'
python3 tools/Security/run.py actionlint
python3 tools/Security/run.py gitleaks
python3 scripts/check-public-files.py --history
```

Verify the GitHub environment and pending run through the API/UI too: local YAML validation cannot prove repository protection settings. Leave the first run at the approval gate until the owner chooses to spend runner time. Do not weaken main's required checks to merge the migration.

References: [GitHub environment protection before runner allocation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idenvironment), [reviewing pending jobs](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments), [PR environment branch patterns](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
