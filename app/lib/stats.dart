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
import 'pace_store.dart';
import 'record_store.dart';

/// Everything the profile puts on the screen.
class PlayerStats {
  const PlayerStats({
    this.rating,
    this.ratedGames = 0,
    this.live = const Tally(),
    this.alone = const Tally(),
    this.reached = false,
    this.pace = Pace.fresh,
    this.history = const SoloHistory(),
  });

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

  /// How long this device takes over a card, as it has measured itself
  /// (pace_store.dart). Never on a relay: nobody else can agree on it,
  /// and nobody else is told.
  final Pace pace;

  /// The games alone hand by hand: the recent scores and what the
  /// queen and the moon did (soloGames).
  final SoloHistory history;

  PlayerStats withLive({required Rating rating, required int ratedGames, required Tally live}) =>
      PlayerStats(rating: rating, ratedGames: ratedGames, live: live, alone: alone, reached: true, pace: pace, history: history);

  PlayerStats withAlone(Tally alone, [SoloHistory? history]) => PlayerStats(
      rating: rating, ratedGames: ratedGames, live: live, alone: alone, reached: reached, pace: pace, history: history ?? this.history);

  PlayerStats withPace(Pace pace) =>
      PlayerStats(rating: rating, ratedGames: ratedGames, live: live, alone: alone, reached: reached, pace: pace, history: history);
}

/// The games alone looked at hand by hand, for the profile's chart and
/// its three numbers: what the last games came to, and what happened
/// to the queen and the moon along the way.
class SoloHistory {
  const SoloHistory({this.recent = const [], this.hands = 0, this.queens = 0, this.moonsShot = 0, this.moonsBlocked = 0});

  /// How many games the chart shows.
  static const shown = 20;

  /// The player's final score in each of their last [shown] finished
  /// games, oldest first, so it reads left to right as it was played.
  final List<int> recent;

  /// Hands played to the end, over every game kept.
  final int hands;

  /// Hands in which the player took the queen of spades.
  final int queens;

  /// Hands in which the player took all twenty-six.
  final int moonsShot;

  /// Hands in which somebody else was running at the moon — the queen
  /// and ten hearts or more, and not all of them — and the player took
  /// one of the hearts they did not get: a run the player broke up.
  final int moonsBlocked;

  /// The mean of [recent]; null with nothing in it.
  double? get average => recent.isEmpty ? null : recent.reduce((a, b) => a + b) / recent.length;
}

/// A run at the moon, as [SoloHistory.moonsBlocked] counts one: the
/// queen and this many hearts or more.
const runAtTheMoon = 10;

/// What one hand's [tricks] say for the player at [me]: whether they
/// took the queen, shot the moon, or broke up somebody else's run at it
/// ([SoloHistory.moonsBlocked]).
({bool queen, bool shot, bool blocked}) handFacts(List<List<Play>> tricks, {required int? moonShooter, required int me}) {
  final hearts = List.filled(seatCount, 0);
  int? tookQueen;
  for (final trick in tricks) {
    final winner = trickWinner(trick);
    for (final play in trick) {
      if (play.card.suit == Suit.hearts) hearts[winner]++;
      if (play.card.suit == Suit.spades && play.card.rank == Rank.queen) tookQueen = winner;
    }
  }
  final running = tookQueen;
  return (
    queen: tookQueen == me,
    shot: moonShooter == me,
    blocked: moonShooter == null && running != null && running != me && hearts[running] >= runAtTheMoon && hearts[me] > 0,
  );
}

/// The games on this device, played again for their scores.
Tally soloTally(Iterable<String> records) => soloGames(records).tally;

/// The games on this device, played again once for everything the
/// profile says about them: the tally, and the history hand by hand.
/// [records] newest first, as the store keeps them.
({Tally tally, SoloHistory history}) soloGames(Iterable<String> records) {
  var games = 0, won = 0, points = 0;
  int? best;
  var hands = 0, queens = 0, shot = 0, blocked = 0;
  final recent = <int>[];
  for (final text in records) {
    final record = SoloRecord.parse(text);
    if (record == null) continue;
    final replay = record.replay();
    // A record that stops short is a game that was left, not one that
    // was played: there is no score to claim for it.
    if (!replay.complete) continue;
    final me = record.humanSeat;
    final totals = replay.game.totals;
    final mine = totals[me];
    games++;
    points += mine;
    if (best == null || mine < best) best = mine;
    if (replay.game.winners.contains(me)) won++;
    if (recent.length < SoloHistory.shown) recent.add(mine);
    for (final hand in replay.hands) {
      if (hand.tricks.length != 13) continue;
      hands++;
      final facts = handFacts(hand.tricks, moonShooter: hand.moonShooter, me: me);
      if (facts.queen) queens++;
      if (facts.shot) shot++;
      if (facts.blocked) blocked++;
    }
  }
  return (
    tally: Tally(games: games, won: won, points: points, best: best),
    history: SoloHistory(recent: recent.reversed.toList(), hands: hands, queens: queens, moonsShot: shot, moonsBlocked: blocked),
  );
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
  var stats = const PlayerStats().withPace(await PaceStore.load());
  final alone = soloGames(await store.load());
  stats = stats.withAlone(alone.tally, alone.history);
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
