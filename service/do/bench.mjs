// The jurors of last resort, as a Cloudflare Container
// (docs/04-live-play.md; service/bench builds the image).
//
// A table with bot seats is dealt only to a jury that can hold them, and
// on a quiet night there is nobody online to make one. The table then
// calls for a juror on the presence relay, every ten seconds while it is
// short — and the presence relay is ours (worker.mjs, TagRelay), which
// passes the call here. This object starts the bench if it is not
// running, waits for it to answer, and hands it the call, so it comes
// online for that table at once rather than at the table's next call.
//
// Then it looks in on the bench once a minute. While the bench is
// serving a table, or online and waiting to be drawn, it is left alone;
// once it has gone quiet — the bench does that itself, ten minutes
// after the last call with nothing to serve (packages/table,
// juror_duty.dart) — it is stopped, and stops costing anything. One
// bench for everyone, named `bench`: four jurors in one process, which
// is what one quiet night needs, and one container to pay for.

/// The bench's port (service/bin/juror.dart, `--port`).
export const BENCH_PORT = 8080;

/// How often the running bench is looked in on, and how long the
/// runtime may keep it without a word from here before stopping it: the
/// second well past the first, so it is this object that decides.
export const LOOK_EVERY_MS = 60 * 1000;
const INACTIVITY_MS = 15 * 60 * 1000;

/// How long a starting bench is waited for before the call is given up
/// on: the table calls again in ten seconds anyway.
const READY_TRIES = 100;
const READY_WAIT_MS = 200;

export class Bench {
  constructor(state, env = {}) {
    this.state = state;
    this.env = env;
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
      const table = url.searchParams.get('table') ?? '';
      if (!table || table.length > 128) return new Response('a table to wake for\n', { status: 400 });
      return (await this.wake(table)) ? new Response('awake\n') : new Response('not up yet\n', { status: 503 });
    }
    if (request.method === 'GET' && url.pathname === '/status') return Response.json(await this.status());
    return new Response('not found\n', { status: 404 });
  }

  /// Started if it is not running, and told of [table]. False when it
  /// did not come up in time.
  async wake(table) {
    const c = this.container;
    if (!c) return false;
    await c.setInactivityTimeout?.(INACTIVITY_MS);
    if (!c.running) {
      c.start({
        enableInternet: true,
        env: {
          ...(this.env.OH_JUROR_SECRET ? { OH_JUROR_SECRET: this.env.OH_JUROR_SECRET } : {}),
          ...(this.env.OH_BENCH_RELAYS ? { OH_RELAYS: this.env.OH_BENCH_RELAYS } : {}),
          ...(this.env.OH_BENCH_PRESENCE_RELAYS ? { OH_PRESENCE_RELAYS: this.env.OH_BENCH_PRESENCE_RELAYS } : {}),
        },
      });
    }
    if (!(await this.ready())) return false;
    try {
      const said = await this.port().fetch(`http://bench/wake?table=${encodeURIComponent(table)}`, { method: 'POST' });
      if (!said.ok) return false;
    } catch {
      return false;
    }
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + LOOK_EVERY_MS);
    return true;
  }

  /// Whether the bench answers on its port, waiting for it to start.
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

  /// What the bench says of itself: {running, online, serving}.
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

  /// Once a minute while it runs: left alone while it serves or waits
  /// to be drawn, stopped once it has gone quiet. A bench that does not
  /// answer is given the benefit of a minute more, once — it may be
  /// busy — and stopped if it still does not.
  async alarm() {
    const c = this.container;
    if (!c?.running) return;
    const s = await this.status();
    const quiet = !s.unanswered && !s.online && s.serving === 0;
    const silent = s.unanswered && (await this.state.storage.get('unanswered')) === true;
    if (quiet || silent) {
      await this.state.storage.delete('unanswered');
      c.signal(15);
      return;
    }
    await this.state.storage.put('unanswered', s.unanswered === true);
    await c.setInactivityTimeout?.(INACTIVITY_MS);
    await this.state.storage.setAlarm(Date.now() + LOOK_EVERY_MS);
  }
}

/// A call for a juror, as the presence relay carries it: kind 24246,
/// content {"kind":"call","table":…} (packages/table, presence_relay.dart).
export function callIn(event) {
  if (event?.kind !== 24246 || typeof event.content !== 'string' || !event.content.includes('"call"')) return null;
  try {
    const said = JSON.parse(event.content);
    return said?.kind === 'call' && typeof said.table === 'string' && said.table && said.table.length <= 128 ? said.table : null;
  } catch {
    return null;
  }
}
