// The name filter (names.mjs): the names it refuses and the names it
// lets be, the same as the app's (app/lib/names.dart, held to the same
// cases in names.vectors.json); every entry on the lists refused as a
// name of its own; and what it reads made from the lists as
// third_party/ldnoobw/build.mjs makes it. node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';

import { nameRefused } from './names.mjs';
import { DART_FILE, JS_FILE, LANGUAGES, LEFT_OUT, sources } from '../../third_party/ldnoobw/build.mjs';

const vectors = JSON.parse(readFileSync(new URL('./names.vectors.json', import.meta.url), 'utf8'));
const listed = (lang) =>
  readFileSync(new URL(`../../third_party/ldnoobw/${lang}`, import.meta.url), 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);

test('names: refuses the names the app refuses', () => {
  assert.ok(vectors.refused.length > 0);
  assert.deepEqual(vectors.refused.filter((n) => !nameRefused(n)), []);
});

test('names: lets be the names the app lets be', () => {
  assert.ok(vectors.allowed.length > 0);
  assert.deepEqual(vectors.allowed.filter((n) => nameRefused(n)), []);
});

test('names: every entry on the lists, but those left out, is refused as a name, as written and in capitals', () => {
  const missed = [];
  for (const lang of LANGUAGES) {
    for (const entry of listed(lang)) {
      if (Object.hasOwn(LEFT_OUT[lang] ?? {}, entry)) continue;
      if (!nameRefused(entry) || !nameRefused(entry.toUpperCase())) missed.push(`${lang}: ${entry}`);
    }
  }
  assert.deepEqual(missed, []);
});

test('names: what is left out is on its list, and lets a name be', () => {
  for (const [lang, left] of Object.entries(LEFT_OUT)) {
    assert.ok(LANGUAGES.includes(lang), lang);
    const entries = listed(lang);
    for (const entry of Object.keys(left)) {
      assert.ok(entries.includes(entry), `${lang}: ${entry} is not on the list; take it out of LEFT_OUT`);
      assert.equal(nameRefused(entry), false, `${lang}: ${entry}, left out, is still refused`);
    }
  }
});

test('names: what is not a string is not the filter\'s to judge', () => {
  for (const x of [null, undefined, 7, {}, ['fuck']]) assert.equal(nameRefused(x), false);
});

test('names: the service\'s and the app\'s word lists are what build.mjs makes of the lists', () => {
  const { js, dart } = sources();
  const stale = 'out of date: run node third_party/ldnoobw/build.mjs';
  assert.equal(readFileSync(JS_FILE, 'utf8'), js, `service/functions/blocked_names.mjs is ${stale}`);
  assert.equal(readFileSync(DART_FILE, 'utf8'), dart, `app/lib/blocked_names.dart is ${stale}`);
});
