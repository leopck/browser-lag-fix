# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-11-26

### Changed
- Renamed from OPFS Guard to **Browser Lag Fix**. The PowerShell module is now `BrowserLagFix.Volume`
  (`Install-BrowserLagFixVolume`, `Get-BrowserLagFixStatus`, …) and installs to `C:\BrowserLagFix`.

### Fixed
- Volume module: paths containing 8.3 short names (for example `C:\Users\RUNNER~1`) were compared in
  their short form, so redirected profiles could be reported as `RedirectedElsewhere` and re-mounting
  failed with "access path already in use".

## [1.0.0] - 2026-11-26

### Added
- Browser extension (MV3): refuses OPFS / legacy FileSystem growth beyond a cap (default 10 GiB) with
  `QuotaExceededError`. Includes a per-site allow-list, log-only mode, diagnostics stacks and JSON export.
- `BrowserLagFix.Volume` PowerShell module: moves Chromium site file storage onto a size-capped VHDX, with
  verified moves, a startup attach task, a logon reconcile task, status reporting and full uninstall.
- `repro/probe.html` and `repro/serve.py` minimal reproduction.
- Diagnostics: WPR flight-recorder profile and free-space dip watcher.
- Root-cause analysis, threat model and a Chromium bug report draft.
