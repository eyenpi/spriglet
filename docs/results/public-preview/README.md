# Preview evidence and historical snapshot

These reports retain the actual app, UI, and asset checks performed for the September 13 preview. Their recorded source and artifact hashes define their scope. Current original-repository preparation is recorded [separately](../repository-preparation/verification.json).

- `public-validation.json` and its linked reports checked the clean exported app code and animation assets. Those same code/assets were retained in the original repository.
- `snapshot-provenance.json` is the exact historical file-export manifest. Its `historyIncluded: false` field describes that exported directory only. The original Spriglet repository retains its Git history.
- `snapshot-sample-verification.json` and `snapshot-icon-verification.json` preserve the exact verifier reports referenced by that manifest. Current authoring verifiers write their results under `art/sprout` after the evidence pointer was relocated.
- `retired-repository-receipt.json` is the historical receipt for the former separate repository. Its remote links, commit, CI run, and release asset IDs refer to that former publication, not to `eyenpi/spriglet` or its current release.

Historical measurements and success hashes have not been rewritten to imply checks against a different tree. No rerender was performed when retaining the metadata-cleaned assets.
