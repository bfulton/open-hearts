// That nothing licensed to Open Hearts as confidential is in the
// repository: the PhotoDNA module, Microsoft's, and the relay's code
// that calls it, which are kept in the private bucket and fetched only
// to deploy the relay (ops/photodna.mjs). Fails on any tracked file
//
//   - under service/do/private/, where the deploy puts the module;
//   - whose SHA-256 is one config/openhearts.json pins for the module;
//   - that says it is private in the words the module's own files open
//     with, or carries the confidential notice of Microsoft's SDK;
//   - that is WebAssembly other than the app's own.
//
//   node ops/no_private.mjs     (check.sh scripts runs it)

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

/// The words each private file opens with, and the notice on
/// Microsoft's SDK, each put together here so that this file does not
/// say them itself.
export const MARKS = [['Private: never in', 'the public repository'].join(' '), ['PhotoDNA SDK', 'Confidential'].join(' ')];

/// The only WebAssembly the repository holds: the app's own, built from
/// crypto/ (check.sh, wasm).
export const OWN_WASM = ['app/web/deal.wasm', 'app/web/schnorr.wasm'];

/// What is wrong with [files] ({path, bytes}, every tracked file), given
/// the module's [pins] (name -> SHA-256, or null): a line for each.
export function privateProblems(files, pins) {
  const pinned = new Map(Object.entries(pins ?? {}).map(([name, sha256]) => [sha256, name]));
  const problems = [];
  for (const { path, bytes } of files) {
    if (path.startsWith('service/do/private/')) problems.push(`${path}: the PhotoDNA module's folder is never committed`);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (pinned.has(sha256)) problems.push(`${path}: is the PhotoDNA module's ${pinned.get(sha256)}`);
    const text = bytes.toString('latin1');
    for (const mark of MARKS) if (text.includes(mark)) problems.push(`${path}: says "${mark}"`);
    if (path.endsWith('.wasm') && !OWN_WASM.includes(path)) problems.push(`${path}: WebAssembly that is not the app's own`);
  }
  return problems;
}

async function main() {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  const paths = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
  const files = paths.map((path) => ({ path, bytes: readFileSync(join(root, path)) }));
  const pins = JSON.parse(readFileSync(join(root, 'config/openhearts.json'), 'utf8')).photodna?.module ?? null;
  const problems = privateProblems(files, pins);
  for (const p of problems) console.error(`no_private: ${p}`);
  if (problems.length) process.exit(1);
  console.log(`no_private: ${files.length} tracked files, none private`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) await main();
