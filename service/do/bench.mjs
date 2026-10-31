// The house, as a Cloudflare Container (docs/explanation/live-play.md;
// service/bench builds the image, service/bin/house.dart is what runs
// in it).
//
// Every sealed table has the house at it: it deals and plays the bot
// seats, holds half of each person's escrow, and says how the game came
// out. A table's object (worker.mjs, TagRelay) calls on this one as the
// table starts, and again whenever the house is not on the table's log
// (referee.mjs, wanted). It seats the pools too, and a pool's object
// calls on this one while somebody waits there and the house is not
// (pool.mjs). This object starts the house if it is not running, waits
// for it to answer, and tells it of the table, which it then follows
// from the log's first entry, or of the pool, which it then seats; and
// with every wake, of the operator's clocks for the tables it seats.
//
// Then it looks in on it once a minute. While it is serving a table or
// a pool, or was woken in the last ten minutes, it is left alone; once
// it has gone quiet it is stopped, and stops costing anything. One
// house for every table and every pool (wrangler.toml, max_instances),
// named `bench` for the container it has always been in.

import { tagLabel } from './relay.mjs';
import { isPoolTag } from './pool.mjs';
import { CONFIG_ROW, configOf } from '../functions/config.mjs';

/// The wake for [tag], as this object and the house's own port both
/// take it: `/wake?pool=…` for a pool's tag, `/wake?table=…` for a
/// table's.
export const wakePath = (tag) => `/wake?${isPoolTag(tag) ? 'pool' : 'table'}=${encodeURIComponent(tag)}`;

/// The house's port (service/bin/house.dart, `--port`).
export const BENCH_PORT = 8080;

/// How often the running house is looked in on, and how long the
/// runtime may keep it without a word from here before stopping it: the
/// second well past the first, so it is this object that decides.
export const LOOK_EVERY_MS = 60 * 1000;
const INACTIVITY_MS = 15 * 60 * 1000;

/// How long a starting house is waited for before the wake is given up
/// on: the table wakes it again when the time between wakes is up.
const READY_TRIES = 100;
const READY_WAIT_MS = 200;

/// Where this object notes what it last started the house with: a
/// digest of its environment, which holds a secret, and of the deploy
/// that started it.
const STARTED_WITH = 'startedWith';

