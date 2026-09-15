/// What a player's own games come to, for their own profile.
///
/// Two halves, because they are two different things. Live games are
/// on the relays, signed by everyone who sat at the table, and they are
/// what a rating is made of (packages/table, results.dart). Games
/// played alone never leave the device: what is kept is the record —
/// the seed and every card the player chose (engine, solo_record.dart)
/// — so the way to know what they scored is to play them again, which
/// is thirty games' worth of bots and comes to a few tens of
/// milliseconds. Cheap enough to do when the page opens, and honest:
/// the record is the game, not a number written beside it.
library;

import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'net/standing.dart' as net;
import 'record_store.dart';

/// Everything the profile puts on the screen.
class PlayerStats {
  const PlayerStats({this.rating, this.ratedGames = 0, this.live = const Tally(), this.alone = const Tally(), this.reached = false});

  /// This device's rating, or null when no relay has said yet.
  final Rating? rating;

  /// How many rated games are behind it. None means there is no rating
  /// worth showing, whatever the arithmetic says.
  final int ratedGames;

  /// Every live game this device played, rated or not.
  final Tally live;

  /// Every game it finished against the bots.
  final Tally alone;

  /// Whether a relay answered at all. Nothing live is known until one
  /// does, and "no games" and "not asked" are different things to say.
  final bool reached;

  PlayerStats withLive({required Rating rating, required int ratedGames, required Tally live}) =>
      PlayerStats(rating: rating, ratedGames: ratedGames, live: live, alone: alone, reached: true);

  PlayerStats withAlone(Tally alone) => PlayerStats(rating: rating, ratedGames: ratedGames, live: live, alone: alone, reached: reached);
}

/// The games on this device, played again for their scores.
Tally soloTally(Iterable<String> records) {
  var games = 0, won = 0, points = 0;
  int? best;
  for (final text in records) {
    final record = SoloRecord.parse(text);
    if (record == null) continue;
    final replay = record.replay();
    // A record that stops short is a game that was left, not one that
    // was played: there is no score to claim for it.
    if (!replay.complete) continue;
    final totals = replay.game.totals;
    final mine = totals[record.humanSeat];
    games++;
    points += mine;
    if (best == null || mine < best) best = mine;
    if (replay.game.winners.contains(record.humanSeat)) won++;
  }
  return Tally(games: games, won: won, points: points, best: best);
}

/// The live half: what a standing from the relays says about a key.
PlayerStats fromStanding(PlayerStats onto, net.Standing standing, PublicKey me) =>
    onto.withLive(rating: standing.mine, ratedGames: standing.ledger.gamesOf(me), live: Tally.of(me, standing.ledger.standing));

/// Both halves, as they come. The device's own games are read first
/// because they need nothing but the device; the relays answer when
/// they answer, and may not.
///
/// [standing] is one already in hand — the front door loads it when it
/// connects — which saves opening a second connection to ask the same
/// question. A null [relays] with no [standing] says not to ask at
/// all, which is a door that is deliberately offline.
Stream<PlayerStats> playerStats({required RecordStore store, required Signer signer, List<Uri>? relays, net.Standing? standing}) async* {
  var stats = const PlayerStats();
  stats = stats.withAlone(soloTally(await store.load()));
  yield stats;
  if (standing != null) {
    yield fromStanding(stats, standing, signer.publicKey);
    return;
  }
  if (relays == null) return;
  try {
    final loaded = await net.Standing.load(relays, signer);
    yield fromStanding(stats, loaded, signer.publicKey);
  } catch (_) {
    // No relay answered. The games played alone still stand.
  }
}
