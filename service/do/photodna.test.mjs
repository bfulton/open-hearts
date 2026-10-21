// PhotoDNA's MatchHash call (photodna.mjs): a picture decoded and hashed
// by the licensed module, its hashes and the key sent, and only an
// answer for every hash, each with status 3000, taken as one.
//
//   node --test service/do

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Unreadable } from './jpeg.mjs';
import { PhotoDnaFailed, TEST_SOURCE, jpegHasher, matchHashes, photoDnaMatch } from './photodna.mjs';

const endpoint = 'https://photodna.example/photodna/v1.0/MatchHash';
const gradient = readFileSync(new URL('./testdata/gradient64.jpg', import.meta.url));

/// A fetch that answers [status] with [body] and keeps what it was asked.
function answering(status, body) {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push({ url, init });
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
  };
  return { asked, fetchImpl };
}

/// MatchHash's answer for a hash: matching the lists in [sources].
const result = (...sources) => ({
  Status: { Code: 3000, Description: 'OK' },
  IsMatch: sources.length > 0,
  MatchDetails: { AdvancedInfo: [], MatchFlags: sources.map((Source) => ({ AdvancedInfo: [], Source, Violations: ['A1'], MatchDistance: 0 })) },
});

test('a JPEG decoded and handed to the module; a picture too small to hash, or not one, Unreadable', () => {
  const given = [];
  const hash = jpegHasher((rgb, width, height) => {
    given.push({ rgb, width, height });
    return ['one', 'two'];
  });
  assert.deepEqual(hash(gradient), ['one', 'two']);
  assert.equal(given.length, 1);
  assert.equal(given[0].width, 64);
  assert.equal(given[0].height, 64);
  assert.equal(given[0].rgb.length, 64 * 64 * 3);

  const small = jpegHasher(() => {
    throw Object.assign(new Error('too small'), { unhashable: true });
  });
  assert.throws(() => small(gradient), (e) => e instanceof Unreadable && /64 by 64 is too small to hash/.test(e.message));
  assert.throws(() => hash(Uint8Array.from([1, 2, 3])), Unreadable);
  assert.equal(given.length, 1, 'nothing undecoded handed to the module');

  const broken = jpegHasher(() => {
    throw new Error('module broke');
  });
  assert.throws(() => broken(gradient), (e) => !(e instanceof Unreadable) && /module broke/.test(e.message), 'anything else is not the picture');
});

test('the hashes and the key sent; a known image a match, a test picture only a test', async () => {
  const yes = answering(200, { TrackingId: 't', MatchResults: [result(), result('Known')] });
  assert.deepEqual(await matchHashes(['h1', 'h2'], { endpoint, key: 'k', fetchImpl: yes.fetchImpl }), { match: true, test: false });
  const [{ url, init }] = yes.asked;
  assert.equal(url, endpoint);
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['ocp-apim-subscription-key'], 'k');
  assert.equal(init.headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(init.body), [{ DataRepresentation: 'PreHashV2', Value: 'h1' }, { DataRepresentation: 'PreHashV2', Value: 'h2' }]);

  for (const [results, said] of [
    [[result()], { match: false, test: false }],
    [[result(TEST_SOURCE)], { match: false, test: true }],
    [[result(TEST_SOURCE), result()], { match: false, test: true }],
    [[result(TEST_SOURCE, 'Known')], { match: true, test: true }],
    [[result(), result(TEST_SOURCE), result('Other')], { match: true, test: true }],
  ]) {
    const { fetchImpl } = answering(200, { MatchResults: results });
    assert.deepEqual(await matchHashes(results.map((_, i) => `h${i}`), { endpoint, key: 'k', fetchImpl }), said, JSON.stringify(results));
  }
});

