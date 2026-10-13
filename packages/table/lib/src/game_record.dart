/// A game's whole record, as it is kept for anyone to look at after the
/// fact: the table, every decision with the signed events behind it,
/// the juries that carried, and the escrow pieces released for seats
/// that left (record.dart, `verifyRecord` takes exactly these).
///
/// Nothing in it is taken on trust: every event carries its author's
/// signature, and a record read back is verified as one played was —
/// a copy that verifies is the game, whoever kept it.
library;

import 'package:engine/engine.dart' show seatCount;

import 'client.dart';
import 'events.dart';
import 'spec.dart';

class GameRecord {
  const GameRecord({required this.spec, required this.record, this.juries = const [], this.releases = const [], this.names = const {}});

  final TableSpec spec;
  final List<Decision> record;
  final List<Decision> juries;
  final List<TableEvent> releases;

  /// What each person was called at the table, by seat. Not signed: a
  /// name is what a device said it was called, and shown as that. The
  /// moves are what the record vouches for.
  final Map<int, String> names;

  /// What a table's client holds once the game is over.
  factory GameRecord.of(TableClient client, {Map<int, String> names = const {}}) =>
      GameRecord(spec: client.spec, record: client.record, juries: client.juries, releases: client.releases, names: names);

  /// The record's form. Version 2 carries with each removal the signed
  /// word of everyone who backed it ([Decision.backing]); version 1,
  /// kept before, names them by key alone, and is read as it was.
  static const version = 2;

  Map<String, Object?> toJson() => {
        'v': version,
        'spec': spec.toJson(),
        'record': [for (final d in record) _decision(d)],
        if (juries.isNotEmpty) 'juries': [for (final d in juries) _decision(d)],
        if (releases.isNotEmpty) 'releases': [for (final e in releases) e.toJson()],
        if (names.isNotEmpty) 'names': {for (final e in names.entries) '${e.key}': e.value},
      };

  static Map<String, Object?> _decision(Decision d) => {
        'turn': [d.turn.hand, d.turn.index],
        'event': d.event.toJson(),
        'witnesses': d.witnesses.toList()..sort(),
        if (d.removal) 'removal': true,
        if (d.among.isNotEmpty) 'among': d.among.toList()..sort(),
        if (d.jury) 'jury': true,
        if (d.verdict case final v?) 'verdict': v.toJson(),
        if (d.removal) 'backing': [for (final e in d.backing ?? const <TableEvent>[]) e.toJson()],
      };

  /// Null for anything that is not a record, or carries an event whose
  /// signature does not check. Whether the record is a legal game is
  /// the verifier's to say, not this.
  static GameRecord? parse(Object? json, {bool verifySignatures = true}) {
    try {
      final m = json as Map;
      final v = m['v'];
      if (v != 1 && v != version) return null;
      final spec = TableSpec.parse(m['spec']);
      if (spec == null) return null;
      TableEvent event(Object? e) =>
          TableEvent.parse(Map<String, Object?>.from(e as Map), verifySignature: verifySignatures) ?? (throw const FormatException('event'));
      TableEvent ours(Object? e) {
        final made = event(e);
        if (made.table != spec.id) throw const FormatException('another table\'s event');
        return made;
      }

      Decision decision(Object? raw) {
        final d = raw as Map;
        final turn = d['turn'] as List;
        return Decision(
          turn: TurnId(turn[0] as int, turn[1] as int),
          event: ours(d['event']),
          witnesses: {for (final k in d['witnesses'] as List) k as String},
          removal: d['removal'] == true,
          among: {for (final k in (d['among'] as List?) ?? const []) k as String},
          jury: d['jury'] == true,
          verdict: d['verdict'] == null ? null : event(d['verdict']),
          // Kept before removals carried their backing: the keys are
          // all there is ([Decision.backing]).
          backing: v == 1 ? null : [for (final e in (d['backing'] as List?) ?? const []) ours(e)],
        );
      }

      return GameRecord(
        spec: spec,
        record: [for (final d in m['record'] as List) decision(d)],
        juries: [for (final d in (m['juries'] as List?) ?? const []) decision(d)],
        releases: [for (final e in (m['releases'] as List?) ?? const []) event(e)],
        names: {
          for (final e in ((m['names'] as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') case final seat? when seat >= 0 && seat < seatCount && e.value is String)
              seat: (e.value as String).length > 40 ? (e.value as String).substring(0, 40) : e.value as String,
        },
      );
    } catch (_) {
      return null;
    }
  }
}
