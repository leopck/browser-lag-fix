# OPFS Guard

[![CI](https://github.com/leopck/opfs-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/leopck/opfs-guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Stops websites from briefly filling your system drive, and freezing your Windows PC, by abusing
browser site storage.**

Some websites run fingerprinting scripts that ask Chrome or Edge to grow a private site file to the
largest size the browser allows (about **60% of the drive**, so roughly 1.1 TB on a 2 TB SSD). On Windows
the browser really reserves that space on NTFS. For a few seconds the system drive is almost full,
NTFS has to scan the whole drive to find free space, and **every program's disk writes stall for
tens of seconds to minutes**. To the user it looks like the PC randomly lags.

This repository contains:

| | What it does | Protects against | Needs |
|---|---|---|---|
| [**Browser extension**](extension/) | Refuses page requests to grow a site file beyond a cap (default 10 GiB) with the browser's own `QuotaExceededError`. | Lag **and** the disk-size leak, on any site, whatever the script. | Chrome / Edge / Brave 111+ |
| [**Windows volume isolation**](windows/) | Moves each browser profile's site file storage onto a small, size-capped virtual disk. | Lag, from **any** source (including Web Workers the extension can't see). | Windows 10/11, admin |
| [**Reproduction**](repro/) | A 60-line page that triggers the problem on demand. | Verifying the bug and the fixes. | Python 3 |
| [**Diagnostics**](diagnostics/) | Free-space dip detector + WPR flight-recorder profile. | Proving it is happening on *your* machine. | Windows, admin |

The full investigation, with traces and measurements, is in [docs/root-cause.md](docs/root-cause.md).
An upstream report for Chromium is drafted in [docs/chromium-bug-report.md](docs/chromium-bug-report.md).

---

## Am I affected?

You probably are if **all** of these are true:

- You use a Chromium-based browser (Edge, Chrome, Brave, Vivaldi, Opera) **on Windows**.
- Your system drive is large (the bigger the drive, the bigger the reservation and the longer the stall).
- You see random multi-second freezes, especially shortly after opening shopping or retail sites.

Quick check: open **Event Viewer → Applications and Services Logs → Microsoft → Windows → Ntfs →
Operational** and look for **Event 147, "An IO took more than 30000 ms to complete"**, logged against
your browser's files. For definitive proof, run the [diagnostics](diagnostics/).

| Platform | Exposed? | Why |
|---|---|---|
| Chrome / Edge on **Windows** | **Yes** | NTFS reserves the full size immediately (measured). |
| Chrome / Safari on **macOS / iOS** | Unlikely to freeze | APFS stores unwritten space sparsely (not tested here). The probe still leaks a quota value. |
| **Firefox** (any OS) | Limited | Best-effort storage is capped at 10 GiB per site. |

## Quick start

### 1. Browser extension (recommended for everyone)

Until it is published in the stores, install it from source:

1. Download the latest `opfs-guard-<version>.zip` from [Releases](https://github.com/leopck/opfs-guard/releases) and unzip it, or clone this repo.
2. Open `edge://extensions` (or `chrome://extensions`), turn on **Developer mode**, click **Load unpacked**, and choose the `extension` folder.
3. Repeat for each browser profile (extensions are per profile).

That's it. The badge shows how many oversized requests were refused on the current page. Sites that
genuinely need huge local files (offline video editors, large local databases) can be allowed from
the popup.

### 2. Windows volume isolation (defence in depth)

In an **elevated** PowerShell, with the browsers **closed**:

```powershell
Import-Module .\windows\OpfsGuard.Volume
Install-OpfsGuardVolume -Browser Edge, Chrome   # default: 20 GB virtual disk at C:\OpfsGuard
Get-OpfsGuardStatus
```

Remove it at any time (data is moved back): `Uninstall-OpfsGuardVolume`. See [windows/README.md](windows/README.md).

## How it works

```
 Site script                       Browser (Windows)                      Disk
 ───────────                       ─────────────────                      ────
 writable.truncate(1023 GiB) ──►   quota check: 60% of drive → OK ──►     NTFS reserves 1.1 TB
                                   SetEndOfFile() on                      → drive ~full
                                   …\File System\NNN\t\00\000000xx        → bitmap scan, writes stall
 (binary search: 8 TiB, 4 TiB,
  2 TiB, 1 TiB ✓, 1.5 TiB ✗ …)

 With the extension:   truncate(1023 GiB) ──► rejected in the page: QuotaExceededError (cap 10 GiB)
 With the volume:      SetEndOfFile() lands on a 20 GB virtual disk ──► fails fast, C: untouched
```

Measured on Edge 158, Windows 11, a 2 TB NVMe drive ([details](docs/root-cause.md#controlled-reproduction)):

| | Unprotected | Volume isolation | Extension |
|---|---|---|---|
| Largest file the probe could create | **1,090 GiB** | 18 GiB | 10 GiB (cap) |
| C: free space during probe | 1,092 → **2 GB** | unchanged | unchanged |
| Time per large `truncate()` | **8–9 s** | 4–34 ms | < 1 ms (never reaches the browser) |
| Disk size learned by the site | ~1.9 TB | ~1.9 TB (quota check still passes) | none (sees a 10 GiB quota) |

## FAQ

**Is this malware?** No. The scripts we observed appear to be fingerprinting or bot-detection code
measuring the storage quota. The damage is a side effect of how the browser implements the request on Windows.

**Will the extension break sites?** Requests below the cap (10 GiB by default, the same value
Chromium reports through `navigator.storage.estimate()`) pass through untouched. Above-cap requests
fail exactly as if the browser's quota were 10 GiB, which sites must already handle.

**Does the extension read my browsing?** No. It runs locally, makes no network requests and stores only counters and
(optionally) the last 500 refused requests on your machine. See [PRIVACY.md](PRIVACY.md).

**Why not just block the script?** It is obfuscated, injected via `eval`, served from different
domains, and changes over time. Both fixes target the *behaviour*, not a particular script.

**Is there a real fix?** Yes, in the browser: extend files sparsely on Windows, as the File System
spec allows, and/or bound growth by actual free space. See the [upstream report](docs/chromium-bug-report.md).

## Repository layout

```
extension/        MV3 browser extension (guard, settings UI, icons)
windows/          OpfsGuard.Volume PowerShell module
repro/            probe.html + local server to reproduce the issue
diagnostics/      WPR profile and free-space dip watcher
docs/             root-cause analysis, upstream bug report, threat model
tests/            Node tests (extension) and Pester tests (module)
tools/            code generation, icon rendering, packaging
```

## Development

```bash
npm ci
npm run ci          # generated-file check, ESLint, unit tests, package -> dist/
```

```powershell
Invoke-Pester tests/windows -Output Detailed                        # unit tests
Invoke-Pester tests/windows -Output Detailed -TagFilter Integration # elevated: real VHDX lifecycle
'windows', 'diagnostics', 'tests' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse }
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