test('a picture hashed and asked about; one with nothing to hash matches nothing, unasked', async () => {
  const asked = answering(200, { MatchResults: [result('Known')] });
  assert.deepEqual(await photoDnaMatch(gradient, { endpoint, key: 'k', hasher: () => ['h'], fetchImpl: asked.fetchImpl }), { match: true, test: false });
  assert.deepEqual(JSON.parse(asked.asked[0].init.body), [{ DataRepresentation: 'PreHashV2', Value: 'h' }]);

  const flat = answering(200, { MatchResults: [] });
  assert.deepEqual(await photoDnaMatch(gradient, { endpoint, key: 'k', hasher: () => [], fetchImpl: flat.fetchImpl }), { match: false, test: false });
  assert.equal(flat.asked.length, 0);

  const none = answering(200, { MatchResults: [] });
  assert.deepEqual(await photoDnaMatch(gradient, { endpoint, key: 'k', hasher: jpegHasher(() => []), fetchImpl: none.fetchImpl }), { match: false, test: false });
  await assert.rejects(photoDnaMatch(Uint8Array.from([1]), { endpoint, key: 'k', hasher: jpegHasher(() => ['h']), fetchImpl: none.fetchImpl }), Unreadable);
  assert.equal(none.asked.length, 0);
});

test('anything but an answer for every hash is a failure, never a clear picture', async () => {
  for (const [status, body] of [
    [200, { MatchResults: [{ Status: { Code: 3002, Description: 'Invalid hash' }, IsMatch: false }] }],
    [200, { MatchResults: [{ Status: { Code: 3000 } }] }],
    [200, { MatchResults: [{ Status: { Code: 3000 }, IsMatch: 'false' }] }],
    [200, { MatchResults: [{ Status: { Code: 3000 }, IsMatch: true, MatchDetails: { MatchFlags: [] } }] }],
    [200, { MatchResults: [{ Status: { Code: 3000 }, IsMatch: true }] }],
    [200, { MatchResults: [result(), result()] }],
    [200, { MatchResults: [] }],
    [200, { Status: { Code: 3000 }, IsMatch: false }],
    [200, { matchResults: [result()] }],
    [200, [result()]],
    [401, { MatchResults: [result()] }],
    [500, 'not json'],
  ]) {
    const { fetchImpl } = answering(status, body);
    await assert.rejects(matchHashes(['h'], { endpoint, key: 'k', fetchImpl }), PhotoDnaFailed, `${status} ${JSON.stringify(body)}`);
  }
  await assert.rejects(
    matchHashes(['h'], { endpoint, key: 'k', fetchImpl: async () => { throw new Error('offline'); } }),
    (e) => e instanceof PhotoDnaFailed && /not reached: offline/.test(e.message),
  );
});

test("the relay is built with the stand-in, and hands the known-picture object the module's hasher when it has one", () => {
  // Read, not run: Wrangler resolves the worker's imports (wrangler.toml,
  // alias), so Node cannot load it.
  const toml = readFileSync(new URL('./wrangler.toml', import.meta.url), 'utf8');
  const tables = [...toml.matchAll(/^\[[^\n]*\]$/gm)];
  const alias = tables.find((t) => t[0] === '[alias]');
  assert.ok(alias, 'an alias table');
  assert.ok(toml.indexOf('\nroutes = ') < alias.index, 'after every top-level key, so that none is read as an alias');
  const body = toml.slice(alias.index + alias[0].length, tables[tables.indexOf(alias) + 1].index);
  assert.deepEqual(body.split('\n').filter((l) => l.trim() && !l.startsWith('#')), ['"open-hearts-photodna" = "./photodna_off.mjs"']);
  const worker = readFileSync(new URL('./worker.mjs', import.meta.url), 'utf8');
  assert.match(worker, /^import \{ edgeHashes \} from 'open-hearts-photodna';$/m);
  assert.match(worker, /^import \{ jpegHasher \} from '\.\/photodna\.mjs';$/m);
  assert.match(worker, /\{ hasher: edgeHashes \? jpegHasher\(edgeHashes\) : null \}/);
});

