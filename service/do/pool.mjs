// A pool's object on the relay (docs/explanation/live-play.md#matchmaking):
// the house seats every pool (packages/table, matching.dart, PoolHost),
// and this object wakes it while anybody waits there and it is away.
//
// A pool's seating is the house's alone. A device takes one from its
// build's house and nobody else, so a seating said by anybody else is a
// stray: an app from before the house seated the pools, or somebody
// trying it on. It is withheld (relay.mjs, `withhold`): answered as
// taken, so that the device that said it is not held out of the relay
// for it, and carried to nobody.

/// What a pool's tag starts with (packages/table, relay_transport.dart,
/// RelayTransport.poolPrefix).
export const poolPrefix = 'queue:';

/// Whether [tag] is a pool's.
export const isPoolTag = (tag) => typeof tag === 'string' && tag.startsWith(poolPrefix);

/// The kind somebody waiting says they are, every couple of seconds
/// (packages/table, nostr.dart, TableKinds.waiting).
export const waitingKind = 24245;

/// The stored kind a pool's seating goes out on (relay.mjs, lobbyKind;
/// packages/table, nostr.dart, TableKinds.lobby).
const lobbyKind = 4244;

/// Why a pool's seating from anybody but the house goes nowhere.
export const NOT_THE_HOUSE_WHY = 'withheld: a pool is seated by its house alone';

/// How long after the last word from somebody waiting the pool still
/// wants its house: as long as anybody takes a waiter who has gone
/// quiet to have gone (packages/table, matching.dart, poolStaleMs).
export const poolWantsMs = 7000;

/// [NOT_THE_HOUSE_WHY] for a pool's seating that is not [house]'s, or
/// null for anything else: with no house, nobody's.
export function seatingHeld(event, house) {
  if (event?.kind !== lobbyKind) return null;
  let content;
  try {
    content = JSON.parse(event.content);
  } catch {
    return null;
  }
  if (content?.kind !== 'match') return null;
  return house && event.pubkey === house ? null : NOT_THE_HOUSE_WHY;
}

/// The pool's want of its house, [house]. [here] says whether the house
/// has a socket on the pool's tag now; [wanted] is told each time
/// somebody waits and it has not ([heard], of each event the relay
/// took). Somebody waiting is wanting the house for [poolWantsMs] after
/// they last said so ([wantsHouse]).
export function poolWatch({ house, here, wanted = null, now = Date.now }) {
  let waitedAt = -Infinity;
  const wantsHouse = () => !!house && now() - waitedAt < poolWantsMs && !here();
  return {
    heard(event) {
      if (event.kind !== waitingKind) return;
      waitedAt = now();
      if (wantsHouse()) wanted?.();
    },
    get wantsHouse() {
      return wantsHouse();
    },
  };
}
