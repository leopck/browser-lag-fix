# Privacy policy: Browser Lag Fix browser extension

Browser Lag Fix runs entirely on your device.

- **No data leaves your browser.** The extension makes no network requests, loads no remote code and
  contains no analytics or telemetry.
- **What is stored, locally only:**
  - your settings (cap, mode, allow-list), via `chrome.storage.sync`, which your browser may sync to
    your own browser account;
  - per-site counters of refused requests (hostname, count, largest size, last time);
  - the most recent 500 refused requests (hostname, frame URL, API name, requested size, time, and a
    JavaScript stack only if you enable *Diagnostics*).
- **What is never collected:** page content, form data, cookies, browsing history beyond the sites
  where a request was refused, and anything about you.
- **Your control:** *Settings → Clear log* deletes the counters and log. Uninstalling removes everything.

The Windows module (`BrowserLagFix.Volume`) only writes to `C:\BrowserLagFix` (or the folder you choose) and
the browser profile folders it redirects. It sends nothing anywhere.