/// The SHA-256 of [env] as JSON, in hex.
async function digestOf(env) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(env))));
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export class Bench {
  /// [log] takes a line for the operator's logs: what this object did
  /// with the house and when, as JSON for Workers Logs — laid beside the
  /// house's own traces and the relay's sockets when a game is lost
  /// (docs/how-to/look-into-a-lost-game.md). A table by the first eight
  /// of its id; nothing about anybody.
  constructor(state, env = {}, { log = (line) => console.log(JSON.stringify(line)) } = {}) {
    this.state = state;
    this.env = env;
    this.log = log;
  }

  get container() {
    return this.state.container;
  }

  port() {
    return this.container.getTcpPort(BENCH_PORT);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === 'POST' && url.pathname === '/wake') {
      const tag = url.searchParams.get(url.searchParams.has('pool') ? 'pool' : 'table') ?? '';
      if (!tag || tag.length > 128) return new Response('a table or a pool to wake for\n', { status: 400 });
      return (await this.wake(tag)) ? new Response('awake\n') : new Response('not up yet\n', { status: 503 });
    }
    if (request.method === 'GET' && url.pathname === '/status') return Response.json(await this.status());
    return new Response('not found\n', { status: 404 });
  }

  /// The operator's clocks for the tables the house seats in the pools
  /// (service/functions/config.mjs, the row's `table`), as a device is
  /// served them: `{timing}`, null for the standard table's, or `{}`
  /// when the row could not be read, which leaves the house with what it
  /// was last told.
  async clocks() {
    try {
      const row = (await this.env.OH_STORE?.get(CONFIG_ROW.join('|'), 'json')) ?? null;
      return { timing: configOf(row).table ?? null };
    } catch {
      return {};
    }
  }

  /// Started if it is not running, and told of [table] — a table's tag
  /// or a pool's ([wakePath]) — with the operator's clocks ([clocks]).
  /// False when it did not come up in time.
  async wake(table) {
    const c = this.container;
    if (!c) return false;
    const at = tagLabel(table);
    await c.setInactivityTimeout?.(INACTIVITY_MS);
    const env = {
      // The house's own secret, and the key the relay takes it by: the
      // house does not start if the one is not the other's.
      ...(this.env.OH_HOUSE_SECRET ? { OH_HOUSE_SECRET: this.env.OH_HOUSE_SECRET } : {}),
      ...(this.env.OH_HOUSE_KEY ? { OH_HOUSE_KEY: this.env.OH_HOUSE_KEY } : {}),
      // The service's public key, to check the seats' licences by.
      ...(this.env.OH_SERVICE_KEY ? { OH_SERVICE_KEY: this.env.OH_SERVICE_KEY } : {}),
      ...(this.env.OH_BENCH_RELAYS ? { OH_RELAYS: this.env.OH_BENCH_RELAYS } : {}),
    };
    // The environment and the image are the container's from when it
    // started, and a deploy starts no container afresh: Cloudflare's
    // rollouts pass over containers an object starts, which take their
    // image at start. One kept awake by tables would hold every seat to
    // an old service key, sign as a house the relay no longer takes, or
    // speak an old build's protocol. So one started with another
    // environment, or under another deploy (CF_VERSION_METADATA,
    // wrangler.toml), is stopped and started again; the tables it was
    // serving wake it again, and it follows each from its log.
    const started = await digestOf({ env, version: this.env.CF_VERSION_METADATA?.id ?? null });
    if (c.running && (await this.state.storage.get(STARTED_WITH)) !== started) {
      this.log({ bench: 'restart', table: at, why: 'started under another deploy or environment' });
      await c.destroy();
    }
    if (!c.running) {
      this.log({ bench: 'start', table: at });
      c.start({ enableInternet: true, env });
      await this.state.storage.put(STARTED_WITH, started);
      // A fresh container gets its minute's grace (alarm), whatever the
      // one before it had missed.
      await this.state.storage.delete('unanswered');
    }
    const waited = Date.now();
    if (!(await this.ready())) {
      this.log({ bench: 'not up', table: at, waitedMs: Date.now() - waited });
      return false;
    }
    try {
      const said = await this.port().fetch(`http://bench${wakePath(table)}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(await this.clocks()),
      });
      this.log({ bench: 'woken', table: at, status: said.status, waitedMs: Date.now() - waited });
      if (!said.ok) return false;
    } catch (e) {
      this.log({ bench: 'not woken', table: at, why: String(e?.message ?? e).slice(0, 80) });
      return false;
    }
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + LOOK_EVERY_MS);
    return true;
  }

  /// Whether the house answers on its port, waiting for it to start.
  async ready() {
    for (let i = 0; i < READY_TRIES; i++) {
      try {
        if ((await this.port().fetch('http://bench/ping')).ok) return true;
      } catch {
        // Not listening yet.
      }
      await new Promise((r) => setTimeout(r, READY_WAIT_MS));
    }
    return false;
  }

  /// What the house says of itself: {running, online, serving} — online
  /// while it was woken in the last ten minutes.
  async status() {
    const c = this.container;
    if (!c?.running) return { running: false, online: false, serving: 0 };
    try {
      const s = await (await this.port().fetch('http://bench/status')).json();
      return { running: true, online: s.online === true, serving: Number.isInteger(s.serving) ? s.serving : 0 };
    } catch {
      return { running: true, online: false, serving: 0, unanswered: true };
    }
  }

  /// Once a minute while it runs: left alone while it serves or was
  /// woken lately, stopped once it has gone quiet. A container that
  /// does not answer is given the benefit of a minute more, once — it
  /// may be busy dealing — and stopped if it still does not.
  async alarm() {
    const c = this.container;
    if (!c?.running) return;
    const s = await this.status();
    const quiet = !s.unanswered && !s.online && s.serving === 0;
    const silent = s.unanswered && (await this.state.storage.get('unanswered')) === true;
    this.log({ bench: 'look', online: s.online, serving: s.serving, ...(s.unanswered ? { unanswered: true } : {}) });
    if (quiet || silent) {
      this.log({ bench: 'stop', why: quiet ? 'quiet' : 'not answering' });
      await this.state.storage.delete('unanswered');
      c.signal(15);
      return;
    }
    await this.state.storage.put('unanswered', s.unanswered === true);
    await c.setInactivityTimeout?.(INACTIVITY_MS);
    await this.state.storage.setAlarm(Date.now() + LOOK_EVERY_MS);
  }
}
