// The backup jurors as a Cloudflare Container (bench.mjs): a
// call heard on the presence relay starts the backup jurors and is
// passed to them; they are left alone while they serve or wait, and
// stopped once they have gone quiet. The container here is a stand-in with the
// runtime's shape (ctx.container); the image itself is checked against
// a real table by service/tool/bench_check.dart. node --test service/do
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { Bench, LOOK_EVERY_MS, callIn } from './bench.mjs';
import { objectRelay, schnorrVerifier } from './relay.mjs';
import { wasmPath } from './host.mjs';
import { keys, signing } from './sign.mjs';

/// A container with the runtime's shape, and backup jurors inside it
/// that answer as service/bin/juror.dart does once [startsAfter] pings
/// have gone unanswered.
function container({ startsAfter = 2 } = {}) {
  const c = {
    running: false,
    started: [],
    signals: [],
    timeouts: [],
    pings: 0,
    bench: { online: false, serving: 0, woken: [], answers: true },
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
            c.bench.woken.push(u.searchParams.get('table'));
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

test('a call starts the backup jurors, waits for them, and passes the call on', async () => {
  const c = container();
  const s = state(c);
  const bench = new Bench(s, { OH_JUROR_SECRET: 'ab'.repeat(32), OH_BENCH_RELAYS: 'wss://r1' });
  const res = await wake(bench);
  assert.equal(res.status, 200);
  assert.equal(c.started.length, 1);
  assert.equal(c.started[0].enableInternet, true);
  assert.deepEqual(c.started[0].env, { OH_JUROR_SECRET: 'ab'.repeat(32), OH_RELAYS: 'wss://r1' });
  assert.deepEqual(c.bench.woken, ['tbl1']);
  assert.ok(s.storage.alarmAt() > Date.now(), 'and it is looked in on');
  // A second call while it runs is passed on, and does not start another.
  await wake(bench, 'tbl2');
  assert.equal(c.started.length, 1);
  assert.deepEqual(c.bench.woken, ['tbl1', 'tbl2']);
  assert.equal((await bench.fetch(new Request('https://bench/wake', { method: 'POST' }))).status, 400, 'a call names its table');
});

test('backup jurors started with anything else are started again with this', async () => {
  const c = container({ startsAfter: 0 });
  const s = state(c);
  const env = { OH_SERVICE_KEY: 'aa'.repeat(32), OH_JUROR_SECRET: 'cc'.repeat(32), OH_BENCH_RELAYS: 'wss://r1', OH_BENCH_PRESENCE_RELAYS: 'wss://p1' };
  await wake(new Bench(s, env));
  await wake(new Bench(s, { ...env }), 'tbl2');
  assert.equal(c.destroyed, 0, 'the same: left running');
  assert.equal(c.started.length, 1);
  assert.ok(!String(await s.storage.get('startedWith')).includes('cc'.repeat(32)), 'the secret is not kept');
  // The relay deployed with each changed in turn: the object is new,
  // the container is not, and it would go on with the old for as long
  // as calls kept it awake.
  const changes = [
    ['OH_SERVICE_KEY', 'bb'.repeat(32), 'OH_SERVICE_KEY'],
    ['OH_JUROR_SECRET', 'dd'.repeat(32), 'OH_JUROR_SECRET'],
    ['OH_BENCH_RELAYS', 'wss://r2', 'OH_RELAYS'],
    ['OH_BENCH_PRESENCE_RELAYS', 'wss://p2', 'OH_PRESENCE_RELAYS'],
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
  assert.deepEqual(c.signals, [], 'online and waiting to be drawn');
  c.bench.online = false;
  await bench.alarm();
  assert.deepEqual(c.signals, [15], 'quiet: stopped, with SIGTERM');
  assert.equal(c.running, false);
  assert.deepEqual(await bench.status(), { running: false, online: false, serving: 0 });
});

test('backup jurors that do not answer are given one more look, then stopped', async () => {
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

test('backup jurors that never come up is not passed the call', async () => {
  const c = container({ startsAfter: 1e9 });
  const bench = new Bench(state(c), {});
  const res = await wake(bench);
  assert.equal(res.status, 503);
  assert.deepEqual(c.bench.woken, []);
});

test('a call for a juror is read off a presence event, and nothing else is', () => {
  const ev = (content, kind = 24246) => ({ kind, content: JSON.stringify(content) });
  assert.equal(callIn(ev({ kind: 'call', table: 'tbl1' })), 'tbl1');
  assert.equal(callIn(ev({ kind: 'here', status: 'online' })), null);
  assert.equal(callIn(ev({ kind: 'call', table: 'tbl1' }, 1)), null, 'not a presence kind');
  assert.equal(callIn(ev({ kind: 'call', table: '' })), null);
  assert.equal(callIn(ev({ kind: 'call', table: 'x'.repeat(129) })), null);
  assert.equal(callIn({ kind: 24246, content: '{"call"' }), null);
});

test('the relay tells its host of an event it took, and not of one it refused', async () => {
  const wasm = readFileSync(wasmPath);
  const verify = await schnorrVerifier(wasm);
  const sign = await signing(wasm);
  const heard = [];
  const relay = objectRelay(verify, { heard: (e) => heard.push(e) });
  const said = [];
  const sock = { send: (t) => said.push(JSON.parse(t)) };
  relay.open(sock);
  const call = await sign.event(keys[0], { kind: 24246, content: JSON.stringify({ kind: 'call', table: 'tbl1' }), tags: [['t', 'online']], created_at: 1000 });
  await relay.message(sock, JSON.stringify(['EVENT', call]));
  await relay.message(sock, JSON.stringify(['EVENT', { ...call, content: 'forged' }]));
  assert.equal(heard.length, 1);
  assert.equal(callIn(heard[0]), 'tbl1');
});
