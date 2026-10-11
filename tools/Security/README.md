# Security checks

Run from the repository root:

```sh
python3 -m unittest discover -s tools/Security -p 'test_*.py'
python3 tools/Security/run.py actionlint
python3 tools/Security/run.py gitleaks
python3 scripts/check-public-files.py --history
```

The runner downloads actionlint and Gitleaks from their official GitHub releases, verifies a checked-in SHA-256 checksum, and executes the binary on Apple silicon macOS or x86_64 Linux. Downloads and reports remain under ignored `.build/`. Gitleaks scans all locally available Git refs and redacts detected values. Fetch relevant remote refs before a release audit; no scanner guarantees that every possible secret is detected.

Update versions and platform checksums together after reviewing [actionlint releases](https://github.com/rhysd/actionlint/releases) and [Gitleaks releases](https://github.com/gitleaks/gitleaks/releases). Never suppress an actual leaked credential just to make CI green: revoke it and investigate its exposure. The small public-file guard complements full secret scanning with project-specific file restrictions.

`.gitleaksignore` contains only the two exact historical fingerprints for Pocket's local UserDefaults storage identifier in commit `5c3bfa6`. Current source uses a shared preference-name constant to avoid the generic API-key heuristic. The historical fingerprints are necessary because a new commit cannot remove matches from published history; no rule, file or value is broadly excluded. See [Gitleaks fingerprint ignores](https://github.com/gitleaks/gitleaks/blob/v8.30.1/README.md#gitleaksignore).

Screenshot evidence lives under `art/screenshots/`. The public-file history check permits only the seven original path/blob pairs from the screenshot migration; working-tree and index checks still reject every `docs/` path. Historical blobs still undergo the content checks.

The security jobs in **Validate Spriglet** also run CodeQL for GitHub Actions, Python, and the unsigned macOS Swift app. No deployment or signing secret is available to these jobs. Dependabot maintains pinned GitHub Actions through reviewable pull requests. Branch rules and environment protections are configured in GitHub; repository files alone do not enforce them. See [SECURITY.md](../../SECURITY.md) for private reporting.
