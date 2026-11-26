import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  CAP_CHOICES_GIB, DEFAULTS, allBootConfigs, bootConfigFile, normalizeHost, normalizeSettings, toMatchPatterns,
} from '../../extension/src/settings.js';

const extRoot = fileURLToPath(new URL('../../extension/', import.meta.url));

test('normalizeHost accepts hostnames and strips URL noise', () => {
  assert.equal(normalizeHost('Example.COM'), 'example.com');
  assert.equal(normalizeHost('https://app.example.org:8443/path?q=1'), 'app.example.org');
  assert.equal(normalizeHost('*.example.net'), 'example.net');
  assert.equal(normalizeHost('localhost'), 'localhost');
  assert.equal(normalizeHost('not a host'), '');
  assert.equal(normalizeHost('-bad.com'), '');
  assert.equal(normalizeHost(''), '');
});

test('normalizeSettings coerces bad input to safe defaults', () => {
  assert.deepEqual(normalizeSettings(undefined), { ...DEFAULTS, allowlist: [] });
  const s = normalizeSettings({ mode: 'weird', capGiB: 7, enabled: 'yes', allowlist: ['B.com', 'b.com', 'a.com', '???'] });
  assert.equal(s.mode, 'block');
  assert.equal(s.capGiB, DEFAULTS.capGiB);
  assert.equal(s.enabled, true);
  assert.deepEqual(s.allowlist, ['a.com', 'b.com']);
  assert.equal(normalizeSettings({ enabled: false }).enabled, false);
});

test('allow-list entries cover the host and its subdomains', () => {
  assert.deepEqual(toMatchPatterns(['example.com']), ['*://example.com/*', '*://*.example.com/*']);
});

test('every selectable setting has a generated, up-to-date boot-config file', () => {
  const configs = allBootConfigs();
  assert.equal(configs.length, CAP_CHOICES_GIB.length * 2 * 2);
  for (const { file, source } of configs) {
    const p = extRoot + file;
    assert.ok(existsSync(p), `missing ${file} (run npm run gen)`);
    assert.equal(readFileSync(p, 'utf8'), source, `${file} is stale (run npm run gen)`);
  }
  assert.equal(bootConfigFile({ capGiB: 10, mode: 'block', diagnostics: false }), 'src/boot/cap-10-block.js');
});

test('default cap matches the quota Chromium reports to pages (10 GiB)', () => {
  assert.equal(DEFAULTS.capGiB, 10);
  assert.ok(CAP_CHOICES_GIB.includes(DEFAULTS.capGiB));
});

test('manifest references files that exist', () => {
  const m = JSON.parse(readFileSync(extRoot + 'manifest.json', 'utf8'));
  const refs = [m.background.service_worker, m.action.default_popup, m.options_ui.page,
    ...Object.values(m.icons), ...m.content_scripts.flatMap(c => c.js)];
  for (const r of refs) assert.ok(existsSync(extRoot + r), `manifest points at missing ${r}`);
});
