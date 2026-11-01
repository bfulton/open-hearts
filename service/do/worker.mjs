// The relay as one Cloudflare object per tag (docs/explanation/service.md).
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
// subscription — or for the house (relay.mjs, serviceGate). The
// account's own object (Household) is asked whether an activation is
// still the one in use as a socket shows it, and tells this object to
// close a device's sockets the moment another device of its account
// takes the account up (`/revoke`, below).
//
// And little is written down. Presence is ephemeral by definition —
// forwarded to whoever is listening and forgotten — so its object has
// no storage to pay for and nothing to sweep. A table's or a lobby's
// tag keeps only the lobby kind tagged for it, in its object's own
// storage, for a day (tag_store.mjs, docs/explanation/relay.md); anything
// else that is not ephemeral is refused rather than quietly dropped. And
// a table's tag keeps the table's log, which its referee writes down
// entry by entry (referee.mjs): a table goes on where it was after its
// object is evicted, and its log goes a day after its last entry.

import wasm from '../../app/web/schnorr.wasm';

import { limitsFrom, objectRelay, presenceTag, schnorrVerifier, serviceGate, socketLine, tagOf, tally } from './relay.mjs';
import { wakeLimiter } from './referee.mjs';
import { tagStore } from './tag_store.mjs';
import { pictureScreen } from './withheld.mjs';
import { reviewRun } from './review.mjs';
import { KNOWN_OBJECT, KnownPictures as KnownObject, knownAsker, knownReport } from './known.mjs';
import { jpegHasher } from './photodna.mjs';
import { edgeHashes } from 'open-hearts-photodna';
import { accountPictures, ownedScreen } from './profile_pictures.mjs';
import { PICTURES_ROW } from '../functions/pictures.mjs';
import { alertKnownProblem, alertPicturesProblem, alertsOf } from '../functions/alerts.mjs';
import { Household as HouseholdObject } from '../functions/household.mjs';
import { storeOf } from '../functions/rows.mjs';
import { Bench as BenchObject, wakePath } from './bench.mjs';
import { withConfig } from '../functions/deployment.mjs';
// The service's settings that are not secret, as the Pages worker reads
// them (service/functions/deployment.mjs): here, the service's public
// key, which an activation has to be signed by.
import config from '../../config/openhearts.json';

// One object per account, through which its codes, claims, drops,
// device in use and profile run one at a time (service/functions/
// household.mjs, "one account at a time"). It lives here because a Pages
// project cannot define a Durable Object of its own, only bind one; and
// here it reaches what checks and keeps each picture the account sets
// (profile_pictures.mjs): the pictures bucket, Workers AI, and the
// checker of known images in use, through KnownPictures.
export class Household extends HouseholdObject {
  constructor(state, env = {}) {
    const e = withConfig(env, config);
    super(state, env, { pictures: accountPictures(e) });
  }
}

// The house, a Cloudflare Container started when a sealed table wants
// it and it is not there (bench.mjs).
export class Bench extends BenchObject {
  constructor(state, env = {}) {
    super(state, withConfig(env, config));
  }
}

/// Where the checker of known images in use is asked about each new
/// picture, and a match acted on (known.mjs): one object, kept in the
/// United States, hashing pictures for PhotoDNA with the module the
/// deploy adds (photodna_off.mjs), if it does.
export class KnownPictures extends KnownObject {
  constructor(state, env = {}) {
    super(state, withConfig(env, config), { edgeHasher: edgeHashes ? jpegHasher(edgeHashes) : null });
  }
}

export class TagRelay {
  constructor(state, env = {}) {
    this.state = state;
    this.env = withConfig(env, config);
    this.relay = null;
    // What the operator watches, if the dataset is bound (wrangler.toml,
    // OH_METRICS): a line of counts a minute, and one when the last
    // socket goes, nothing about anyone.
    this.tally = tally(env.OH_METRICS ?? null);
    // The house woken for this table or pool, when it is wanted and away
    // (referee.mjs, wakeLimiter; pool.mjs): at most one wake every
    // twenty seconds.
    this.wakeHouse = wakeLimiter({
      wake: () => this.wake(),
      stillWanted: async () => (await this.ready()).wantsHouse,
    });
    // The pictures the operator took down (withheld.mjs), read from the
    // store at most once a minute while pictures come this way.
    this.pictures = pictureScreen({ read: () => this.env.OH_STORE?.get(PICTURES_ROW.join('|'), 'json') ?? null });
    // A picture is carried only as its account's picture now, checked
    // as the account set it (profile_pictures.mjs): the one it set last,
    // as its copies in the pictures bucket say.
    this.owned = ownedScreen({ bucket: this.env.OH_PICTURES ?? null, log: (line) => console.log(line) });
  }

