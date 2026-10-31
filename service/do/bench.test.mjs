// The house as a Cloudflare Container (bench.mjs): a table that wants
// it starts it and tells it of the table; it is left alone while it
// serves or was woken lately, and stopped once it has gone quiet. The
// container here is a stand-in with the runtime's shape
// (ctx.container); the image itself is checked against a real table by
// service/tool/house_check.dart. node --test service/do
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Bench, LOOK_EVERY_MS, wakePath } from './bench.mjs';

/// A container with the runtime's shape, and a house inside it that
/// answers as service/bin/house.dart does once [startsAfter] pings have
/// gone unanswered.
function container({ startsAfter = 2 } = {}) {
  const c = {
    running: false,
    started: [],
    signals: [],
    timeouts: [],
    pings: 0,
    bench: { online: false, serving: 0, woken: [], pools: [], told: [], answers: true },
    start(options) {
      this.running = true;
      this.started.push(options);
    },
    signal(n) {
      this.signals.push(n);
      this.running = false;
    },
    destroyed: 0,
    async destroy() {
      this.destroyed++;
      this.running = false;
    },
    async setInactivityTimeout(ms) {
      this.timeouts.push(ms);
    },
    getTcpPort(port) {
      assert.equal(port, 8080);
      return {
        fetch: async (url, init = {}) => {
          if (!c.running) throw new Error('not running');
          const u = new URL(url);
          if (u.pathname === '/ping') {
            if (++c.pings <= startsAfter) throw new Error('connection refused');
            return new Response('ok');
          }
          if (!c.bench.answers) throw new Error('no answer');
          if (u.pathname === '/status') return Response.json({ online: c.bench.online, serving: c.bench.serving });
          if (u.pathname === '/wake' && init.method === 'POST') {
            if (u.searchParams.has('pool')) c.bench.pools.push(u.searchParams.get('pool'));
            else c.bench.woken.push(u.searchParams.get('table'));
            c.bench.told.push(JSON.parse(init.body ?? 'null'));
            c.bench.online = true;
            return new Response('awake');
          }
          return new Response('', { status: 404 });
        },
      };
    },
  };
  return c;
}

function state(c) {
  const rows = new Map();
  let alarm = null;
  return {
    container: c,
    storage: {
      getAlarm: async () => alarm,
      setAlarm: async (at) => {
        alarm = at;
      },
      get: async (k) => rows.get(k),
      put: async (k, v) => rows.set(k, v),
      delete: async (k) => rows.delete(k),
      alarmAt: () => alarm,
      clearAlarm: () => {
        alarm = null;
      },
    },
  };
}

const wake = (bench, table = 'tbl1') => bench.fetch(new Request(`https://bench/wake?table=${table}`, { method: 'POST' }));

test('a table wanting the house starts it, waits for it, and tells it of the table', async () => {
  const c = container();
  const s = state(c);
  const bench = new Bench(s, { OH_HOUSE_SECRET: 'ab'.repeat(32), OH_HOUSE_KEY: 'cd'.repeat(32), OH_BENCH_RELAYS: 'wss://r1' });
  const res = await wake(bench);
  assert.equal(res.status, 200);
  assert.equal(c.started.length, 1);
  assert.equal(c.started[0].enableInternet, true);
  assert.deepEqual(c.started[0].env, { OH_HOUSE_SECRET: 'ab'.repeat(32), OH_HOUSE_KEY: 'cd'.repeat(32), OH_RELAYS: 'wss://r1' });
  assert.deepEqual(c.bench.woken, ['tbl1']);
  assert.ok(s.storage.alarmAt() > Date.now(), 'and it is looked in on');
  // A second table while it runs is told of, and does not start another.
  await wake(bench, 'tbl2');
  assert.equal(c.started.length, 1);
  assert.deepEqual(c.bench.woken, ['tbl1', 'tbl2']);
  assert.equal((await bench.fetch(new Request('https://bench/wake', { method: 'POST' }))).status, 400, 'a wake names its table');
});

