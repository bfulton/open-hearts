/// What a finished game says about ratings, and how it is published.
///
/// At the end of a rated game every human at the table publishes the
/// same result — the table, the seats, the final totals, who was there
/// from the deal and who left — signed with their device's key. A
/// person in a result is an account, not a device: each line names the
/// account, with the licence that says the seat's key is one of its
/// devices (licence.dart), so anyone folding results can check whose
/// it is. A table's result stands when a majority of the accounts who
/// sat down published the same one, each by the device it sat with.
/// From every result that stands, in order, ratings fall out
/// (rating.dart), for accounts and for the bots that started the game;
/// a bot that took over a leaver's seat has no stake, and a leaver
/// finishes last.
///
/// A result is attested by the humans at the table alone, so a table
/// of one human is attested by that one human.
///
/// Ratings began again with accounts: results go under their own tag
/// ([GameResult.tag]), and a result that names no account — one from
/// before, keyed by device — is not folded.
library;

import 'dart:convert';

import 'package:engine/engine.dart';

import 'licence.dart';
import 'nostr.dart';
import 'rating.dart';
import 'signing.dart';
import 'spec.dart';

/// One seat's line in a result.
class SeatResult {
  const SeatResult(
      {required this.human, this.key, this.account, this.licence, this.bot, required this.total, required this.fromStart, this.left = false});

  final bool human;

  /// The key of the device the human sat with, or null for a bot.
  final PublicKey? key;

  /// The human's account, or null for a bot: whose result this is.
  final AccountId? account;

  /// The service's word that [key] is a device of [account].
  final Licence? licence;

  /// Who a line is about: the account, or the bot's identity.
  String get id => account ?? bot!;

  /// The bot's identity — its persona at its level, `Persona.id` — or
  /// null for a human.
  final String? bot;

  /// The seat's final total.
  final int total;

  /// Whether whoever holds the seat at the end held it from the deal.
  final bool fromStart;

  /// A human who left, was booted or fell silent: they finish last.
  final bool left;

  Map<String, Object?> toJson() => {
        if (key != null) 'key': key,
        if (account != null) 'account': account,
        if (licence != null) 'licence': licence!.toJson(),
        if (bot != null) 'bot': bot,
        'total': total,
        'fromStart': fromStart,
        if (left) 'left': true,
      };

