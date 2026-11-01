// What the operator watches of the handlers (docs/explanation/service.md),
// in node's own test runner: node --test service/functions
import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from './worker.mjs';
import { measure } from './metrics.mjs';

/// An Analytics Engine dataset that keeps what it was given.
const dataset = () => ({
  points: [],
  writeDataPoint(p) {
    this.points.push(p);
  },
});

const KEY = 'ab'.repeat(32);

test('a request is a line: the handler, its status, how long — and nothing about who asked', async () => {
  const OH_METRICS = dataset();
  const env = { OH_METRICS, ASSETS: { fetch: async () => new Response('asset') } };
  const ask = (path, init) => worker.fetch(new Request(`https://play.openhearts.game${path}`, init), env);

  await ask('/api/licence', { method: 'POST', body: JSON.stringify({ key: KEY, at: 1, sig: 'x' }), headers: { 'x-forwarded-for': '203.0.113.9' } });
  await ask('/api/nothing-here-' + KEY);
  await ask('/play/index.html');

  assert.equal(OH_METRICS.points.length, 2, 'the handlers, not the assets');
  const [licence, unknown] = OH_METRICS.points;
  assert.deepEqual(licence.indexes, ['licence']);
  assert.equal(licence.blobs[0], 'licence');
  assert.match(licence.blobs[1], /^\d{3}$/);
  assert.equal(licence.doubles[1], 1, 'stands for itself');
  assert.ok(licence.doubles[0] >= 0);
  assert.deepEqual(unknown.blobs, ['unknown', '404'], 'a path nobody serves is not written down as asked');
  for (const p of OH_METRICS.points) {
    const said = JSON.stringify(p);
    assert.ok(!said.includes(KEY), 'no key');
    assert.ok(!said.includes('203.0.113.9'), 'no address');
  }
});

test('the config, which every open app asks for, is one in ten and says so', () => {
  const OH_METRICS = dataset();
  let draw = 0;
  const random = () => [0.05, 0.5, 0.95, 0.09][draw++ % 4];
  for (let i = 0; i < 4; i++) measure({ OH_METRICS }, 'config', 200, 3, { random });
  assert.equal(OH_METRICS.points.length, 2);
  assert.deepEqual(OH_METRICS.points[0].doubles, [3, 10], 'each line stands for ten');
  measure({ OH_METRICS }, 'ticket', 200, 3, { random: () => 0.99 });
  assert.equal(OH_METRICS.points.length, 3, 'a person doing something is always written');
});

test('nothing bound, nothing written; a dataset that throws stops nothing', async () => {
  measure({}, 'licence', 200, 1);
  const env = { OH_METRICS: { writeDataPoint: () => { throw new Error('quota'); } } };
  const answer = await worker.fetch(new Request('https://play.openhearts.game/api/config'), env);
  assert.equal(answer.status, 200);
});

test('a handler that throws is counted as the 500 the runtime answers, and still throws', async () => {
  const OH_METRICS = dataset();
  const OH_STORE = { get: async () => { throw new Error('KV down'); } };
  const order = new Request('https://play.openhearts.game/api/order', { method: 'POST', body: JSON.stringify({ order: 'e'.repeat(32) }) });
  await assert.rejects(worker.fetch(order, { OH_METRICS, OH_STORE }), /KV down/);
  assert.deepEqual(OH_METRICS.points.map((p) => p.blobs), [['order', '500']]);
});