test('a pool wanting the house wakes it for the pool, and every wake says the operator\'s clocks', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  // The operator's row (service/functions/config.mjs), as a device is
  // served it: the table's clocks it names, and nothing it does not.
  let row = { live: true, table: { bankMs: 30000, nonsense: 1 } };
  let down = false;
  const store = {
    get: async (key, type) => {
      if (down) throw new Error('the store is down');
      assert.equal(type, 'json');
      return key === 'config|app' ? row : null;
    },
  };
  const bench = new Bench(s, { OH_HOUSE_SECRET: 'ab'.repeat(32), OH_STORE: store });
  // As the pool's object asks (worker.mjs, wake).
  assert.equal(wakePath('queue:unrated:100'), '/wake?pool=queue%3Aunrated%3A100');
  assert.equal(wakePath('ab'.repeat(16)), `/wake?table=${'ab'.repeat(16)}`);
  const res = await bench.fetch(new Request(`https://bench${wakePath('queue:unrated:100')}`, { method: 'POST' }));
  assert.equal(res.status, 200);
  assert.deepEqual(c.bench.pools, ['queue:unrated:100']);
  assert.deepEqual(c.bench.woken, [], 'a pool, not a table');
  assert.deepEqual(c.bench.told.at(-1), { timing: { bankMs: 30000 } });
  // A table's wake says them too, so the house seating a busy pool
  // hears of a change.
  row = { table: { bankMs: 5 } };
  await wake(bench, 'tbl1');
  assert.deepEqual(c.bench.told.at(-1), { timing: null }, 'a row out of bounds is the standard table, as a device is served it');
  row = null;
  await wake(bench, 'tbl2');
  assert.deepEqual(c.bench.told.at(-1), { timing: null }, 'no row: the standard table');
  down = true;
  await wake(bench, 'tbl3');
  assert.deepEqual(c.bench.told.at(-1), {}, 'a store that cannot be read says nothing, and the house keeps what it has');
  assert.equal((await bench.fetch(new Request('https://bench/wake?pool=', { method: 'POST' }))).status, 400, 'a wake names its pool');
});

test('a house started with anything else is started again with this', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  const env = { OH_SERVICE_KEY: 'aa'.repeat(32), OH_HOUSE_SECRET: 'cc'.repeat(32), OH_HOUSE_KEY: 'ee'.repeat(32), OH_BENCH_RELAYS: 'wss://r1' };
  await wake(new Bench(s, env));
  await wake(new Bench(s, { ...env }), 'tbl2');
  assert.equal(c.destroyed, 0, 'the same: left running');
  assert.equal(c.started.length, 1);
  assert.ok(!String(await s.storage.get('startedWith')).includes('cc'.repeat(32)), 'the secret is not kept');
  // The relay deployed with each changed in turn: the object is new,
  // the container is not, and it would go on with the old for as long
  // as tables kept it awake.
  const changes = [
    ['OH_SERVICE_KEY', 'bb'.repeat(32), 'OH_SERVICE_KEY'],
    ['OH_HOUSE_SECRET', 'dd'.repeat(32), 'OH_HOUSE_SECRET'],
    ['OH_HOUSE_KEY', 'ff'.repeat(32), 'OH_HOUSE_KEY'],
    ['OH_BENCH_RELAYS', 'wss://r2', 'OH_RELAYS'],
  ];
  for (const [i, [name, value, inside]] of changes.entries()) {
    env[name] = value;
    const res = await wake(new Bench(s, { ...env }), `tbl${i + 3}`);
    assert.equal(res.status, 200);
    assert.equal(c.destroyed, i + 1, name);
    assert.equal(c.started.length, i + 2, name);
    assert.equal(c.started.at(-1).env[inside], value, name);
  }
  assert.deepEqual(c.bench.woken, ['tbl1', 'tbl2', 'tbl3', 'tbl4', 'tbl5', 'tbl6']);
  // A deploy with the environment as it was: a new image, which a
  // running container does not take until it starts again.
  await wake(new Bench(s, { ...env, CF_VERSION_METADATA: { id: 'v1' } }), 'tbl7');
  assert.equal(c.destroyed, changes.length + 1, 'the first deploy that says which');
  await wake(new Bench(s, { ...env, CF_VERSION_METADATA: { id: 'v1' } }), 'tbl8');
  assert.equal(c.destroyed, changes.length + 1, 'the same deploy: left running');
  await wake(new Bench(s, { ...env, CF_VERSION_METADATA: { id: 'v2' } }), 'tbl9');
  assert.equal(c.destroyed, changes.length + 2, 'another deploy: started again');
  assert.equal(c.started.at(-1).env.CF_VERSION_METADATA, undefined, 'the version is not passed in');
});

