// Unit tests for extension/src/guard.js, executed in a simulated page global via node:vm.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const GUARD_SRC = readFileSync(fileURLToPath(new URL('../../extension/src/guard.js', import.meta.url)), 'utf8');
const GiB = 1024 ** 3;

/** Builds a fake page global with OPFS / legacy FileSystem classes that record calls. */
function makePage({ testMode = false, boot } = {}) {
  const calls = [];
  const listeners = {};
  class FileSystemWritableFileStream {
    truncate(size) { calls.push(['truncate', size]); return Promise.resolve(); }
    write(data) { calls.push(['write', data]); return Promise.resolve(); }
    getWriter() { return new WritableStreamDefaultWriter(this); }
  }
  class WritableStreamDefaultWriter {
    constructor(stream) { this.stream = stream; }
    write(chunk) { calls.push(['writer.write', chunk]); return Promise.resolve(); }
  }
  class FileWriter {
    truncate(size) { calls.push(['legacy.truncate', size]); }
    seek(offset) { calls.push(['legacy.seek', offset]); }
  }
  class EventTarget {
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); }
    dispatchEvent(ev) { (listeners[ev.type] || []).forEach(fn => fn(ev)); return true; }
  }
  class CustomEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail; } }
  const document = new EventTarget();
  const g = {
    FileSystemWritableFileStream, WritableStreamDefaultWriter, FileWriter, EventTarget, CustomEvent, document,
    DOMException, Promise, JSON, Error, Object, Number, ArrayBuffer, Function, String, Date, WeakSet,
    location: { href: 'https://shop.example/' },
  };
  g.globalThis = g;
  if (testMode) g.__LAG_FIX_TEST__ = true;
  if (boot) g.__lagFixBootConfig__ = boot;
  const ctx = vm.createContext(g);
  vm.runInContext(GUARD_SRC, ctx, { filename: 'guard.js' });
  const reports = [];
  document.addEventListener('__lag_fix_report__', e => reports.push(JSON.parse(e.detail)));
  return { g, calls, reports };
}

test('decide(): allows at or below the cap, blocks or logs above it', () => {
  const { g } = makePage({ testMode: true });
  const { decide } = g.__LAG_FIX_EXPORTS__;
  const cfg = { mode: 'block', capBytes: 10 * GiB };
  assert.equal(decide(0, cfg), 'allow');
  assert.equal(decide(10 * GiB, cfg), 'allow');
  assert.equal(decide(10 * GiB + 1, cfg), 'block');
  assert.equal(decide(1023 * GiB, { ...cfg, mode: 'log' }), 'log');
  assert.equal(decide(undefined, cfg), 'allow');
  assert.equal(decide(Number.NaN, cfg), 'allow');
});

test('impliedSize(): understands truncate/seek/write parameter objects only', () => {
  const { g } = makePage({ testMode: true });
  const { impliedSize } = g.__LAG_FIX_EXPORTS__;
  assert.equal(impliedSize({ type: 'truncate', size: 5 }), 5);
  assert.equal(impliedSize({ type: 'seek', position: 7 }), 7);
  assert.equal(impliedSize({ type: 'write', position: 10, data: new Uint8Array(4) }), 14);
  assert.equal(impliedSize({ type: 'write', position: 10, data: 'abc' }), 13);
  assert.equal(impliedSize(new Uint8Array(100)), undefined);
  assert.equal(impliedSize('text'), undefined);
  assert.equal(impliedSize(null), undefined);
});

test('defaults: blocks a 1 TiB truncate with QuotaExceededError and never calls the browser', async () => {
  const { g, calls, reports } = makePage();
  const w = new g.FileSystemWritableFileStream();
  await assert.rejects(w.truncate(1023 * GiB), err => err.name === 'QuotaExceededError');
  assert.deepEqual(calls, []);
  assert.equal(reports.length, 1);
  assert.equal(reports[0].action, 'blocked');
  assert.equal(reports[0].api, 'FileSystemWritableFileStream.truncate');
  assert.equal(reports[0].requested, 1023 * GiB);
  assert.equal(reports[0].cap, 10 * GiB);
});

test('defaults: small truncates and writes pass straight through', async () => {
  const { g, calls, reports } = makePage();
  const w = new g.FileSystemWritableFileStream();
  await w.truncate(100 * 1024 * 1024);
  await w.write(new Uint8Array(8));
  await w.write({ type: 'write', position: 0, data: new Uint8Array(8) });
  assert.equal(calls.length, 3);
  assert.equal(reports.length, 0);
});

