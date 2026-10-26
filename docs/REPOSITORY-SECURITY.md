# Protect the public repository

Only people with write access can push changes to this repository.
Public access lets other people read and fork the code. It does not grant write access.
The MIT License permits reuse under its terms.

## Security features

Keep these GitHub features enabled:

- Secret scanning and push protection.
- Dependabot alerts and security updates.
- Private vulnerability reporting.

Review the Security tab for new alerts.
If a real credential is exposed, revoke it. Deleting a file does not revoke a credential.

## Protect main

Create a branch ruleset in **Settings → Rules → Rulesets**.
Apply it to `main`.

1. Block force pushes.
2. Block branch deletion.
3. Require a pull request for changes.
4. Require resolved review conversations.
5. Keep required approving reviews at zero while Wei Rui is the only maintainer.

A pull request author cannot approve their own pull request.
Do not require another reviewer until a trusted reviewer is available.
Use squash merges to keep the main branch history simple.
Do not rewrite public history for routine changes.

### Require CI after it passes

The hosted service-readiness tests currently fail.
Investigate those failures before you make the checks mandatory.
Do not remove the tests only to obtain a successful result.

After the failures are fixed, require these checks:

- `Test (macos-15)`
- `Test (macos-15-intel)`

Select GitHub Actions as the expected source of the checks.
Decide whether to apply the rules to the repository administrator too.
Keep a recovery method for an incorrect rule.

## Restrict workflow access

Use read-only workflow tokens unless a job needs write access.
The current CI workflow uses read-only tokens and actions pinned to commit IDs.
Dependabot can propose updates to those pins.

In **Settings → Actions → General**, require approval for workflows from external pull requests.
Do not give pull request workflows signing certificates or release credentials.
Review changes to `.github/workflows/` before you run them.
The CODEOWNERS file requests review from Wei Rui.
It does not enforce review without a branch rule.

## Protect the maintainer account

Enable a passkey or two-factor authentication on GitHub.
Limit collaborator access and token permissions.
Keep recovery codes in a secure location outside the repository.
Review repository access and installed GitHub Apps periodically.

## Protect releases

Keep Apple certificates and notarization credentials outside Git.
Use a separate release workflow with access only to the required secrets.
Sign and notarize public Mac downloads.
Publish checksums with each release.
Do not publish CI artifacts as trusted releases without review.

References:

- [GitHub branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [GitHub push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection)
- [Private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)
