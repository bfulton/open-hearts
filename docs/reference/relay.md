# Relay tags, kinds and limits

This page lists the relay's address, the tags and event kinds that live play uses on it, the limits it holds each socket to, what it stores and for how long, and the shape of a reaction.

For why the relay works this way, see [the relay](../explanation/relay.md).

## Address

| Build | Relay | Defined in |
|---|---|---|
| Deployed (web and phone) | `wss://relay.openhearts.game/{tag}`: the tag replaces `{tag}` (`tagMark` in `packages/table/lib/src/presence_relay.dart`) | `ourRelay` in `app/lib/net/relays.dart` |
| Deployed, with `relays` in the remote config | Up to `MOST_RELAYS` relays on `openhearts.game` or a subdomain | [Remote config](configuration.md#remote-config) |
| Served from a local host | `ws://127.0.0.1:7447`, or the port in the page's `?relay=PORT` | `localRelay` and `localRelayAt` in `app/lib/net/relays.dart` |
| Built with the `OH_RELAYS` define | That comma list | `devRelay` in `app/lib/net/relays.dart` |

The tag in the path names a Durable Object, so everyone on one tag reaches the same object (`TABLE.idFromName(tag)` in `service/do/worker.mjs`). A tag is one path segment of letters, digits and `._:@+-` (`tagShape` and `tagOf` in `service/do/relay.mjs`).

| Request | Answer |
|---|---|
| `GET /` | 200, `open hearts relay: a relay lives at /<tag>`. The monitors ask this. |
| A path that is not a tag | 404 |
| A tag, without a WebSocket upgrade | 426 |
| A tag, with a WebSocket upgrade | The tag's object |

## Tags

| Tag | Shape | Defined by | Kinds published on it |
|---|---|---|---|
| `online` | The one presence tag | `presenceTag` in `service/do/relay.mjs`; `RelayPresence.topic` in `packages/table/lib/src/presence_relay.dart` | 24246 |
| A table's ID | 32 lowercase hex characters | `newTableId` in `packages/table/lib/src/spec.dart` | 24242, 24243, 24247, 24248 |
| A pool | `queue:<pool>`, or `queue:<pool>:<target>` for a game that does not run to the default score | `poolTag` in `packages/table/lib/src/matching.dart`; `RelayTransport.poolPrefix` in `packages/table/lib/src/relay_transport.dart` | 24245 (`wait`), 4244 (`match`, `picture`) |
| A room code | 8 characters | `Room.newCode` and `Room.validCode` in `app/lib/net/room.dart` | 24245 (`here`), 4244 (`start`, `picture`) |
| The results tag | One fixed name, which every result carries | `GameResult.tag` in `packages/table/lib/src/results.dart` | 4244 (`result`) |

## Kinds

The kind numbers are `TableKinds` in `packages/table/lib/src/nostr.dart`. Kinds 20000 to 29999 are ephemeral: the relay forwards them and forgets them (`ephemeral` in `service/do/relay.mjs`).

| Kind | Name | Tags | Carries | Ephemeral |
|---|---|---|---|---|
| 4244 | `TableKinds.lobby` | `t`: the pool, room code or results tag | JSON with a `kind`: `match` (a pool's seating of a table), `start` (a room's table started), `picture` (a player's picture), `result` (a finished game's result, `GameResult`) | No |
| 22242 | `TableKinds.auth` | `relay`, `challenge`, and `activation` (the device's activation, as JSON) or `bench` (a backup juror's mark) | A device's answer to the relay's challenge (NIP-42), sent in an `AUTH` message. The relay reads it and does not forward it. | Yes |
| 24242 | `TableKinds.table` | `t`: the table ID | A table event (`packages/table/lib/src/events.dart`) as JSON | Yes |
| 24243 | `TableKinds.signal` | `p`: the recipient; `t`: the table ID | A WebRTC offer, answer or ICE candidate, sealed to the recipient with NIP-44 v2 (`packages/table/lib/src/nip44.dart`) | Yes |
| 24245 | `TableKinds.waiting` | `t`: the pool or room code | A beat: `wait` from a player waiting in a pool, `here` from a member of a friends' room | Yes |
| 24246 | `TableKinds.presence` | `t`: `online`; `p`: the juror, on a summons | JSON with a `kind`: `here` (status and activation), `gone`, `summons` (to a juror), `call` (a table's call for a backup juror) | Yes |
| 24247 | `TableKinds.watch` | `t`: the table ID | A watcher saying it is watching (`{"watching": true, "licence": …}`), or a seated player's view of the table (`WatchedTable` in `packages/table/lib/src/watch.dart`) | Yes |
| 24248 | `TableKinds.react` | `t`: the table ID, and nothing else | A reaction. See [Reactions](#reactions). | Yes |

## Messages

The relay speaks a subset of NIP-01, plus NIP-42's `AUTH` (`createRelay` in `service/do/relay.mjs`).

| From | Message |
|---|---|
| Client | `EVENT`, `REQ`, `CLOSE`, `AUTH` |
| Relay | `AUTH` (a challenge, as each socket opens), `OK`, `EVENT`, `EOSE`, `CLOSED`, `NOTICE` |

A deployed relay object holds every socket's `EVENT`, `REQ` and `CLOSE` until the socket answers the challenge (`serviceGate`). It carries a socket only for a device with a current activation, which is the device in use of an account with a subscription, or for a backup juror.

The reason in a refusal starts with one of these words:

| Prefix | Meaning |
|---|---|
| `rate-limited:` | The socket published more than its burst and rate allow. Checked before the signature. |
| `invalid:` | A bad ID or signature, or a reaction of the wrong size or shape. |
| `blocked:` | This tag's object does not carry this kind, or a reaction is on the wrong tag. |
| `duplicate:` | The relay already has this event. The `OK` is `true`. |
| `auth-required:` | The socket has not answered the challenge, or its answer is stale or carries no current activation. |
| `restricted:` | Not a backup juror. The relay closes the socket. |
| `superseded:` | Another device of this account is in use. The relay closes the socket. |
| `too big:` | A `NOTICE`: a message or `REQ` over its limit. |

## Limits

Each deployed tag's object holds every socket to these limits. `service/do/host.mjs` applies them only with `--object`, which is how `OH_RELAY=object` runs it.

| Limit | `online` | Every other tag |
|---|---|---|
| Longest message, in characters | `objectLimits.message` | `tableLimits.message` |
| Longest `REQ`, in characters | `objectLimits.request` | `tableLimits.request` |
| Events a socket may publish at once | `objectLimits.burst` | `tableLimits.burst` |
| Events a socket may publish each second, after the burst | `objectLimits.perSecond` | `tableLimits.perSecond` |
| Subscriptions per socket; the oldest goes when a new one arrives | `maxSubscriptions` | `maxSubscriptions` |
| Messages held while the challenge is unanswered | `heldMost` | `heldMost` |
| Age of an answer to the challenge, in seconds | `answerFreshS` | `answerFreshS` |
| Event IDs remembered to answer duplicates | `rememberedIds` | `rememberedIds` |

All are in `service/do/relay.mjs`. The operator can change the `online` limits with the [relay settings](configuration.md#relay-settings) row, within `objectLimitBounds`. `tableLimits` is fixed in code.

## What is stored

| What | Kept | Defined by |
|---|---|---|
| Ephemeral kinds, on any tag | Not stored: forwarded to matching subscriptions, then forgotten | `ephemeral` in `service/do/relay.mjs` |
| Anything on `online` that is not ephemeral | Refused | `refusalFor` |
| Kind 4244 on a pool, room code or table tag, tagged `t` with that same tag | A day, in the object's own storage; an alarm deletes older events | `KEPT_MS` and `SWEEP_EVERY_MS` in `service/do/tag_store.mjs` |
| Kind 4244 on the results tag (`GameResult.tag`) | For good | `resultsTag` in `service/do/relay.mjs`; `tagStore` in `service/do/tag_store.mjs` |
| Any other kind that is not ephemeral | Refused | `refusalFor` |

A stored event survives the object being evicted. The object holds the newest `storedKeep(tag)` stored events in memory, and sends those that match to each new subscription before `EOSE`. A client reads a pool's seatings back only for `RelayTransport.poolHistorySeconds` (`packages/table/lib/src/relay_transport.dart`).

## Reactions

A reaction is kind 24248 (`TableKinds.react`; `reactionKind` in `service/do/relay.mjs`). It is ephemeral, and it is not part of the table's record.

| Part | Rule | Checked by |
|---|---|---|
| Tag | The table's own ID, and only that: the tags are exactly `[["t", "<table ID>"]]` | `reactionRefusal` in `service/do/relay.mjs` |
| Content length | At most `reactionMost` characters | `reactionRefusal`; `ReactionSaid.most` in `packages/table/lib/src/reactions.dart` |
| Content | A JSON object with exactly three fields: `{"react":"nice","hand":2,"turn":17}` | `reactionRefusal`; `ReactionSaid.decode` |
| `react` | Lowercase letters, 1 to 16. The relay does not list the codes, so a new code needs no relay change. | `reactionRefusal` |
| `hand` | The hand number, from 0 to `ReactionSaid.lastHand` | `reactionRefusal`; `ReactionSaid.decode` |
| `turn` | How many of the hand's cards had been played, from 0 to 52 | `reactionRefusal`; `ReactionSaid.decode` |

The codes the app knows, and the emoji each shows as, are the `Reaction` enum in `packages/table/lib/src/reactions.dart`.

Both ends apply `ReactionRules` in `packages/table/lib/src/reactions.dart`:

- A player says at most one reaction every `ReactionRules.gap`, and each shows for `ReactionRules.shownFor`.
- A screen shows a reaction only from a key that holds a seat in person, about the current hand or one either side of it, made within `ReactionRules.staleAfter`, heard for the first time, and not sooner than `ReactionRules.gap` less `ReactionRules.jitter` after the last one shown from that key.
