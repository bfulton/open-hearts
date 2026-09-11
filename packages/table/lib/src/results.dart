/// What a finished game says about ratings, and how it is published.
///
/// At the end of a rated game every human at the table publishes the
/// same result — the table, the seats, the final totals, who was there
/// from the deal and who left — signed with their key. A table's
/// result stands when a majority of the humans who sat down published
/// the same one. From every result that stands, in order, ratings fall
/// out (rating.dart), for people and for the bots that started the
/// game; a bot that took over a leaver's seat has no stake, and a
/// leaver finishes last.
///
/// Until the verifiable deal and the juror exist (docs 03, 04) the deal
/// is a seed everyone can read and a table of one human is attested by
/// that one human, so these ratings are provisional: fine for a reward,
/// not yet for a claim.
library;

import 'dart:convert';

import 'package:engine/engine.dart';

import 'nostr.dart';
import 'rating.dart';
import 'signing.dart';
import 'spec.dart';

/// One seat's line in a result.
class SeatResult {
  const SeatResult({required this.human, this.key, this.bot, required this.total, required this.fromStart, this.left = false});

  final bool human;

  /// The human's key, or null for a bot.
  final PublicKey? key;

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
        if (bot != null) 'bot': bot,
        'total': total,
        'fromStart': fromStart,
        if (left) 'left': true,
      };

  static SeatResult? parse(Object? json) {
    try {
      final m = json as Map;
      return SeatResult(
        human: m['key'] is String,
        key: m['key'] as String?,
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
  /// them all.
  static const tag = 'results';

  Map<String, Object?> toJson() => {
        'kind': 'result',
        'table': table,
        'rated': rated,
        'seats': [for (final s in seats) s.toJson()],
      };

  /// The bytes two results are compared by: everything but who said it.
  String get digest => sha256Hex(utf8.encode(jsonEncode(toJson())));

  static GameResult? parse(NostrEvent e) {
    try {
      final m = Map<String, Object?>.from(jsonDecode(e.content) as Map);
      if (m['kind'] != 'result') return null;
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
        seats.add(SeatResult(human: true, key: start.key, total: totals[s], fromStart: true, left: true));
        seats.add(SeatResult(human: false, bot: end.persona.id, total: totals[s], fromStart: false));
      } else if (start is HumanSeat) {
        seats.add(SeatResult(human: true, key: start.key, total: totals[s], fromStart: true));
      } else {
        seats.add(SeatResult(human: false, bot: (start as BotSeat).persona.id, total: totals[s], fromStart: true));
      }
    }
    return GameResult(table: spec.id, rated: spec.rated, seats: seats, at: 0);
  }

  /// The humans who sat down, whose majority makes the result stand.
  Set<PublicKey> get humans => {for (final s in seats) if (s.key != null) s.key!};
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

  /// A person's key or a bot's `Persona.id`.
  Rating of(String id) => _ratings[id] ?? prior?.call(id) ?? Rating.fresh;
  int gamesOf(String id) => _games[id] ?? 0;

  /// Applies one result. Every seat with a stake — a human, or a bot
  /// there from the deal — is rated against every other such seat by
  /// final total; a leaver's total counts as worse than everyone's.
  void apply(GameResult r) {
    if (!r.rated) return;
    final staked = r.seats.where((s) => s.human || s.fromStart).toList();
    String idOf(SeatResult s) => s.key ?? s.bot!;
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
  /// the version a majority of the table's humans published, oldest
  /// first.
  static Ledger from(Iterable<NostrEvent> events, {Rating? Function(String id)? prior}) {
    final byTable = <String, Map<String, ({GameResult result, Set<PublicKey> signers})>>{};
    for (final e in events) {
      final r = GameResult.parse(e);
      if (r == null || !r.humans.contains(e.pubkey)) continue; // only a seat may vouch for its table
      final versions = byTable.putIfAbsent(r.table, () => {});
      final v = versions.putIfAbsent(r.digest, () => (result: r, signers: {}));
      v.signers.add(e.pubkey);
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
