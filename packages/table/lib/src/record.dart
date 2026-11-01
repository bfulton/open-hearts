/// A game played at a refereed table, kept for anyone to look at after
/// the fact, and checked by anyone: the table's spec and the referee's
/// log as it came (log.dart), every entry of it.
///
/// Checking it is playing it again. The rules every side played by
/// (rules.dart) are run over the log by a side with no seat and no key:
/// every event's signature, every move against the turn it was for and
/// the cards the seat held, and at a sealed table every step of the deal
/// — each key's proof, each shuffle's argument, each token — then every
/// card opened by the audits. And the house's word on how it came out,
/// which names the log as it stood at the end by its hash: a log kept
/// with any entry changed, dropped, put in or out of order is not the
/// one the house signed for, and does not check.
///
/// A game kept before the referee is the other record
/// (legacy/v2_record.dart).
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'client.dart';
import 'events.dart';
import 'log.dart';
import 'names.dart';
import 'replay.dart';
import 'rules.dart';
import 'signing.dart';
import 'spec.dart';

class GameRecord {
  const GameRecord({required this.spec, required this.log, this.names = const {}});

  final TableSpec spec;

  /// The referee's log, every entry in order, as it came.
  final List<LogEntry> log;

  /// What each person was called at the table, by seat. Not signed: a
  /// name is what a device said it was called, and shown as that.
  final Map<int, String> names;

  /// The record's form: the first two were kept before the referee
  /// (legacy/v2_record.dart).
  static const version = 3;

  /// What [client] holds of its table: the log as far as it has read it.
  factory GameRecord.of(TableClient client, {Map<int, String> names = const {}}) =>
      GameRecord(spec: client.tableSpec!, log: List.of(client.rules.log), names: names);

  Map<String, Object?> toJson() => {
        'v': version,
        'spec': spec.toJson(),
        'log': [for (final e in log) e.toJson()],
        if (names.isNotEmpty) 'names': {for (final e in names.entries) '${e.key}': e.value},
      };

  /// The form a stored record's JSON says it is in, or null for none.
  static int? versionOf(Object? json) => json is Map && json['v'] is int ? json['v'] as int : null;

  /// Null for anything that is not a record of this form: every entry
  /// numbered from zero, in order, each one an entry the referee sends.
  /// An event that does not read is an entry that changes nothing, as at
  /// the table (LogEntry.unread); whether the whole is a game is the
  /// verifier's to say ([verifyRecord]).
  static GameRecord? parse(Object? json, {bool verifySignatures = true}) {
    try {
      final m = json as Map;
      if (m['v'] != version) return null;
      final spec = TableSpec.parse(m['spec']);
      if (spec == null) return null;
      final log = <LogEntry>[];
      for (final raw in m['log'] as List) {
        final e = LogEntry.parse(raw, verifySignature: verifySignatures);
        if (e == null || e.n != log.length) return null;
        log.add(e);
      }
      return GameRecord(
        spec: spec,
        log: log,
        names: {
          for (final e in ((m['names'] as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') case final seat? when seat >= 0 && seat < seatCount && e.value is String)
              seat: cleanName(e.value as String, most: 40),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a record comes to.
class RecordVerdict {
  const RecordVerdict({
    required this.ok,
    required this.reason,
    this.state = TableState.waiting,
    this.totals = const [],
    this.winners = const [],
    this.vouched = false,
    this.removals = const {},
  });

  /// Whether everything in the record checked: the start is its spec's,
  /// every entry reads, and the house — at a sealed table — signed for
  /// the log as it is.
  final bool ok;
  final String reason;

  /// How the game stood at the record's end: finished, ended, or failed;
  /// still playing, for a record kept before the end.
  final TableState state;
  final List<int> totals;

  /// The seats with the lowest total, once the game is finished.
  final List<int> winners;

  /// Whether the house's word on the end is in the log and names the log
  /// as it stood then. A sealed game's record checks only with it.
  final bool vouched;

  /// Each person who gave up their seat, and how.
  final Map<int, Exit> removals;

  bool get complete => state == TableState.finished || state == TableState.ended || state == TableState.failed;
}

/// Plays [record] again, and says what it comes to. [house] is the house
/// this build plays with: a sealed record naming another is not one of
/// its games. [replay] is filled hand by hand as each is checked, for a
/// page to show the game as it goes.
///
/// A game is kept once it is over, so a log that does not reach the end
/// of the game does not check: a log bent anywhere the rules or the deal
/// vouch for stops the game there. [allowUnfinished] takes one kept
/// before the end, as far as it goes.
RecordVerdict verifyRecord(GameRecord record, {DealCrypto? crypto, PublicKey? house, TableReplay? replay, bool allowUnfinished = false}) {
  final spec = record.spec;
  RecordVerdict no(String why) => RecordVerdict(ok: false, reason: why);
  if (record.log.isEmpty) return no('the log is empty');
  final start = record.log.first.event;
  final started = start == null || start.kind != EventKind.start ? null : TableSpec.parse(start.body['spec']);
  if (started == null || jsonEncode(started.toJson()) != jsonEncode(spec.toJson())) {
    return no('the log does not start this table');
  }
  // Every person's seat held to its licence, as a seating is before
  // anyone sits: with no clock to hold its date to after the game.
  final unlicensed = spec.licenceProblem();
  if (unlicensed != null) return no(unlicensed);
  if (spec.sealed) {
    if (crypto == null) return no('a sealed game, and no deal here to check it with');
    if (house != null && spec.house != house) return no('the table names another house');
  }
  // Games are kept for good, and a game kept before a pass hid its
  // proofs is read as it was made.
  final rules = TableRules(tableId: spec.id, crypto: crypto, readsOldPasses: true);
  if (replay != null) {
    var shown = 0;
    void playsUpTo(int hand) {
      for (; shown < rules.moves.length; shown++) {
        final m = rules.moves[shown];
        if (m.hand > hand) break;
        if (m.card != null) replay.played(m.hand, m.seat, m.card!);
      }
    }

    rules.onHandOver = (game, deal) {
      playsUpTo(game.handNumber);
      replay.ended(game, deal);
    };
    try {
      _feedAll(rules, record.log);
    } catch (e) {
      return no('the log does not play: $e');
    }
    playsUpTo(1 << 30);
  } else {
    try {
      _feedAll(rules, record.log);
    } catch (e) {
      return no('the log does not play: $e');
    }
  }
  if (rules.state == TableState.waiting || rules.spec == null) return no('the log does not start a table');
  if (!rules.over && !allowUnfinished) return no('the log does not reach the end of the game: ${rules.describe()}');
  final vouched = rules.result != null;
  if (spec.sealed && rules.over && rules.state != TableState.failed && !vouched) {
    return no('the house did not sign for this log');
  }
  final finished = rules.state == TableState.finished;
  return RecordVerdict(
    ok: true,
    reason: '',
    state: rules.state,
    totals: rules.game.totals,
    winners: finished ? rules.game.winners : const [],
    vouched: vouched,
    removals: {for (final e in rules.removals.entries) e.key: e.value.exit},
  );
}

void _feedAll(TableRules rules, List<LogEntry> log) {
  for (final e in log) {
    rules.feed(e);
    if (rules.waitingToTake > 0) throw StateError('the deal waits on a call made elsewhere');
  }
}