  /// This table's or this pool's house woken where it is bound
  /// (wrangler.toml, BENCH) and told of the tag, not awaited — the
  /// referee has said what it had to already, and a wake that does not
  /// get through is made again on the table's next entry, or as
  /// somebody next says they are waiting in the pool.
  wake() {
    if (!this.env.BENCH) return;
    const bench = this.env.BENCH.get(this.env.BENCH.idFromName('bench'));
    this.state.waitUntil(bench.fetch(`https://bench${wakePath(this.tag)}`, { method: 'POST' }).catch((e) => console.log(`house not woken: ${e}`)));
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
  /// takes from each of them is bounded (relay.mjs, objectLimits on
  /// presence, tableLimits elsewhere): the tag is open to anybody, and
  /// every device on it shares this one thread.
  async build() {
    const [verify, limits] = await Promise.all([schnorrVerifier(wasm), limitsFrom(this.env)]);
    const tag = (this.tag ??= (await this.state.storage.get('tag')) ?? presenceTag);
    const presence = tag === presenceTag;
    // A table's or a lobby's tag keeps the lobby kind (docs/explanation/relay.md):
    // what an evicted object held comes back from its own storage.
    const kept = tagStore(this.state.storage, tag);
    const [store, log] = await Promise.all([kept.load(), kept.loadLog()]);
    const house = /^[0-9a-f]{64}$/.test(this.env.OH_HOUSE_KEY ?? '') ? this.env.OH_HOUSE_KEY : null;
    const relay = objectRelay(verify, {
      tag,
      count: (what, n) => this.tally.count(what, n),
      // The operator's limits are presence's; a table's are the relay's own.
      limits: presence ? limits : null,
      store,
      kept: (event, gone) => this.state.waitUntil(kept.keep(event, gone)),
      withhold: (event) => this.pictures.withheld(event),
      screen: this.owned,
      forget: (event) => this.state.waitUntil(kept.forget(event)),
      gate: this.gate(verify, tag, house),
      house,
      log,
      keepEntry: (entry) => this.state.waitUntil(kept.keepEntry(entry)),
      wanted: () => this.wakeHouse(),
    });
    for (const socket of this.state.getWebSockets()) {
      const carried = socket.deserializeAttachment();
      const v2 = carried?.v === 2;
      relay.open(socket, v2 ? carried.subs : carried, v2 ? carried.auth : null, v2 ? (carried.log ?? null) : null);
    }
    // Whoever the log says is there and has no socket now was cut off
    // while the object was gone.
    relay.settle();
    return relay;
  }

  /// Who may use this object (relay.mjs, serviceGate): a device with a
  /// current activation from the service whose key the deployment names
  /// (OH_SERVICE_KEY), still its account's device in use as the
  /// account's own object says — or the house, by its key (OH_HOUSE_KEY).
  /// Without the service's key nobody is: a relay that carried anybody
  /// would be live play without a subscription.
  gate(verify, tag, house) {
    const env = this.env;
    const service = /^[0-9a-f]{64}$/.test(env.OH_SERVICE_KEY ?? '') ? env.OH_SERVICE_KEY : '0'.repeat(64);
    return serviceGate({
      service,
      verify,
      house,
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
      // account has been superseded, or that the account is suspended,
      // and saying which (Household, revokerOf). Only an
      // object reaches here without a websocket: the worker below hands
      // an object nothing else.
      if (request.method === 'POST' && new URL(request.url).pathname === '/revoke') {
        const { account, epoch, why } = await request.json();
        if (typeof account === 'string' && Number.isSafeInteger(epoch)) (await this.ready()).revoke(account, epoch, why ?? undefined);
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
    // When it opened, which comes back with it from hibernation as its
    // subscriptions do, for the line it gets as it goes.
    server.serializeAttachment({ v: 2, subs: {}, auth: null, at: Date.now() });
    relay.open(server);
    this.tally.count('opened');
    this.say('open', server, relay);
    return new Response(null, { status: 101, webSocket: client });
  }

  /// A socket's coming and going, as a line of JSON for Workers Logs
  /// (relay.mjs, socketLine): read beside a device's own account of its
  /// line when a game is lost (docs/how-to/look-into-a-lost-game.md).
  say(what, socket, relay, end = {}) {
    let openedAt;
    try {
      openedAt = socket.deserializeAttachment()?.at;
    } catch {
      // A socket with nothing kept on it.
    }
    const sockets = this.state.getWebSockets().filter((s) => what === 'open' || s !== socket).length;
    console.log(JSON.stringify(socketLine(what, { tag: this.tag, who: relay.authOf(socket), openedAt, sockets, ...end })));
  }

  async webSocketMessage(socket, message) {
    // The protocol is JSON text; a binary frame is not one of ours.
    if (typeof message !== 'string') return;
    const relay = await this.ready();
    await relay.message(socket, message);
    // What this socket must remember if the object is evicted before
    // its next message: its subscriptions, bounded by the relay itself,
    // which holds a client to a few, who it answered as, the
    // subscription it follows the table's log under, and when it opened.
    const at = socket.deserializeAttachment()?.at;
    socket.serializeAttachment({ v: 2, subs: relay.subscriptionsOf(socket), auth: relay.authOf(socket), log: relay.followedBy(socket), at });
  }

  async webSocketClose(socket, code, reason, wasClean) {
    await this.gone(socket, 'close', { code, clean: wasClean, why: reason });
  }

  async webSocketError(socket, error) {
    await this.gone(socket, 'error', { why: error?.message ?? error });
  }

  async gone(socket, what, end) {
    const relay = await this.ready();
    // Said before the relay lets go of it, while it still knows who
    // the socket answered as.
    this.say(what, socket, relay, end);
    relay.close(socket);
    this.tally.closed(this.state.getWebSockets().filter((s) => s !== socket).length);
  }
}

export default {
  /// Once a day (wrangler.toml, crons): anything left to do after a
  /// match tried again (known.mjs); and the pictures accounts set kept
  /// as long as the privacy policy says and no longer, asked about again
  /// where no checker has cleared them, and emailed to the
  /// operator since the last run, if the config asks for it
  /// (review.mjs).
  async scheduled(controller, env, ctx) {
    const e = withConfig(env, config);
    if (knownAsker(e)) {
      const us = e.KNOWN.jurisdiction('us');
      ctx.waitUntil(
        us
          .get(us.idFromName(KNOWN_OBJECT))
          .fetch('https://known/wake', { method: 'POST' })
          .then((res) => {
            if (!res.ok) throw new Error(`said ${res.status}`);
          })
          .catch((err) => {
            console.log(`known pictures not woken: ${err}`);
            return alertKnownProblem(e, storeOf(e), { what: 'wake', error: `the daily run could not reach the object that acts on matches: ${err?.message ?? err}` });
          }),
      );
    }
    const alerts = alertsOf(e);
    const store = storeOf(e);
    if (!e.OH_PICTURES || !store) return;
    const from = { email: e.OH_MAIL_FROM, name: 'Open Hearts' };
    const send = alerts?.pictures && e.EMAIL ? (mail) => e.EMAIL.send({ to: alerts.to, from, ...mail }) : null;
    ctx.waitUntil(
      reviewRun({ bucket: e.OH_PICTURES, store, records: e.OH_RECORDS ?? null, send, ask: knownAsker(e), log: (line) => console.log(`pictures: ${line}`) }).then(
        (r) => console.log(`pictures: ${r.deleted} deleted, ${r.asked} asked about again, ${r.sent} emailed, ${r.more} for later`),
        (err) => {
          console.log(`pictures: the daily run failed: ${err}`);
          return alertPicturesProblem(e, store, { error: `${err?.message ?? err}` });
        },
      ),
    );
  },

  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    // The root answers, for the monitor that asks whether the relay is
    // up (observability/monitoring.mjs); it opens no object.
    if (path === '/') return new Response('open hearts relay: a relay lives at /<tag>\n', { status: 200 });
    // A picture the operator found, reported by their tool (`oh picture
    // report`).
    if (path === '/known' && request.method === 'POST') return knownReport(request, env);
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
