// The relay as one Cloudflare object per tag (docs/06-service.md).
//
// `wss://host/<tag>` is a relay of its own: the worker turns the tag
// into an object id and hands the socket to that object, so everyone
// on a tag meets in one place and nothing has to be broadcast between
// machines. Presence is one tag — `online` — and one object.
//
// Two things keep this free rather than a monthly bill.
//
// The sockets hibernate. `state.acceptWebSocket` gives the runtime the
// socket and lets this object be evicted while nothing is happening,
// which is most of the time: a room of people with the app open sends
// a beat every five seconds and is otherwise silent. `server.accept()`
// would keep the object — and its duration charge — alive for as long
// as anybody was connected. What the object loses when it is evicted
// is its memory, so a socket carries its own subscriptions
// (`serializeAttachment`) and they come back with it.
//
// And nobody is carried on the service's say-so alone. Every socket is
// asked who it is, and carried only for a device the service has given
// a current activation — the device in use of an account with a
// subscription — or for a backup juror (relay.mjs, serviceGate). The
// account's own object (Household) is asked whether an activation is
// still the one in use as a socket shows it, and tells this object to
// close a device's sockets the moment another device of its account
// takes the account up (`/revoke`, below).
//
// And little is written down. Presence is ephemeral by definition —
// forwarded to whoever is listening and forgotten — so its object has
// no storage to pay for and nothing to sweep. A table's or a lobby's
// tag keeps only the lobby kind tagged for it, in its object's own
// storage, for a day (tag_store.mjs, docs/08-own-relays.md); anything
// else that is not ephemeral is refused rather than quietly dropped.

import wasm from '../../app/web/schnorr.wasm';

import { limitsFrom, objectRelay, presenceTag, schnorrVerifier, serviceGate, tagOf, tally } from './relay.mjs';
import { tagStore } from './tag_store.mjs';
import { Bench as BenchObject, callIn } from './bench.mjs';
import { withConfig } from '../functions/deployment.mjs';
// The service's settings that are not secret, as the Pages worker reads
// them (service/functions/deployment.mjs): here, the service's public
// key, which an activation has to be signed by.
import config from '../../config/openhearts.json';

// One object per account, through which its codes, claims, drops and
// device in use run one at a time (service/functions/worker.mjs, "one
// account at a time"). It lives here because a Pages project cannot
// define a Durable Object of its own, only bind one.
export { Household } from '../functions/worker.mjs';

// The jurors of last resort, a Cloudflare Container started when a table
// calls for a juror and nobody is there (bench.mjs).
export class Bench extends BenchObject {
  constructor(state, env = {}) {
    super(state, withConfig(env, config));
  }
}

/// How often one object passes a call on to the backup jurors: a table
/// calls every ten seconds while it is short, and they need one.
const WAKE_EVERY_MS = 20 * 1000;

export class TagRelay {
  constructor(state, env = {}) {
    this.state = state;
    this.env = withConfig(env, config);
    this.relay = null;
    // What the operator watches, if the dataset is bound (wrangler.toml,
    // OH_METRICS): a line of counts a minute, nothing about anyone.
    this.tally = tally(env.OH_METRICS ?? null);
    this.wokeAt = 0;
  }

  /// A call for a juror heard here, passed to the backup jurors where
  /// they are bound (wrangler.toml, BENCH). Not awaited by the relay:
  /// the caller has its OK already, and they take a while to start.
  heard(event) {
    const table = callIn(event);
    if (!table || !this.env.BENCH) return;
    const now = Date.now();
    if (now - this.wokeAt < WAKE_EVERY_MS) return;
    this.wokeAt = now;
    const bench = this.env.BENCH.get(this.env.BENCH.idFromName('bench'));
    this.state.waitUntil(
      // A wake that does not get through is said again by the table's
      // next call, ten seconds on.
      bench.fetch(`https://bench/wake?table=${encodeURIComponent(table)}`, { method: 'POST' }).catch((e) => console.log(`backup jurors not woken: ${e}`)),
    );
  }

  /// The relay for this object, built on first use — which is the
  /// first message after every wake, since an evicted object comes
  /// back empty. What is kept is the promise of it rather than the
  /// relay, so a second message arriving while the first is still
  /// waiting for the wasm gets the relay the first one built and not
  /// one of its own.
  ready() {
    return (this.relay ??= this.build());
  }

