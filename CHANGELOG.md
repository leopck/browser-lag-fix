# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-26

### Added
- Browser extension (MV3): refuses OPFS / legacy FileSystem growth beyond a cap (default 10 GiB) with
  `QuotaExceededError`. Includes a per-site allow-list, log-only mode, diagnostics stacks and JSON export.
- `OpfsGuard.Volume` PowerShell module: moves Chromium site file storage onto a size-capped VHDX, with
  verified moves, a startup attach task, a logon reconcile task, status reporting and full uninstall.
- `repro/probe.html` and `repro/serve.py` minimal reproduction.
- Diagnostics: WPR flight-recorder profile and free-space dip watcher.
- Root-cause analysis, threat model and a Chromium bug report draft.
