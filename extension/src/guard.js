/*
 * Browser Lag Fix — page-world guard.
 *
 * Runs in the page's own JavaScript world (MAIN) at document_start, before any site script.
 * It refuses requests that would grow a file in the browser's sandboxed site storage
 * (Origin Private File System, and the legacy webkitRequestFileSystem API) beyond a cap,
 * by failing them with the same QuotaExceededError the browser itself uses.
 *
 * Why: on Windows, Chromium backs these files with ordinary NTFS files and growing one with
 * truncate() reserves real disk space up to ~60% of the drive. Fingerprinting scripts
 * binary-search that limit, which briefly fills the system drive and stalls all disk I/O,
 * and also leaks the disk size. Refusing above-cap requests here makes the probe see a quota
 * equal to the cap and never reach the browser.
 *
 * This file must stay self-contained (no imports): it is injected as a classic script.
 */
(function lagFix(root) {
  'use strict';

  const EVENT_REPORT = '__lag_fix_report__';
  const BOOT_KEY = '__lagFixBootConfig__';
  const GiB = 1024 ** 3;

  /** Defaults apply until the extension delivers the user's settings (a few ms after start). */
  const DEFAULT_CONFIG = Object.freeze({ mode: 'block', capBytes: 10 * GiB, diagnostics: false });

  /**
   * Pure decision function (unit tested).
   * @param {number} requestedBytes Size a call would grow a file to (or write position).
   * @param {{mode: string, capBytes: number}} config
   * @returns {'allow'|'block'|'log'}
   */
  function decide(requestedBytes, config) {
    if (typeof requestedBytes !== 'number' || !Number.isFinite(requestedBytes)) return 'allow';
    if (requestedBytes <= config.capBytes) return 'allow';
    return config.mode === 'log' ? 'log' : 'block';
  }

  /** Builds the error a real quota failure produces, preferring the newer QuotaExceededError class. */
  function quotaError(global, requested, quota) {
    const msg = 'The operation failed because it would cause the application to exceed its storage quota.';
    try {
      if (typeof global.QuotaExceededError === 'function') {
        return new global.QuotaExceededError(msg, { quota, requested });
      }
    } catch (_) { /* fall through */ }
    return new global.DOMException(msg, 'QuotaExceededError');
  }

  /**
   * Extracts the largest size implied by a FileSystemWritableFileStream.write() argument.
   * Covers {type:'truncate', size}, {type:'seek'|'write', position, data}.
   */
  function impliedSize(arg) {
    if (!arg || typeof arg !== 'object' || ArrayBuffer.isView(arg) || arg instanceof ArrayBuffer) return undefined;
    if (typeof Blob !== 'undefined' && arg instanceof Blob) return undefined;
    if (arg.type === 'truncate' && typeof arg.size === 'number') return arg.size;
    if ((arg.type === 'seek' || arg.type === 'write') && typeof arg.position === 'number') {
      let len = 0;
      const d = arg.data;
      if (d && typeof d.byteLength === 'number') len = d.byteLength;
      else if (d && typeof d.size === 'number') len = d.size;
      else if (typeof d === 'string') len = d.length;
      return arg.position + len;
    }
    return undefined;
  }

  /**
   * Installs the guard into a JS global (window or a test double).
   * @param {object} global
   * @param {() => {mode:string, capBytes:number, diagnostics:boolean}} getConfig
   * @param {(event: object) => void} report
   */
  function install(global, getConfig, report) {
    if (global.__lagFixInstalled__) return;
    Object.defineProperty(global, '__lagFixInstalled__', { value: true });

    const nativeToString = Function.prototype.toString;
    const disguise = (wrapper, original) => {
      // Keep wrapped functions indistinguishable from native ones to scripts that inspect them.
      try {
        Object.defineProperty(wrapper, 'name', { value: original.name });
        Object.defineProperty(wrapper, 'length', { value: original.length });
        Object.defineProperty(wrapper, 'toString', { value: () => nativeToString.call(original) });
      } catch (_) { /* non-fatal */ }
      return wrapper;
    };

    const emit = (api, requested, action) => {
      const cfg = getConfig();
      const evt = { api, requested, cap: cfg.capBytes, action, t: Date.now(), href: global.location ? String(global.location.href) : '' };
      if (cfg.diagnostics) {
        try { evt.stack = String(new Error().stack || '').split('\n').slice(3, 15).map(s => s.trim()).join('\n'); } catch (_) { /* ignore */ }
      }
      try { report(evt); } catch (_) { /* ignore */ }
    };

    /** Wraps an async (promise-returning) method so above-cap calls reject. */
    const guardAsync = (proto, name, api, sizeOf) => {
      if (!proto || typeof proto[name] !== 'function') return;
      const original = proto[name];
      const wrapper = disguise(function (...args) {
        const size = sizeOf(args);
        const verdict = decide(size, getConfig());
        if (verdict !== 'allow') {
          emit(api, size, verdict === 'block' ? 'blocked' : 'logged');
          if (verdict === 'block') return Promise.reject(quotaError(global, size, getConfig().capBytes));
        }
        return original.apply(this, args);
      }, original);
      Object.defineProperty(proto, name, { value: wrapper, writable: true, configurable: true, enumerable: false });
    };

    /** Wraps a synchronous method so above-cap calls throw. */
    const guardSync = (proto, name, api, sizeOf) => {
      if (!proto || typeof proto[name] !== 'function') return;
      const original = proto[name];
      const wrapper = disguise(function (...args) {
        const size = sizeOf(args);
        const verdict = decide(size, getConfig());
        if (verdict !== 'allow') {
          emit(api, size, verdict === 'block' ? 'blocked' : 'logged');
          if (verdict === 'block') throw quotaError(global, size, getConfig().capBytes);
        }
        return original.apply(this, args);
      }, original);
      Object.defineProperty(proto, name, { value: wrapper, writable: true, configurable: true, enumerable: false });
    };

    // Origin Private File System (window and dedicated workers expose these).
    const FSWFS = global.FileSystemWritableFileStream;
    if (FSWFS) {
      guardAsync(FSWFS.prototype, 'truncate', 'FileSystemWritableFileStream.truncate', a => a[0]);
      guardAsync(FSWFS.prototype, 'write', 'FileSystemWritableFileStream.write', a => impliedSize(a[0]));

      // Writes through stream.getWriter() bypass FSWFS.prototype.write; tag those writers.
      const writers = new WeakSet();
      const WSDW = global.WritableStreamDefaultWriter;
      if (typeof FSWFS.prototype.getWriter === 'function' && WSDW) {
        const originalGetWriter = FSWFS.prototype.getWriter;
        const getWriter = disguise(function (...args) {
          const w = originalGetWriter.apply(this, args);
          try { writers.add(w); } catch (_) { /* ignore */ }
          return w;
        }, originalGetWriter);
        Object.defineProperty(FSWFS.prototype, 'getWriter', { value: getWriter, writable: true, configurable: true });

        const originalWrite = WSDW.prototype.write;
        const write = disguise(function (chunk) {
          if (writers.has(this)) {
            const size = impliedSize(chunk);
            const verdict = decide(size, getConfig());
            if (verdict !== 'allow') {
              emit('WritableStreamDefaultWriter.write', size, verdict === 'block' ? 'blocked' : 'logged');
              if (verdict === 'block') return Promise.reject(quotaError(global, size, getConfig().capBytes));
            }
          }
          return originalWrite.apply(this, arguments);
        }, originalWrite);
        Object.defineProperty(WSDW.prototype, 'write', { value: write, writable: true, configurable: true });
      }
    }
    // Sync access handles only exist in workers; harmless no-op in a window.
    guardSync(global.FileSystemSyncAccessHandle && global.FileSystemSyncAccessHandle.prototype,
      'truncate', 'FileSystemSyncAccessHandle.truncate', a => a[0]);

    // Legacy sandboxed FileSystem API (webkitRequestFileSystem). truncate() is synchronous-start.
    guardSync(global.FileWriter && global.FileWriter.prototype, 'truncate', 'FileWriter.truncate', a => a[0]);
    guardSync(global.FileWriter && global.FileWriter.prototype, 'seek', 'FileWriter.seek', a => a[0]);
  }

  // --- test hook -----------------------------------------------------------------------------
  if (root && root.__LAG_FIX_TEST__) {
    root.__LAG_FIX_EXPORTS__ = { decide, impliedSize, install, quotaError, DEFAULT_CONFIG, EVENT_REPORT, BOOT_KEY };
    return;
  }

  // --- page installation ---------------------------------------------------------------------
  // Settings arrive via a tiny boot-config script the extension injects immediately before this
  // file (see background.js). Both run at document_start before any page script, so we read the
  // value and delete it in the same task: a page can never see or alter the guard's settings.
  // There is deliberately no runtime settings channel a page could forge.
  let config = DEFAULT_CONFIG;
  const boot = root[BOOT_KEY];
  try { delete root[BOOT_KEY]; } catch (_) { /* ignore */ }
  if (boot && (boot.mode === 'block' || boot.mode === 'log') && Number.isFinite(boot.capBytes) && boot.capBytes > 0) {
    config = Object.freeze({ mode: boot.mode, capBytes: boot.capBytes, diagnostics: !!boot.diagnostics });
  }
  // Capture DOM primitives now so later page code cannot intercept or suppress reports.
  const doc = root.document;
  const dispatch = doc ? root.EventTarget.prototype.dispatchEvent.bind(doc) : null;
  const CE = root.CustomEvent;
  const stringify = JSON.stringify;
  const report = evt => { if (dispatch) dispatch(new CE(EVENT_REPORT, { detail: stringify(evt) })); };
  install(root, () => config, report);
})(typeof globalThis !== 'undefined' ? globalThis : this);