  /// The sockets this object already holds are handed back to the new
  /// relay with the subscriptions they were carrying. What the relay
  /// takes from each of them is bounded (relay.mjs, objectLimits): the
  /// tag is open to anybody, and every device on it shares this one
  /// thread.
  async build() {
    const [verify, limits] = await Promise.all([schnorrVerifier(wasm), limitsFrom(this.env)]);
    const tag = (this.tag ??= (await this.state.storage.get('tag')) ?? presenceTag);
    const presence = tag === presenceTag;
    // A table's or a lobby's tag keeps the lobby kind (docs/08-own-relays.md):
    // what an evicted object held comes back from its own storage.
    const kept = tagStore(this.state.storage, tag);
    const relay = objectRelay(verify, {
      tag,
      count: (what, n) => this.tally.count(what, n),
      // The operator's limits are presence's; a table's are the relay's own.
      limits: presence ? limits : null,
      heard: (event) => this.heard(event),
      store: await kept.load(),
      kept: (event, gone) => this.state.waitUntil(kept.keep(event, gone)),
      gate: this.gate(verify, tag),
    });
    for (const socket of this.state.getWebSockets()) {
      const carried = socket.deserializeAttachment();
      relay.open(socket, carried?.v === 2 ? carried.subs : carried, carried?.v === 2 ? carried.auth : null);
    }
    return relay;
  }

  /// Who may use this object (relay.mjs, serviceGate): a device with a
  /// current activation from the service whose key the deployment names
  /// (OH_SERVICE_KEY), still its account's device in use as the
  /// account's own object says — or a backup juror, by OH_JUROR_SECRET.
  /// Without the service's key nobody is: a relay that carried anybody
  /// would be live play without a subscription.
  gate(verify, tag) {
    const env = this.env;
    const service = /^[0-9a-f]{64}$/.test(env.OH_SERVICE_KEY ?? '') ? env.OH_SERVICE_KEY : '0'.repeat(64);
    return serviceGate({
      service,
      verify,
      bench: env.OH_JUROR_SECRET ?? null,
      seen: env.HOUSEHOLD
        ? async (who) => {
            try {
              const stub = env.HOUSEHOLD.get(env.HOUSEHOLD.idFromName(who.account));
              const answer = await (
                await stub.fetch('https://household/', {
                  method: 'POST',
                  body: JSON.stringify({ op: 'seen', account: who.account, key: who.key, epoch: who.epoch, tag }),
                })
              ).json();
              return answer.status === 409 ? answer.body?.error ?? 'superseded: another device of this account is in use' : null;
            } catch {
              // The account's object out of reach: the service's
              // signature stands, until its hour is up or the object
              // says otherwise.
              return null;
            }
          }
        : null,
    });
  }

  /// A day's stored events gone; the relay in memory built again from
  /// storage at the next message.
  async alarm() {
    if (this.tag === undefined) this.tag = (await this.state.storage.get('tag')) ?? presenceTag;
    if (await tagStore(this.state.storage, this.tag).sweep()) this.relay = null;
  }

  async fetch(request) {
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
      // The account's own object, telling this one that a device of the
      // account has been superseded (Household, revokerOf). Only an
      // object reaches here without a websocket: the worker below hands
      // an object nothing else.
      if (request.method === 'POST' && new URL(request.url).pathname === '/revoke') {
        const { account, epoch } = await request.json();
        if (typeof account === 'string' && Number.isSafeInteger(epoch)) (await this.ready()).revoke(account, epoch);
        return new Response('ok\n');
      }
      return new Response('this is a relay: open a websocket\n', { status: 426 });
    }
    // The tag this object is for, said once and kept: an object cannot
    // read its own name, and an alarm has no request to read it from.
    if (this.tag === undefined) {
      const tag = tagOf(new URL(request.url).pathname) || presenceTag;
      this.tag = tag;
      if ((await this.state.storage.get('tag')) !== tag) await this.state.storage.put('tag', tag);
    }
    const relay = await this.ready();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server);
    relay.open(server);
    this.tally.count('opened');
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket, message) {
    // The protocol is JSON text; a binary frame is not one of ours.
    if (typeof message !== 'string') return;
    const relay = await this.ready();
    await relay.message(socket, message);
    // What this socket must remember if the object is evicted before
    // its next message: its subscriptions, bounded by the relay itself,
    // which holds a client to a few, and who it answered as.
    socket.serializeAttachment({ v: 2, subs: relay.subscriptionsOf(socket), auth: relay.authOf(socket) });
  }

  async webSocketClose(socket) {
    (await this.ready()).close(socket);
    this.tally.count('closed');
  }

  async webSocketError(socket) {
    (await this.ready()).close(socket);
    this.tally.count('closed');
  }
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    // The root answers, for the monitor that asks whether the relay is
    // up (observability/monitoring.mjs); it opens no object.
    if (path === '/') return new Response('open hearts relay: a relay lives at /<tag>\n', { status: 200 });
    const tag = tagOf(path);
    if (!tag) return new Response('a relay lives at /<tag>\n', { status: 404 });
    // An object is handed websockets and nothing else: what it answers
    // otherwise is for the account's own object alone.
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('this is a relay: open a websocket\n', { status: 426 });
    }
    // One object per tag, found by name: every client that asks for
    // this tag, wherever it is in the world, lands on this one object.
    return env.TABLE.get(env.TABLE.idFromName(tag)).fetch(request);
  },
};
