# Security

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/eyenpi/spriglet/security/advisories/new). Include the affected version or commit, steps to reproduce, expected impact, and a minimal example. Remove personal desktop content and credentials from diagnostics. Please keep exploitable details out of public issues until a fix or mitigation is available.

The maintainer reviews reports and coordinates fixes through the private advisory. There is no paid support SLA or bug bounty. If you cannot use GitHub's private reporting, use the contact route on the [support page](https://meetspriglet.com/support) once it is operational.

## Supported versions

Spriglet is currently a source preview. Security fixes target the latest development source on `main`; older preview tags are not maintained separately. Signed App Store distribution is pending. Once released, install the latest available App Store update.

## Security boundaries

The app is sandboxed and stores its preferences locally. It has no account, analytics SDK, or application backend. Reassess these statements before adding a service or dependency. See [the privacy policy](PRIVACY.md).

Pull request code must never receive Cloudflare deployment or Apple signing credentials. Review changes to workflows, deployment tools, shared policies, and signing configuration carefully. Public artifacts and logs must not contain credentials or private diagnostics. Report an exposed credential immediately so its owner can revoke it.
