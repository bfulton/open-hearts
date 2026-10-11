// Which of the app's tests a change can reach: every test file whose
// imports, followed all the way down — through lib/, the test helpers
// and the packages the app takes by path — come to a file that changed.
//
//   node app/tool/affected_tests.mjs <changed path>...   # from the repo root
//
// Prints the test files, one a line, relative to app/; or `all` when the
// change is to something every test stands on (the pubspec, the
// analysis options, the words, flutter_test_config.dart) or to a file it
// cannot follow. ../../check.sh uses it for `quick`.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const packages = { open_hearts: 'app/lib', engine: 'packages/engine/lib', table: 'packages/table/lib', deal: 'packages/deal/lib' };

/// What every test stands on, so a change there is a change to all.
const everything = [/^app\/pubspec\.yaml$/, /^app\/analysis_options\.yaml$/, /^app\/l10n\.yaml$/, /^app\/lib\/l10n\//, /^app\/test\/flutter_test_config\.dart$/, /^packages\/\w+\/pubspec\.yaml$/];

const dartFiles = (dir) => {
  const out = [];
  const walk = (d) => {
    for (const e of readdirSync(join(root, d), { withFileTypes: true })) {
      const p = `${d}/${e.name}`;
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.dart')) out.push(p);
    }
  };
  if (existsSync(join(root, dir))) walk(dir);
  return out;
};

/// The files [file] reaches by its imports, exports and parts — both
/// sides of a conditional import — as paths from the root.
function depsOf(file) {
  const src = readFileSync(join(root, file), 'utf8');
  const out = [];
  for (const m of src.matchAll(/^\s*(?:import|export|part)\s+((?:'[^']+'|"[^"]+"|\s|if\s*\([^)]*\))+)/gm)) {
    for (const [, uri] of m[1].matchAll(/['"]([^'"]+)['"]/g)) {
      if (uri.startsWith('dart:')) continue;
      const pkg = uri.match(/^package:(\w+)\/(.*)$/);
      if (pkg) {
        if (packages[pkg[1]]) out.push(`${packages[pkg[1]]}/${pkg[2]}`);
        continue;
      }
      out.push(relative(root, normalize(join(root, dirname(file), uri))));
    }
  }
  return out;
}

const changed = process.argv.slice(2).map((p) => p.replace(/^\.\//, ''));
if (changed.some((p) => everything.some((re) => re.test(p)))) {
  console.log('all');
  process.exit(0);
}
const graph = new Map();
for (const f of [...dartFiles('app/lib'), ...dartFiles('app/test'), ...Object.values(packages).slice(1).flatMap(dartFiles)]) {
  graph.set(f, depsOf(f));
}
const touched = new Set(changed.filter((p) => p.endsWith('.dart')));
const reaches = new Map();
const reach = (f, seen = new Set()) => {
  if (seen.has(f)) return false;
  seen.add(f);
  if (touched.has(f)) return true;
  return (graph.get(f) ?? []).some((d) => reach(d, seen));
};
const tests = [...graph.keys()].filter((f) => f.startsWith('app/test/') && f.endsWith('_test.dart')).sort();
for (const t of tests) reaches.set(t, reach(t));
// A file that is not Dart — the page's index.html, a worker's script —
// reaches the tests that name it.
const named = changed.filter((p) => p.startsWith('app/') && !p.endsWith('.dart')).map((p) => p.split('/').at(-1));
const names = (t) => named.some((n) => readFileSync(join(root, t), 'utf8').includes(n));
const hit = tests.filter((t) => reaches.get(t) || names(t));
for (const t of hit) console.log(relative('app', t));
