# Contributing

Thanks for helping. Bug reports, site reports and pull requests are welcome.

## Setup

- Node.js 22+ (extension tooling), Python 3 with Pillow (icons only)
- PowerShell 7+ or Windows PowerShell 5.1, with Pester 5.5+ and PSScriptAnalyzer (Windows module)

```bash
npm ci
npm run ci
```

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester tests/windows -Output Detailed
'windows', 'diagnostics', 'tests' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse }
```

The integration tests (`-TagFilter Integration`) create and delete a real 100 MB VHDX and need an
elevated session. CI runs them on `windows-latest`.

The browser end-to-end test runs the real extension against `repro/probe.html` in throwaway Edge
profiles, covering the install and session-restore races:

```powershell
pwsh tests/e2e/Invoke-ExtensionE2E.ps1
```

## Guidelines

- **Guard (`extension/src/guard.js`)** must stay a dependency-free classic script, because it runs in
  the page's own world. Every new hooked API needs a unit test in `tests/extension/guard.test.js`.
- **Settings** live in `extension/src/settings.js`. After changing `CAP_CHOICES_GIB` or the boot-config
  format, run `npm run gen` and commit the regenerated `src/boot/*` files (CI checks this).
- **Windows module:** every state-changing function supports `-WhatIf`/`-Confirm`, and nothing is
  ever deleted before a verified copy exists.
- Update `CHANGELOG.md` under *Unreleased*.

## Releasing

1. Bump `extension/manifest.json`, `package.json` and `windows/OpfsGuard.Volume/OpfsGuard.Volume.psd1`
   to the same version, and move the *Unreleased* changelog entries under it.
2. Tag `vX.Y.Z` and push the tag. The Release workflow builds both packages, with checksums, and publishes them.
