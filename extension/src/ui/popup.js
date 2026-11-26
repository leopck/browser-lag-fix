import { DEFAULTS, normalizeHost, normalizeSettings } from '../settings.js';
import { formatBytes } from './format.js';

const $ = id => document.getElementById(id);

async function main() {
  const settings = normalizeSettings(await chrome.storage.sync.get(DEFAULTS));
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  let host = '';
  try { host = normalizeHost(new URL(tab.url).hostname); } catch (_) { /* chrome:// etc. */ }

  const allowed = host && settings.allowlist.some(h => host === h || host.endsWith(`.${h}`));
  const state = !settings.enabled ? ['Off', 'off'] : allowed ? ['Allowed here', 'warn'] : settings.mode === 'log' ? ['Log only', 'warn'] : ['Protecting', 'on'];
  $('state').textContent = state[0];
  $('state').className = `pill ${state[1]}`;
  $('site').textContent = host || 'This page cannot be protected';

  const { [`tab_${tab.id}`]: tabCount = 0 } = await chrome.storage.session.get(`tab_${tab.id}`);
  const { stats = {} } = await chrome.storage.local.get('stats');
  const s = stats[host] || { blocked: 0, logged: 0, largestBytes: 0 };
  $('tabCount').textContent = String(tabCount);
  $('siteCount').textContent = String(s.blocked + s.logged);
  $('largest').textContent = s.largestBytes ? formatBytes(s.largestBytes) : '—';
  $('capLine').textContent = `Requests to grow a site file beyond ${settings.capGiB} GiB are ${settings.mode === 'log' ? 'logged' : 'refused'}.`;

  const btn = $('allowBtn');
  if (!host) { btn.disabled = true; btn.textContent = 'Allow this site'; }
  else if (allowed) {
    btn.textContent = 'Stop allowing this site';
    btn.onclick = async () => {
      const allowlist = settings.allowlist.filter(h => !(host === h || host.endsWith(`.${h}`)));
      await chrome.storage.sync.set({ allowlist });
      window.close();
    };
  } else {
    btn.textContent = 'Allow this site';
    btn.onclick = async () => {
      await chrome.storage.sync.set({ allowlist: [...settings.allowlist, host] });
      window.close();
    };
  }
  $('optionsBtn').onclick = () => chrome.runtime.openOptionsPage();
}

main().catch(err => { $('site').textContent = `Error: ${err.message}`; });