test('a container started afresh gets its minute, whatever the one before it missed', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  await wake(new Bench(s, {}));
  // It stops answering, and misses one look.
  c.bench.answers = false;
  await new Bench(s, {}).alarm();
  assert.equal(await s.storage.get('unanswered'), true);
  // It ends before the next look, and the next call starts another.
  c.running = false;
  c.bench.answers = true;
  assert.equal((await wake(new Bench(s, {}), 'tbl2')).status, 200);
  // The new one misses its first look: given its minute, not stopped.
  c.bench.answers = false;
  await new Bench(s, {}).alarm();
  assert.deepEqual(c.signals, []);
});

test('left alone while they serve or wait, stopped once they are quiet', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  const bench = new Bench(s, {});
  await wake(bench);
  c.bench.serving = 1;
  await bench.alarm();
  assert.deepEqual(c.signals, [], 'serving');
  assert.ok(s.storage.alarmAt() >= Date.now() + LOOK_EVERY_MS - 1000);
  c.bench.serving = 0;
  await bench.alarm();
  assert.deepEqual(c.signals, [], 'woken lately');
  c.bench.online = false;
  await bench.alarm();
  assert.deepEqual(c.signals, [15], 'quiet: stopped, with SIGTERM');
  assert.equal(c.running, false);
  assert.deepEqual(await bench.status(), { running: false, online: false, serving: 0 });
});

test('a house that does not answer is given one more look, then stopped', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  const bench = new Bench(s, {});
  await wake(bench);
  c.bench.answers = false;
  await bench.alarm();
  assert.deepEqual(c.signals, []);
  await bench.alarm();
  assert.deepEqual(c.signals, [15]);
});

test('a house that never comes up is not told of the table', async () => {
  const c = container({ startsAfter: 1e9 });
  const bench = new Bench(state(c), {});
  const res = await wake(bench);
  assert.equal(res.status, 503);
  assert.deepEqual(c.bench.woken, []);
});

test('what it does with the house is said, a table by the first eight of its id', async () => {
  const c = container();
  const s = state(c);
  const lines = [];
  const bench = new Bench(s, { OH_HOUSE_SECRET: 'ab'.repeat(32) }, { log: (line) => lines.push(line) });
  const table = '83167bb6681da6f1b6f4ab8931028fbb';
  await wake(bench, table);
  assert.deepEqual(
    lines.map((l) => l.bench),
    ['start', 'woken'],
  );
  assert.equal(lines[0].table, 'table:83167bb6');
  assert.equal(lines[1].status, 200);
  assert.ok(lines[1].waitedMs >= 0);
  c.bench.online = false;
  await bench.alarm();
  assert.deepEqual(lines.slice(2), [{ bench: 'look', online: false, serving: 0 }, { bench: 'stop', why: 'quiet' }]);
  assert.ok(!JSON.stringify(lines).includes(table), 'not the whole of the id');
  assert.ok(!JSON.stringify(lines).includes('ab'.repeat(32)), 'nor the secret');
});
