# Report a security issue

Use [GitHub private vulnerability reporting](https://github.com/weirui828/skyeye/security/advisories/new).
Wei Rui, the repository maintainer, receives these reports.

Do not publish an exploit or an unredacted configuration file in a public issue.
Do not include passwords, tokens, private keys, or personal service logs.
Use a small example with fake credentials when possible.

Describe the affected version, the expected result, and the steps that reproduce the issue.
This project does not currently promise a response deadline.

## Scope

SkyEye is an early developer preview.
Security fixes target the current main branch. No older release branch has a separate support commitment.

SkyEye runs service commands with the current user's permissions.
Command approval controls commands added through the CLI or MCP.
The local control socket accepts connections from the same user account.
It is not a security boundary against malicious software already running as that user.

Keep command approval enabled. Review commands before approval.
Use services and AI agent integrations that you trust.
