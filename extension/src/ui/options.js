import { CAP_CHOICES_GIB, DEFAULTS, normalizeSettings } from '../settings.js';
import { formatBytes } from './format.js';

const $ = id => document.getElementById(id);

async function load() {
  const s = normalizeSettings(await chrome.storage.sync.get(DEFAULTS));
  const sel = $('capGiB');
  sel.replaceChildren(...CAP_CHOICES_GIB.map(g => {
    const o = document.createElement('option');
    o.value = String(g);
    o.textContent = `${g} GiB${g === DEFAULTS.capGiB ? ' (default)' : ''}`;
    return o;
  }));
  sel.value = String(s.capGiB);
  $('enabled').checked = s.enabled;
  $('mode').value = s.mode;
  $('diagnostics').checked = s.diagnostics;
  $('allowlist').value = s.allowlist.join('\n');
  await renderEvents();
}

async function renderEvents() {
  const { events = [] } = await chrome.storage.local.get('events');
  const body = $('events').querySelector('tbody');
  body.replaceChildren(...events.slice().reverse().slice(0, 200).map(e => {
    const tr = document.createElement('tr');
    for (const v of [new Date(e.t).toLocaleString(), e.site, e.api, formatBytes(e.requested), e.action]) {
      const td = document.createElement('td');
      td.textContent = v;
      tr.append(td);
    }
    if (e.stack) tr.title = e.stack;
    return tr;
  }));
}

$('form').addEventListener('submit', async ev => {
  ev.preventDefault();
  const s = normalizeSettings({
    enabled: $('enabled').checked,
    mode: $('mode').value,
    capGiB: Number($('capGiB').value),
    diagnostics: $('diagnostics').checked,
    allowlist: $('allowlist').value.split(/\s+/),
  });
  await chrome.storage.sync.set(s);
  $('allowlist').value = s.allowlist.join('\n');
  $('saved').textContent = 'Saved. Applies to pages loaded from now on.';
  setTimeout(() => { $('saved').textContent = ''; }, 4000);
});

$('exportBtn').addEventListener('click', async () => {
  const data = await chrome.storage.local.get(['stats', 'events']);
  const blob = new Blob([JSON.stringify({ exported: new Date().toISOString(), ...data }, null, 2)], { type: 'application/json' });
  const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: 'browser-lag-fix-log.json' });
  a.click();
  URL.revokeObjectURL(a.href);
});

$('clearBtn').addEventListener('click', async () => {
  await chrome.storage.local.set({ stats: {}, events: [] });
  await renderEvents();
});

load();
