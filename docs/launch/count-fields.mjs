// Counts every store field in store-listing.md and writes the count
// under it, so the numbers in the file are measured, not typed.
//
//   node docs/launch/count-fields.mjs           # rewrite the counts
//   node docs/launch/count-fields.mjs --check   # fail if a count is stale or a field is over
//
// A field is a ```text block with a marker on the line above it:
//
//   <!-- limit=30 unit=chars -->     characters (Unicode code points)
//   <!-- limit=100 unit=bytes -->    UTF-8 bytes: App Store keywords
//   <!-- limit=6 unit=words -->      words: screenshot captions
//
// and the line after the block is its count. A keyword field is also
// checked for spaces after commas, words of two characters or fewer,
// and repeats, which App Store Connect either refuses or wastes.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), 'store-listing.md');
const check = process.argv.includes('--check');
const lines = fs.readFileSync(file, 'utf8').split('\n');

const chars = (s) => [...s].length;
const bytes = (s) => Buffer.byteLength(s, 'utf8');
const words = (s) => s.trim().split(/\s+/).filter(Boolean).length;

const out = [];
const problems = [];
let fields = 0;
for (let i = 0; i < lines.length; i++) {
  const marker = lines[i].match(/^<!-- limit=(\d+) unit=(chars|bytes|words) -->$/);
  out.push(lines[i]);
  if (!marker) continue;
  const limit = Number(marker[1]);
  const unit = marker[2];
  if (lines[i + 1] !== '```text') throw new Error(`line ${i + 2}: a marker must be followed by a \`\`\`text block`);
  const body = [];
  let j = i + 2;
  for (; j < lines.length && lines[j] !== '```'; j++) body.push(lines[j]);
  if (j === lines.length) throw new Error(`line ${i + 2}: the block never closes`);
  const text = body.join('\n');
  out.push(...lines.slice(i + 1, j + 1));
  const n = unit === 'bytes' ? bytes(text) : unit === 'words' ? words(text) : chars(text);
  const extra = unit === 'bytes' ? ` (${chars(text)} characters)` : '';
  const verdict = n > limit ? ' — OVER' : '';
  const line = `Count: ${n} of ${limit} ${unit === 'chars' ? 'characters' : unit}${extra}${verdict}`;
  if (n > limit) problems.push(`line ${i + 3}: ${n} ${unit}, limit ${limit}: ${text.slice(0, 50)}`);
  if (unit === 'bytes') {
    const terms = text.split(',');
    if (/\s/.test(text)) problems.push(`line ${i + 3}: keywords hold whitespace`);
    for (const t of terms) if (chars(t) <= 2) problems.push(`line ${i + 3}: keyword "${t}" is two characters or fewer`);
    const seen = new Set();
    for (const t of terms) {
      if (seen.has(t.toLowerCase())) problems.push(`line ${i + 3}: keyword "${t}" repeated`);
      seen.add(t.toLowerCase());
    }
  }
  // The count line: replaced if there is one, added if not.
  const next = lines[j + 1] ?? '';
  if (next.startsWith('Count: ')) {
    if (check && next !== line) problems.push(`line ${j + 2}: says "${next}", measures "${line}"`);
    out.push(line);
    i = j + 1;
  } else {
    if (check) problems.push(`line ${j + 2}: no count line`);
    out.push(line);
    i = j;
  }
  fields++;
}

if (!check) fs.writeFileSync(file, out.join('\n'));
console.log(`${fields} fields ${check ? 'checked' : 'counted'} in ${path.relative(process.cwd(), file)}`);
for (const p of problems) console.log(`  ${p}`);
process.exit(problems.length ? 1 : 0);