test('write({type:"truncate"}) and far seeks are guarded', async () => {
  const { g, calls } = makePage();
  const w = new g.FileSystemWritableFileStream();
  await assert.rejects(w.write({ type: 'truncate', size: 2048 * GiB }), { name: 'QuotaExceededError' });
  await assert.rejects(w.write({ type: 'seek', position: 50 * GiB }), { name: 'QuotaExceededError' });
  await assert.rejects(w.write({ type: 'write', position: 20 * GiB, data: new Uint8Array(1) }), { name: 'QuotaExceededError' });
  assert.deepEqual(calls, []);
});

test('writes through stream.getWriter() are guarded too', async () => {
  const { g, calls } = makePage();
  const w = new g.FileSystemWritableFileStream();
  const writer = w.getWriter();
  await assert.rejects(writer.write({ type: 'truncate', size: 4096 * GiB }), { name: 'QuotaExceededError' });
  await writer.write(new Uint8Array(1));
  assert.deepEqual(calls.map(c => c[0]), ['writer.write']);
});

test('writers of unrelated streams are not affected', async () => {
  const { g, calls } = makePage();
  const other = new g.WritableStreamDefaultWriter({});
  await other.write({ type: 'truncate', size: 4096 * GiB });
  assert.equal(calls.length, 1);
});

test('legacy FileWriter.truncate/seek throw synchronously above the cap', () => {
  const { g, calls } = makePage();
  const fw = new g.FileWriter();
  assert.throws(() => fw.truncate(1023 * GiB), { name: 'QuotaExceededError' });
  assert.throws(() => fw.seek(1023 * GiB), { name: 'QuotaExceededError' });
  fw.truncate(1024);
  assert.deepEqual(calls, [['legacy.truncate', 1024]]);
});

test('reproduces the observed in-the-wild probe: it converges on the cap, not the disk size', async () => {
  // Sequence taken from the zwilling.com capture (GiB): start at 8 TiB, halve until accepted, refine.
  const { g } = makePage();
  let hi = 8192 * GiB, lo = 0, size = hi;
  for (let i = 0; i < 40 && !(lo > 0 && hi - lo < GiB / 16); i++) {
    const w = new g.FileSystemWritableFileStream();
    let ok = true;
    try { await w.truncate(size); } catch (e) { if (e.name === 'QuotaExceededError') ok = false; else throw e; }
    if (ok) lo = size; else hi = size;
    size = lo === 0 ? size / 2 : (lo + hi) / 2;
  }
  assert.ok(lo <= 10 * GiB && lo > 9.9 * GiB, `probe concluded ${lo / GiB} GiB`);
});

test('boot config is applied, then removed from the page global', async () => {
  const { g, calls, reports } = makePage({ boot: { mode: 'log', capBytes: 1 * GiB, diagnostics: true } });
  assert.equal(g.__lagFixBootConfig__, undefined);
  const w = new g.FileSystemWritableFileStream();
  await w.truncate(2 * GiB); // log mode: allowed but reported
  assert.equal(calls.length, 1);
  assert.equal(reports[0].action, 'logged');
  assert.equal(reports[0].cap, GiB);
  assert.equal(typeof reports[0].stack, 'string');
});

test('invalid boot config falls back to safe defaults', async () => {
  const { g, calls } = makePage({ boot: { mode: 'off', capBytes: -1 } });
  const w = new g.FileSystemWritableFileStream();
  await assert.rejects(w.truncate(11 * GiB), { name: 'QuotaExceededError' });
  assert.equal(calls.length, 0);
});

test('wrapped methods still look native to inspecting scripts', () => {
  const { g } = makePage();
  const fn = g.FileSystemWritableFileStream.prototype.truncate;
  assert.equal(fn.name, 'truncate');
  assert.equal(fn.length, 1);
  assert.match(fn.toString(), /truncate\(size\)/); // original source of the fake, i.e. not the wrapper
});

test('installing twice is a no-op', async () => {
  const { g, calls } = makePage();
  vm.runInContext(GUARD_SRC, vm.createContext(g));
  const w = new g.FileSystemWritableFileStream();
  await w.truncate(1);
  assert.equal(calls.length, 1);
});
