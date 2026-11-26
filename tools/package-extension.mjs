#!/usr/bin/env node
// Builds dist/opfs-guard-<version>.zip, ready for the Chrome Web Store / Edge Add-ons upload.
// Uses only Node built-ins (a minimal deflate ZIP writer) so packaging has no dependencies.
import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync, crc32 } from 'node:zlib';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const extRoot = join(repo, 'extension');
const manifest = JSON.parse(await readFile(join(extRoot, 'manifest.json'), 'utf8'));

async function walk(dir) {
  const out = [];
  for (const name of (await readdir(dir)).sort()) {
    const p = join(dir, name);
    if ((await stat(p)).isDirectory()) out.push(...await walk(p)); else out.push(p);
  }
  return out;
}

const files = (await walk(extRoot)).filter(p => !p.endsWith('.md'));
const locals = [];
const centrals = [];
let offset = 0;
const dosTime = 0;        // fixed timestamps => reproducible archives
const dosDate = (1 << 5) | 1; // 1980-01-01

for (const p of files) {
  const name = Buffer.from(relative(extRoot, p).split(sep).join('/'));
  const data = await readFile(p);
  const comp = deflateRawSync(data, { level: 9 });
  const crc = crc32(data);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0, 6); local.writeUInt16LE(8, 8);
  local.writeUInt16LE(dosTime, 10); local.writeUInt16LE(dosDate, 12); local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(comp.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26); local.writeUInt16LE(0, 28);
  locals.push(local, name, comp);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(0, 8);
  central.writeUInt16LE(8, 10); central.writeUInt16LE(dosTime, 12); central.writeUInt16LE(dosDate, 14); central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(comp.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28);
  central.writeUInt32LE(offset, 42);
  centrals.push(central, name);
  offset += local.length + name.length + comp.length;
}
const centralBuf = Buffer.concat(centrals);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
end.writeUInt32LE(centralBuf.length, 12); end.writeUInt32LE(offset, 16);

await mkdir(join(repo, 'dist'), { recursive: true });
const out = join(repo, 'dist', `opfs-guard-${manifest.version}.zip`);
await writeFile(out, Buffer.concat([...locals, centralBuf, end]));
console.log(`${relative(repo, out)}  (${files.length} files)`);
