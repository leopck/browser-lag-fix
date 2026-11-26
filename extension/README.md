# Browser Lag Fix: browser extension

A Manifest V3 extension for Chromium-based browsers (Chrome, Edge, Brave, Vivaldi, Opera; version 111+).

It refuses page requests that would grow a file in site storage beyond a cap, failing them with the
same `QuotaExceededError` the browser itself uses. Smaller requests pass through untouched.

## Install (from source)

1. `edge://extensions` or `chrome://extensions` → enable **Developer mode** → **Load unpacked** → select this `extension/` folder.
2. Repeat in every browser profile.

## Using it

- **Badge:** the number of refused requests on the current page.
- **Popup:** the current site's counters, and **Allow this site** for web apps that legitimately need very large local files.
- **Settings:**
  - **Cap:** 1–100 GiB. The default is 10 GiB, which equals the quota Chromium reports through `navigator.storage.estimate()`.
  - **Mode:** *Refuse* (default) or *Log only*.
  - **Diagnostics:** records JavaScript stacks for refused calls, useful for bug reports.
  - **Allow-list**, and **Export log** as JSON.

Changes apply to pages loaded afterwards.

## Design

| File | World | Role |
|---|---|---|
| `src/boot/cap-*-*.js` | page (MAIN) | Generated one-liners carrying the selected settings. Injected immediately before the guard. |
| `src/guard.js` | page (MAIN) | Wraps the storage APIs. Reads and deletes the boot config synchronously, so pages cannot see or change it. |
| `src/bridge.js` | isolated | Validates and rate-limits refusal reports, then forwards them to the service worker. |
| `src/background.js` | service worker | Registers the guard as a dynamic content script (allow-list → `excludeMatches`) and keeps counters. |
| `src/settings.js` | shared | Pure settings model, unit-tested. |

See the [threat model](../docs/threat-model.md) for what is and isn't covered (notably Web Workers).

## Permissions

| Permission | Why |
|---|---|
| `scripting` | Register the page-world guard with the chosen settings and allow-list. |
| `storage` | Settings (synced) and local counters/log. |
| host access `<all_urls>` | The guard must run on every site, in every frame, from `document_start`. |

No network access, no remote code, no analytics. See [PRIVACY.md](../PRIVACY.md).

## Build

```bash
npm run gen       # regenerate src/boot/* after changing settings.js
npm run icons     # re-render icons (Pillow)
npm run package   # dist/browser-lag-fix-<version>.zip for store upload
```
