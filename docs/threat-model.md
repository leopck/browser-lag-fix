# Threat model and limitations

## What we defend against

A web page (first- or third-party script) that grows files in browser site storage (OPFS or the legacy
`webkitRequestFileSystem` store) to very large sizes, either deliberately (quota or disk-size
fingerprinting) or by accident, causing:

1. **Availability impact:** the system drive briefly fills and all disk writes stall.
2. **Information leak:** the enforced quota (≈60% of disk) reveals the disk size.

We do not try to defend against a page that deliberately writes real data up to its quota. That is
bounded by normal quota and eviction rules, and writing real data is slow and visible.

## Extension

**How it works.** A script registered with `world: "MAIN"` at `document_start` in every frame wraps:

- `FileSystemWritableFileStream.prototype.truncate`
- `FileSystemWritableFileStream.prototype.write`, for `{type: 'truncate' | 'seek' | 'write'}` parameter objects
- `WritableStreamDefaultWriter.prototype.write`, for writers obtained from a file stream
- `FileSystemSyncAccessHandle.prototype.truncate`, where present
- `FileWriter.prototype.truncate` / `seek` (legacy API)

Requests whose resulting size exceeds the cap are rejected with `QuotaExceededError` before reaching
the browser.

**Settings integrity.** Settings reach the guard through a boot-config script injected immediately
before it, in the same `document_start` task. The guard reads and deletes the value synchronously, so
there is no runtime channel a page could forge. The allow-list is enforced by the browser
(`excludeMatches` on the dynamic content script), not by page-visible state.

**Report channel.** Refusals are reported to the extension with a DOM `CustomEvent`. A page can also
fire that event to inflate the counters. The bridge validates and rate-limits reports (200 per page).
Counters are informational only and never change enforcement.

### Known gaps

| Gap | Impact | Mitigation |
|---|---|---|
| **Dedicated / shared / service workers.** Content scripts are not injected into workers, and `FileSystemSyncAccessHandle` only exists there. | A worker-based probe bypasses the extension. | Use [volume isolation](../windows/) as well. |
| **Pristine prototypes from a fresh same-origin iframe.** A page can create an `about:blank` iframe and use its untouched `FileSystemWritableFileStream.prototype` before injection. | Determined bypass is possible. | `match_about_blank` and `match_origin_as_fallback` narrow the window; volume isolation is unaffected. |
| **Detectability.** A page can tell some code wrapped the APIs (for example from timing, or because the probe converges on exactly the cap). | Slight fingerprinting surface. | Wrappers keep native `name`, `length` and `toString()`. The default cap equals the quota Chromium already reports, so the observable value is not new information. |
| **Pages that load before the extension is ready.** At browser start-up (session restore, start-up URLs) and on install or update, tabs can begin loading before registered content scripts are active. | A probe that runs in the first instant of such a page is not intercepted. | On start-up, install and update the service worker injects the guard into every open tab. Observed probes run seconds after load (≈20 s in the wild), and the end-to-end test covers both races. Volume isolation covers the remainder. |
| **Settings apply on next page load.** | A changed cap or allow-list affects new documents only. | Documented in the UI. |

## Volume isolation

**How it works.** Each profile's `File System` directory becomes a junction to a folder on a
dynamically expanding VHDX (default 20 GB) mounted at `C:\BrowserLagFix\mnt`. A `SYSTEM` startup task
re-attaches the disk on boot. A logon task redirects profiles created later.

### Known gaps

| Gap | Impact | Mitigation |
|---|---|---|
| **Quota still leaks disk size.** Chromium computes the quota from the profile's drive, and a probe that ignores non-quota errors still finds ~60% of the system disk. | Fingerprinting only; no lag. | Use the extension as well. |
| **Virtual disk not attached** (startup task disabled or failed). | Junctions dangle, and sites cannot use OPFS until it is fixed. Other browser data is unaffected. | `Get-BrowserLagFixStatus`; `Mount-BrowserLagFixVolume`; the log at `C:\BrowserLagFix\browserlagfix.log`. |
| **Other storage types** (IndexedDB, Cache Storage) stay on the system drive. | They are written with real data, so they do not exhibit the sparse-allocation problem. | None needed. |
| **WebView2 apps** keep separate user-data folders. | Not covered by default. | Pass `-UserDataRoot` explicitly. |
