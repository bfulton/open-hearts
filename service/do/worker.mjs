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
// And nothing is written down. Presence is ephemeral by definition —
// forwarded to whoever is listening and forgotten — so this object has
// no storage to pay for, none to read on the way back from
// hibernation, and nothing that would ever need sweeping. A kind that
// is not ephemeral is refused rather than quietly dropped, and the
// client writes it to the relays that keep things (app/lib/net/
// relays.dart): tables have not moved here.

import wasm from '../../app/web/schnorr.wasm';

import { objectRelay, schnorrVerifier, tagOf } from './relay.mjs';

export class TagRelay {
  constructor(state) {
    this.state = state;
    this.relay = null;
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
    const relay = objectRelay(await schnorrVerifier(wasm));
    for (const socket of this.state.getWebSockets()) relay.open(socket, socket.deserializeAttachment());
    return relay;
  }

  async fetch(request) {
    if (request.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('this is a relay: open a websocket\n', { status: 426 });
    }
    const relay = await this.ready();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server);
    relay.open(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket, message) {
    // The protocol is JSON text; a binary frame is not one of ours.
    if (typeof message !== 'string') return;
    const relay = await this.ready();
    await relay.message(socket, message);
    // What this socket must remember if the object is evicted before
    // its next message. Bounded by the relay itself, which holds a
    // client to a few subscriptions.
    socket.serializeAttachment(relay.subscriptionsOf(socket));
  }

  async webSocketClose(socket) {
    (await this.ready()).close(socket);
  }

  async webSocketError(socket) {
    (await this.ready()).close(socket);
  }
}

export default {
  async fetch(request, env) {
    const tag = tagOf(new URL(request.url).pathname);
    if (!tag) return new Response('a relay lives at /<tag>\n', { status: 404 });
    // One object per tag, found by name: every client that asks for
    // this tag, wherever it is in the world, lands on this one object.
    return env.TABLE.get(env.TABLE.idFromName(tag)).fetch(request);
  },
};
