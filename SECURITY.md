# Security

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/eyenpi/spriglet/security/advisories/new). Include the affected version or commit, steps to reproduce, expected impact, and a minimal example. Remove personal desktop content and credentials from diagnostics. Please keep exploitable details out of public issues until a fix or mitigation is available.

The maintainer reviews reports and coordinates fixes through the private advisory. There is no paid support SLA or bug bounty. If you cannot use GitHub's private reporting, email [support@meetspriglet.com](mailto:support@meetspriglet.com) or use the [support page](https://meetspriglet.com/support).

## Supported versions

Security fixes target the current source on `main`; older GitHub preview tags are not maintained separately. The public [Mallow preview](https://github.com/eyenpi/spriglet/releases/tag/v0.3.0-preview.1) is app 0.3.0, build 5 and predates the current controls and accessibility work. App 0.3.1, build 6 was submitted to the Mac App Store on October 5, 2026 and was Waiting for Review as of that date. It is not yet a public Store release. Build the current source for the latest implementation; an ad hoc GitHub download is not Apple-notarized.

## Security boundaries

The app is sandboxed and holds companion state in memory for the current session. It does not read or migrate the previous companion’s saved preferences. It has no account, analytics SDK, or application backend. Reassess these statements before adding a service or dependency. Outside mouse clicks are observed only to return Mallow home; clicked content and global keyboard events are not read. See [the privacy policy](PRIVACY.md).

Pull request code must never receive Cloudflare deployment or Apple signing credentials. Review changes to workflows, deployment tools, shared policies, and signing configuration carefully. Public artifacts and logs must not contain credentials or private diagnostics. Report an exposed credential immediately so its owner can revoke it.
