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

`.gitleaksignore` contains the same two exact historical fingerprints as PR #45 for Pocket's local UserDefaults storage identifier in commit `5c3bfa6`. The all-ref scan includes the `feature/drop-to-mallow` history even though this branch has no intake source. PR #45 already changed that source to a shared preference-name constant in `dbcfb5f`. Published history remains intact; no rule, file or value is broadly excluded.

The security jobs in **Validate Spriglet** also run CodeQL for GitHub Actions, Python, and the unsigned macOS Swift app. No deployment or signing secret is available to these jobs. Dependabot maintains pinned GitHub Actions through reviewable pull requests. Branch rules and environment protections are configured in GitHub; repository files alone do not enforce them. See [SECURITY.md](../../SECURITY.md) for private reporting.