  static SeatResult? parse(Object? json) {
    try {
      final m = json as Map;
      final human = m['key'] is String;
      // A person is an account here: a line keyed by a device alone is
      // from before accounts, and not a line at all.
      if (human && m['account'] is! String) return null;
      if (!human && m['bot'] is! String) return null;
      final licence = m['licence'] == null ? null : Licence.parse(m['licence']) ?? (throw const FormatException('licence'));
      return SeatResult(
        human: human,
        key: m['key'] as String?,
        account: m['account'] as String?,
        licence: licence,
        bot: m['bot'] as String?,
        total: m['total'] as int,
        fromStart: m['fromStart'] as bool,
        left: m['left'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

class GameResult {
  const GameResult({required this.table, required this.rated, required this.seats, required this.at});

  final String table;
  final bool rated;

  /// Seat order. A seat a human left holds two lines' worth: the human
  /// who left it, marked [SeatResult.left], and the bot that finished
  /// it, marked not from the start — so a table may have more than
  /// four lines.
  final List<SeatResult> seats;

  /// Relay time when published, seconds.
  final int at;

  /// The relay's tag every result carries, so one subscription finds
  /// them all. Not the tag device-keyed results went under before
  /// accounts: ratings started again with them.
  static const tag = 'standings';

  /// What a result says it is, so that one of another shape is never
  /// read as one of these.
  static const version = 2;

  Map<String, Object?> toJson() => {
        'kind': 'result',
        'v': version,
        'table': table,
        'rated': rated,
        'seats': [for (final s in seats) s.toJson()],
      };

  /// The bytes two results are compared by: everything but who said it.
  String get digest => sha256Hex(utf8.encode(jsonEncode(toJson())));

  static GameResult? parse(NostrEvent e) {
    try {
      final m = Map<String, Object?>.from(jsonDecode(e.content) as Map);
      if (m['kind'] != 'result' || m['v'] != version) return null;
      final seats = [for (final s in m['seats'] as List) SeatResult.parse(s)!];
      return GameResult(table: m['table'] as String, rated: m['rated'] == true, seats: seats, at: e.createdAt);
    } catch (_) {
      return null;
    }
  }

  /// Builds a result from a finished game: the spec says who sat down,
  /// the holders who finished, and the totals settle it.
  factory GameResult.of(TableSpec spec, List<SeatHolder> finalHolders, List<int> totals, {Set<PublicKey> gone = const {}}) {
    final seats = <SeatResult>[];
    for (var s = 0; s < seatCount; s++) {
      final start = spec.seats[s];
      final end = finalHolders[s];
      if (start is HumanSeat && end is BotSeat) {
        // Left: the human finishes last, the bot has no stake.
        seats.add(SeatResult(human: true, key: start.key, account: start.account, licence: start.licence, total: totals[s], fromStart: true, left: true));
        seats.add(SeatResult(human: false, bot: end.persona.id, total: totals[s], fromStart: false));
      } else if (start is HumanSeat) {
        seats.add(SeatResult(human: true, key: start.key, account: start.account, licence: start.licence, total: totals[s], fromStart: true));
      } else {
        seats.add(SeatResult(human: false, bot: (start as BotSeat).persona.id, total: totals[s], fromStart: true));
      }
    }
    return GameResult(table: spec.id, rated: spec.rated, seats: seats, at: 0);
  }

  /// The accounts who sat down, whose majority makes the result stand.
  Set<AccountId> get humans => {for (final s in seats) if (s.account != null) s.account!};

  /// The account whose device [key] sat here, or null for a key that
  /// sat nowhere at this table.
  AccountId? accountAt(PublicKey key) {
    for (final s in seats) {
      if (s.key == key) return s.account;
    }
    return null;
  }

  /// Whether every person's line names its account by a licence for
  /// the key it sat with, where accounts are checked ([licenceFits]),
  /// and no account sits twice. Without a clock: a result is folded
  /// long after the licences in it ran out.
  bool get licensed {
    final seen = <AccountId>{};
    for (final s in seats) {
      if (!s.human) continue;
      if (s.licence != null && s.licence!.account != s.account) return false;
      if (!licenceFits(s.licence, s.key!)) return false;
      if (!seen.add(s.account!)) return false;
    }
    return true;
  }
}

/// What one player's finished games come to: enough to put on a
/// profile, and no more than the results themselves say.
///
/// A game is won by the lowest total, which is Hearts; a tie at the
/// bottom counts for everyone tied, because the game does not break
/// them. A seat its player left counts as played and not won, since
/// leaving is not a result to be proud of and the rating already says
/// so.
class Tally {
  const Tally({this.games = 0, this.won = 0, this.points = 0, this.best});

  final int games;
  final int won;

  /// Every final total added up, for the average.
  final int points;

  /// The lowest total in any of them.
  final int? best;

  double? get average => games == 0 ? null : points / games;

  /// One player's line through [results]: an account, or a bot.
  static Tally of(String id, Iterable<GameResult> results, {bool? rated}) {
    var games = 0, won = 0, points = 0;
    int? best;
    for (final r in results) {
      if (rated != null && r.rated != rated) continue;
      final mine = r.seats.where((s) => s.id == id).toList();
      if (mine.isEmpty) continue;
      // A seat with two lines — a human who left and the bot that
      // finished it — is one game for the human, at the total they
      // left behind.
      final seat = mine.first;
      games++;
      points += seat.total;
      if (best == null || seat.total < best) best = seat.total;
      if (seat.left) continue;
      final lowest = r.seats.where((s) => !s.left).map((s) => s.total).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      if (lowest != null && seat.total == lowest) won++;
    }
    return Tally(games: games, won: won, points: points, best: best);
  }
}

/// Ratings from results: fold every result that stands, in order.
class Ledger {
  Ledger({this.prior});

  /// Where an identity with no results yet starts: a person at
  /// [Rating.fresh]; a bot at its level's calibrated rating, if the
  /// caller says so ([Persona.priorRating]).
  final Rating? Function(String id)? prior;

  final Map<String, Rating> _ratings = {};
  final Map<String, int> _games = {};

  /// Every result folded into this ledger, oldest first — the ones
  /// that stood. Kept because a rating is not the only thing a
  /// finished game says: what a seat scored, and where it came, are in
  /// here too, and nothing else on the device has them.
  final List<GameResult> standing = [];

  /// A person's account or a bot's `Persona.id`.
  Rating of(String id) => _ratings[id] ?? prior?.call(id) ?? Rating.fresh;
  int gamesOf(String id) => _games[id] ?? 0;

  /// Applies one result. Every seat with a stake — a human, or a bot
  /// there from the deal — is rated against every other such seat by
  /// final total; a leaver's total counts as worse than everyone's.
  void apply(GameResult r) {
    standing.add(r);
    if (!r.rated) return;
    final staked = r.seats.where((s) => s.human || s.fromStart).toList();
    String idOf(SeatResult s) => s.id;
    int totalOf(SeatResult s) => s.left ? 1 << 20 : s.total;
    final before = {for (final s in staked) idOf(s): of(idOf(s))};
    for (final s in staked) {
      final outcomes = <Outcome>[
        for (final o in staked)
          if (o != s)
            (
              opponent: before[idOf(o)]!,
              score: totalOf(s) < totalOf(o)
                  ? 1.0
                  : totalOf(s) == totalOf(o)
                      ? 0.5
                      : 0.0,
            ),
      ];
      _ratings[idOf(s)] = rate(before[idOf(s)]!, outcomes);
      _games[idOf(s)] = gamesOf(idOf(s)) + 1;
    }
  }

  /// Folds every result on the relay that stands: grouped by table,
  /// the version a majority of the table's accounts published, each by
  /// the device it sat with, oldest first.
  static Ledger from(Iterable<NostrEvent> events, {Rating? Function(String id)? prior}) {
    final byTable = <String, Map<String, ({GameResult result, Set<AccountId> signers})>>{};
    for (final e in events) {
      final r = GameResult.parse(e);
      if (r == null || !r.licensed) continue;
      // Only a seat may vouch for its table: the device that sat there
      // for its account, and nobody else of the account or not.
      final account = r.accountAt(e.pubkey);
      if (account == null) continue;
      final versions = byTable.putIfAbsent(r.table, () => {});
      final v = versions.putIfAbsent(r.digest, () => (result: r, signers: {}));
      v.signers.add(account);
    }
    final standing = <GameResult>[];
    for (final versions in byTable.values) {
      for (final v in versions.values) {
        if (v.signers.length >= v.result.humans.length ~/ 2 + 1) {
          standing.add(v.result);
          break;
        }
      }
    }
    standing.sort((a, b) => a.at.compareTo(b.at));
    final ledger = Ledger(prior: prior);
    for (final r in standing) {
      ledger.apply(r);
    }
    return ledger;
  }
}
