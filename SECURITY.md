# Security policy

## Reporting a vulnerability

Please report security issues **privately** through
[GitHub security advisories](https://github.com/leopck/browser-lag-fix/security/advisories/new),
not in public issues. Include steps to reproduce and the affected component and version.
Expect an acknowledgement within 7 days.

## Scope

In scope:
- ways for a web page to disable, reconfigure or bypass the extension's guard beyond the gaps
  documented in [docs/threat-model.md](docs/threat-model.md);
- privilege or data-integrity issues in the Windows module (for example data loss during
  redirection, or unsafe ACLs on the install folder).

The underlying browser behaviour (OPFS growth reserving disk space on Windows) is a Chromium issue.
See [docs/chromium-bug-report.md](docs/chromium-bug-report.md).
