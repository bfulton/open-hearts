// The checkers of known images (checkers.mjs): which one is in use, as
// the run-time row says; what each needs before it checks anything; and
// what what they said comes to, whichever is in use now.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { KNOWN_ROW, PHOTODNA, SHIELD, anyChecker, checkerIn, checkersOf, knownSettingsOf, listed, verdictOf } from './checkers.mjs';

const shield = { OH_ARACHNID_ENDPOINT: 'https://shield.example', OH_ARACHNID_USERNAME: 'user', OH_ARACHNID_PASSWORD: 'pass' };
const photoDna = { OH_PHOTODNA_ENDPOINT: 'https://photodna.example', OH_PHOTODNA_KEY: 'pkey' };
const edgeHasher = () => ['h'];

/// OH_STORE holding [rows] ({'pk|sk': value}), as KV answers.
const kv = (rows = {}) => ({ get: async (k, type) => (k in rows ? (type === 'json' ? rows[k] : JSON.stringify(rows[k])) : null) });

test('what was said comes to: a match, then harmful, then clear, whichever checker said it; unreadable only for the one in use; else nothing yet', () => {
  for (const [by, on, said] of [
    [{}, [SHIELD], null],
    [{ shield: 'clear' }, [SHIELD], 'clear'],
    [{ shield: 'clear' }, [PHOTODNA], 'clear'],
    [{ photodna: 'match' }, [SHIELD], 'match'],
    [{ shield: 'harmful' }, [PHOTODNA], 'harmful'],
    [{ shield: 'harmful', photodna: 'match' }, [SHIELD], 'match'],
    [{ shield: 'clear', photodna: 'match' }, [SHIELD], 'match'],
    [{ shield: 'clear', photodna: 'harmful' }, [SHIELD], 'harmful'],
    [{ shield: 'clear', photodna: 'unreadable' }, [PHOTODNA], 'clear'],
    [{ shield: 'unreadable' }, [SHIELD], 'unreadable'],
    [{ shield: 'unreadable' }, [PHOTODNA], null],
    [{ operator: 'match' }, [SHIELD], 'match'],
    [{ shield: 'clear' }, [], 'clear'],
    [{}, [], null],
  ]) {
    assert.equal(verdictOf(by, on), said, `${JSON.stringify(by)} with ${on}`);
  }
});

test('the checker in use is the one the run-time row names, and Shield for anything else, or no row', async () => {
  assert.deepEqual(KNOWN_ROW, ['config', 'known']);
  assert.deepEqual(knownSettingsOf({ checker: 'photodna' }), { checker: PHOTODNA });
  for (const raw of [null, {}, { checker: 'shield' }, { checker: 'PhotoDNA' }, { checker: ['photodna'] }, 'photodna']) {
    assert.deepEqual(knownSettingsOf(raw), { checker: SHIELD }, JSON.stringify(raw));
  }
  assert.equal(await checkerIn({ OH_STORE: kv({ 'config|known': { checker: 'photodna' } }) }), PHOTODNA);
  assert.equal(await checkerIn({ OH_STORE: kv() }), SHIELD);
  assert.equal(await checkerIn({}), SHIELD, 'no store');
  assert.equal(await checkerIn({ OH_STORE: { get: async () => Promise.reject(new Error('KV down')) } }), SHIELD, 'a store that does not answer');
});

test('the one in use checks pictures once it has what it needs; the other is never asked, whatever it has', () => {
  const ids = (env, checker, more = {}) => checkersOf(env, { checker, edgeHasher, ...more }).on.map((c) => c.id);
  assert.deepEqual(ids({ ...shield, ...photoDna }, SHIELD), [SHIELD]);
  assert.deepEqual(ids({ ...shield, ...photoDna }, PHOTODNA), [PHOTODNA]);
  assert.deepEqual(ids(shield, SHIELD), [SHIELD]);
  assert.deepEqual(ids(photoDna, PHOTODNA), [PHOTODNA]);
  assert.deepEqual(ids({ ...shield, ...photoDna }, PHOTODNA, { edgeHasher: null }), [], 'PhotoDNA without the module');
  assert.deepEqual(ids({}, SHIELD), []);
  assert.deepEqual(checkersOf({}, { checker: SHIELD }).missing, [], 'nothing set: nothing to tell');
  assert.deepEqual(checkersOf(photoDna, { checker: PHOTODNA, edgeHasher }).missing, []);
  assert.deepEqual(checkersOf({ ...shield, ...photoDna }, { checker: SHIELD, edgeHasher: null }).missing, [], "the other's lack is nothing while it is not in use");
});

test('what the one in use lacks is told, and nothing is checked', () => {
  const missing = (env, checker, more = {}) => checkersOf(env, { checker, edgeHasher, ...more });
  for (const [env, checker, more, said] of [
    [{ ...shield, OH_ARACHNID_PASSWORD: undefined }, SHIELD, {}, /OH_ARACHNID_USERNAME is set but OH_ARACHNID_PASSWORD is not, so no picture is checked/],
    [{ ...shield, OH_ARACHNID_ENDPOINT: undefined }, SHIELD, {}, /OH_ARACHNID_USERNAME is set but arachnid.endpoint in config\/openhearts.json is not/],
    [photoDna, SHIELD, {}, /Arachnid Shield is the checker in use, and OH_ARACHNID_USERNAME is not set, so no picture is checked; PhotoDNA has its key: `\.\/oh config set known`/],
    [{ ...photoDna, OH_PHOTODNA_ENDPOINT: undefined }, PHOTODNA, {}, /OH_PHOTODNA_KEY is set but photodna.endpoint in config\/openhearts.json is not/],
    [photoDna, PHOTODNA, { edgeHasher: null }, /OH_PHOTODNA_KEY is set but the relay was deployed without the PhotoDNA module, so no picture is checked \(docs\/how-to\/update-the-photodna-module.md\)/],
    [shield, PHOTODNA, {}, /PhotoDNA is the checker in use, and OH_PHOTODNA_KEY is not set, so no picture is checked; Arachnid Shield has its credentials/],
  ]) {
    const { on, missing: lacks } = missing(env, checker, more);
    assert.deepEqual(on, []);
    assert.equal(lacks.length, 1);
    assert.match(lacks[0], said);
  }
});

test('either credential is enough to ask about a picture at all', () => {
  assert.equal(anyChecker({}), false);
  assert.equal(anyChecker({ OH_ARACHNID_USERNAME: 'user' }), true);
  assert.equal(anyChecker({ OH_PHOTODNA_KEY: 'pkey' }), true);
  assert.equal(anyChecker({ OH_ARACHNID_PASSWORD: 'pass', OH_PHOTODNA_ENDPOINT: 'x' }), false);
});

test('names listed as a sentence lists them', () => {
  assert.deepEqual(['', 'A', 'A and B', 'A, B and C'], [[], ['A'], ['A', 'B'], ['A', 'B', 'C']].map(listed));
});
