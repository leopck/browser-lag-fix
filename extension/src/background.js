/*
 * Browser Lag Fix — service worker.
 *
 * - Registers the page-world guard (plus the boot-config file matching the user's settings) as a
 *   dynamic content script, excluding allow-listed sites.
 * - Receives block/log reports from the bridge and keeps per-site counters and a bounded event log.
 */
import { CAP_CHOICES_GIB, DEFAULTS, bootConfigFile, normalizeSettings, toMatchPatterns } from './settings.js';

const SCRIPT_ID = 'browser-lag-fix-main';
const MAX_EVENTS = 500;

async function getSettings() {
  const stored = await chrome.storage.sync.get(DEFAULTS);
  return normalizeSettings(stored);
}

async function registerGuard() {
  const s = await getSettings();
  const existing = await chrome.scripting.getRegisteredContentScripts({ ids: [SCRIPT_ID] });
  if (existing.length) await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] });
  if (!s.enabled) return;
  const excludeMatches = toMatchPatterns(s.allowlist);
  await chrome.scripting.registerContentScripts([{
    id: SCRIPT_ID,
    matches: ['<all_urls>'],
    excludeMatches,
    js: [bootConfigFile(s), 'src/guard.js'],
    runAt: 'document_start',
    world: 'MAIN',
    allFrames: true,
    matchOriginAsFallback: true,
    persistAcrossSessions: true,
  }]);
}

/**
 * Pages that started loading before the extension was ready (tabs restored at browser start-up,
 * tabs open when the extension is installed or updated) never received the registered content
 * script. Inject the guard into them now. Probing scripts typically run seconds after load, so
 * this closes the gap in practice; the guard ignores a second installation in the same document.
 */
async function protectOpenTabs() {
  const s = await getSettings();
  if (!s.enabled) return;
  const allowed = host => s.allowlist.some(h => host === h || host.endsWith(`.${h}`));
  const tabs = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] });
  await Promise.all(tabs.map(async tab => {
    let host = '';
    try { host = new URL(tab.url).hostname; } catch (_) { return; }
    if (allowed(host)) return;
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: [bootConfigFile(s), 'src/guard.js'],
        world: 'MAIN',
        injectImmediately: true,
      });
    } catch (_) { /* discarded tab, error page, or a page we may not script */ }
  }));
}

async function initialise() {
  await registerGuard();
  await protectOpenTabs();
}

chrome.runtime.onInstalled.addListener(() => { initialise().catch(console.error); });
chrome.runtime.onStartup.addListener(() => { initialise().catch(console.error); });
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'sync') registerGuard().catch(console.error);
});

// Serialise storage updates so concurrent reports don't lose increments.
let queue = Promise.resolve();
function enqueue(fn) { queue = queue.then(fn).catch(console.error); return queue; }

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.kind === 'report' && msg.event && sender.tab) {
    const ev = msg.event;
    let site = '';
    try { site = new URL(sender.tab.url || ev.href).hostname; } catch (_) { /* ignore */ }
    enqueue(async () => {
      const { stats = {}, events = [] } = await chrome.storage.local.get(['stats', 'events']);
      const s = stats[site] || { blocked: 0, logged: 0, largestBytes: 0, last: 0 };
      if (ev.action === 'blocked') s.blocked += 1; else s.logged += 1;
      s.largestBytes = Math.max(s.largestBytes, Number(ev.requested) || 0);
      s.last = Date.now();
      stats[site] = s;
      events.push({ site, api: String(ev.api), requested: Number(ev.requested), cap: Number(ev.cap), action: ev.action,
        t: Date.now(), frame: String(ev.href || '').slice(0, 300), stack: ev.stack ? String(ev.stack).slice(0, 4000) : undefined });
      if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS);
      await chrome.storage.local.set({ stats, events });
      const tabKey = `tab_${sender.tab.id}`;
      const { [tabKey]: n = 0 } = await chrome.storage.session.get(tabKey);
      await chrome.storage.session.set({ [tabKey]: n + 1 });
      await chrome.action.setBadgeBackgroundColor({ tabId: sender.tab.id, color: '#B3261E' });
      await chrome.action.setBadgeText({ tabId: sender.tab.id, text: String(Math.min(n + 1, 999)) });
    });
    return false;
  }
  if (msg && msg.kind === 'getCapChoices') { sendResponse(CAP_CHOICES_GIB); return false; }
  if (msg && msg.kind === 'reregister') { registerGuard().then(() => sendResponse(true)); return true; }
  return false;
});

chrome.tabs.onRemoved.addListener(tabId => { chrome.storage.session.remove(`tab_${tabId}`); });
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === 'loading' && info.url) {
    chrome.storage.session.remove(`tab_${tabId}`);
    chrome.action.setBadgeText({ tabId, text: '' });
  }
});
