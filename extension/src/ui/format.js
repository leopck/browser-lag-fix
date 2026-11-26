/** Formats a byte count with binary units, e.g. 1099511627776 -> "1.0 TiB". */
export function formatBytes(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v < 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let i = 0;
  let x = v;
  while (x >= 1024 && i < units.length - 1) { x /= 1024; i += 1; }
  return `${i === 0 ? x : x.toFixed(1)} ${units[i]}`;
}
