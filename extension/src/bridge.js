/*
 * OPFS Guard — isolated-world bridge.
 * Forwards block/log reports from the page-world guard to the service worker.
 * Reports are validated and rate-limited because a page can dispatch the same DOM event.
 */
(() => {
  const EVENT_REPORT = '__opfs_guard_report__';
  const MAX_PER_PAGE = 200;
  let sent = 0;
  document.addEventListener(EVENT_REPORT, e => {
    if (sent >= MAX_PER_PAGE || typeof e.detail !== 'string' || e.detail.length > 8192) return;
    let ev;
    try { ev = JSON.parse(e.detail); } catch (_) { return; }
    if (!ev || typeof ev.api !== 'string' || !['blocked', 'logged'].includes(ev.action)) return;
    sent += 1;
    try { chrome.runtime.sendMessage({ kind: 'report', event: ev }); } catch (_) { /* extension reloaded */ }
  });
})();
