/// The table's clocks: how long a person and the house each have for a
/// turn, how long a closed connection is waited for, and how long past
/// its deadline the house is waited for before the game fails.
///
/// Every side applies them to the referee's times (rules.dart), so every
/// side has to have the same ones. A table's timing is chosen once, by
/// whoever seats it: the house, with the operator's clocks, at a pool's
/// table (matching.dart, PoolHost), and the starting device, from its
/// remote config (docs/explanation/service.md), at a friends' table. It
/// rides in the spec the log starts with (`TableSpec.timing`).
library;

import 'time_bank.dart';

class TableTiming {
  const TableTiming({
    this.bank = TimeBank.standard,
    this.botActsMs = 15000,
    this.botDealsMs = 40000,
    this.houseGraceMs = 20000,
    this.silenceMs = 30000,
  });

  /// The timing a table has unless the device that starts it is told
  /// otherwise.
  static const standard = TableTiming();

  /// A person's clock: a grace per decision, a bank per hand
  /// (time_bank.dart).
  final TimeBank bank;

  /// How long the house has for a bot seat's card or pass. A bot's move
  /// is worked out rather than thought about, so this is a deadline on a
  /// computation and not on a person: there is no grace in it and no
  /// bank behind it.
  final int botActsMs;

  /// And for a bot seat's step of the deal or its audit, which wait on
  /// the slow calls of the deal's cryptography.
  final int botDealsMs;

  /// How long past either of those the house is waited for before the
  /// game ends as failed: time for a restarted service to come back and
  /// read the log where it left it. Nobody else can play a bot seat's
  /// cards, so a house gone longer is a game nobody can finish.
  final int houseGraceMs;

  /// How long a person's connection may stay closed before the table
  /// gives their seat to a bot at their turn, without waiting on their
  /// clock (docs/explanation/live-play.md): half a minute, sooner than a
  /// full bank runs out (time_bank.dart), and long enough for a reload.
  /// A device that is there and slow is timed by its clock.
  final int silenceMs;

  /// The fields as a spec carries them, all in milliseconds.
  Map<String, int> toJson() => {
        'graceMs': bank.graceMs,
        'passGraceMs': bank.passGraceMs,
        'bankMs': bank.bankMs,
        'fixedMs': bank.fixedMs,
        'botActsMs': botActsMs,
        'botDealsMs': botDealsMs,
        'houseGraceMs': houseGraceMs,
        'silenceMs': silenceMs,
      };

  /// What each field may be, in milliseconds, least and most. The
  /// worker checks a remote config's `table` against the same
  /// (service/functions/config.mjs, `tableTimingOf`).
  static const bounds = {
    'graceMs': (2000, 60000),
    'passGraceMs': (2000, 120000),
    'bankMs': (10000, 300000),
    'fixedMs': (15000, 120000),
    'botActsMs': (5000, 60000),
    'botDealsMs': (15000, 120000),
    'houseGraceMs': (10000, 120000),
    'silenceMs': (10000, 600000),
  };

  /// The timing [json] says, field by field, with [base]'s for any
  /// field it does not name.
  ///
  /// Every side parses the same spec and has to come out with the same
  /// clocks, so this is a function of [json] alone, and all or nothing:
  /// a field of the wrong type or outside its [bounds], and the whole
  /// timing is [base]. Clamping one field and keeping the rest would be
  /// as deterministic, but would make a table nobody chose. Names it
  /// does not know are passed over, for a later build's fields and an
  /// earlier one's.
  static TableTiming parse(Object? json, {TableTiming base = standard}) {
    if (json is! Map) return base;
    final at = base.toJson();
    for (final MapEntry(:key, :value) in json.entries) {
      final range = bounds[key];
      if (range == null) continue;
      if (value is! int || value < range.$1 || value > range.$2) return base;
      at[key as String] = value;
    }
    return TableTiming(
      bank: TimeBank(
        graceMs: at['graceMs']!,
        passGraceMs: at['passGraceMs']!,
        bankMs: at['bankMs']!,
        fixedMs: at['fixedMs']!,
      ),
      botActsMs: at['botActsMs']!,
      botDealsMs: at['botDealsMs']!,
      houseGraceMs: at['houseGraceMs']!,
      silenceMs: at['silenceMs']!,
    );
  }

  /// The timing [json] says in full, or null: every field named, each
  /// an int inside its [bounds], and nothing else. What a table's start
  /// carries (spec.dart), which every side, of every build, has to read
  /// as the same clocks: so nothing is filled in from a standard that
  /// another build may have changed, and a field this build does not
  /// know is a clock it cannot keep, and no table it can sit at.
  static TableTiming? exactly(Object? json) {
    if (json is! Map || json.length != bounds.length) return null;
    for (final MapEntry(:key, value: (least, most)) in bounds.entries) {
      final v = json[key];
      if (v is! int || v < least || v > most) return null;
    }
    return parse(json);
  }

  /// This timing with a person's clock of [bank]'s.
  TableTiming withBank(TimeBank bank) => TableTiming(
        bank: bank,
        botActsMs: botActsMs,
        botDealsMs: botDealsMs,
        houseGraceMs: houseGraceMs,
        silenceMs: silenceMs,
      );

  @override
  bool operator ==(Object other) {
    if (other is! TableTiming) return false;
    final a = toJson();
    final b = other.toJson();
    return a.keys.every((k) => a[k] == b[k]);
  }

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() => 'TableTiming(${toJson()})';
}
