/// Where an event is written among a set of relays: the one place the
/// choice lives, so the real relay group (`relays.dart`) and the
/// simulator (`sim/sim_network.dart`) decide it the same way and
/// neither can drift from the other. Relays are identified by whatever
/// type the caller uses — a `Uri` for real sockets, a name for the
/// simulator — so the rules here are generic over it.
///
/// The rule, in one place: a write goes to one relay, the first the
/// readers can read; or, when it must be seen whatever a reader has
/// lost — told to go everywhere, or with no readable relay up — to
/// every relay that is up.
library;

/// The relays every peer heard from lately reads in common, or null
/// when no peer has said what it reads — then the writer's own order
/// decides. [reads] is what each peer last said it reads and when;
/// entries older than [staleMs] at [nowMs] are dropped and the map is
/// pruned in place, since a peer long unheard is out of the reckoning
/// as it is out of the table's.
Set<R>? readByFrom<K, R>(Map<K, ({Set<R> reads, int at})> reads, int nowMs, int staleMs) {
  reads.removeWhere((_, v) => nowMs - v.at > staleMs);
  if (reads.isEmpty) return null;
  Set<R>? all;
  for (final v in reads.values) {
    all = all == null ? Set.of(v.reads) : all.intersection(v.reads);
  }
  return all;
}

/// Whether a write goes to every relay that is up rather than one:
/// when told to go [everywhere], or when the readers' common relays
/// ([readBy]) are known and not one of them is up — a relay nobody at
/// the table can read is no place for the event, so it goes to all
/// that are up. [up] is the relays up and not refusing this writer.
bool floodWrite<R>(Iterable<R> up, Set<R>? readBy, {required bool everywhere}) {
  if (everywhere) return true;
  if (readBy == null) return false;
  final upList = up is List<R> ? up : up.toList();
  return upList.isNotEmpty && !upList.any(readBy.contains);
}

/// The single relay a write goes to when it is not [floodWrite]: the
/// first in [order] that is [up] and, when the readers' common relays
/// [readBy] are known, among them. Null when none qualifies — then the
/// event goes nowhere and the protocol's own repeats carry it later.
R? firstTarget<R>(List<R> order, Set<R> up, Set<R>? readBy) {
  for (final r in order) {
    if (!up.contains(r)) continue;
    if (readBy != null && !readBy.contains(r)) continue;
    return r;
  }
  return null;
}
