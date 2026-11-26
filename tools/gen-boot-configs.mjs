#!/usr/bin/env node
// Generates extension/src/boot/*.js from the settings model.
// Usage: node tools/gen-boot-configs.mjs [--check]
//   --check  exit 1 if any generated file is missing or out of date (used in CI).
import { mkdir, readFile, readdir, writeFile, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { allBootConfigs } from '../extension/src/settings.js';

const extRoot = join(dirname(fileURLToPath(import.meta.url)), '..', 'extension');
const bootDir = join(extRoot, 'src', 'boot');
const check = process.argv.includes('--check');

await mkdir(bootDir, { recursive: true });
const wanted = allBootConfigs();
const wantedNames = new Set(wanted.map(w => w.file.split('/').pop()));
let problems = 0;

for (const { file, source } of wanted) {
  const path = join(extRoot, file);
  let current = null;
  try { current = await readFile(path, 'utf8'); } catch { /* missing */ }
  if (current === source) continue;
  if (check) { console.error(`out of date: ${file}`); problems += 1; } else { await writeFile(path, source); console.log(`wrote ${file}`); }
}
for (const name of await readdir(bootDir)) {
  if (!wantedNames.has(name)) {
    if (check) { console.error(`stale: src/boot/${name}`); problems += 1; } else { await unlink(join(bootDir, name)); console.log(`removed src/boot/${name}`); }
  }
}
if (check && problems) { console.error(`${problems} boot-config file(s) need regenerating: npm run gen`); process.exit(1); }
if (check) console.log(`boot configs up to date (${wanted.length} files)`);
