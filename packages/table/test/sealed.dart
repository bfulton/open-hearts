/// What a finished sealed table is held to, for sealed_test.dart and
/// the files beside it: one table's tests are split three ways so they
/// run side by side.
library;

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// Every one of [among] holds the same record, and it verifies.
/// [among] is the survivors, unless a client is out of the table
/// without knowing it — a modified one that stopped applying the
/// record is still seated as far as it can tell.
void agreeAmong(SimTable t, Iterable<TableClient> among) {
  final records = [for (final c in among) c.record.map((d) => d.key).toList()];
  for (final r in records) {
    expect(r, records.first, reason: 'every survivor holds the same record');
  }
  final totals = [for (final c in among) c.game.totals];
  for (final s in totals) {
    expect(s, totals.first);
  }
  final first = among.first;
  final v = verifyRecord(t.spec, first.record, juries: first.juries, crypto: t.crypto, releases: first.releases);
  expect(v.ok, isTrue, reason: v.reason);
  expect(v.complete, isTrue, reason: 'a finished sealed game verifies to the end');
  expect(v.winners, first.game.winners);
}

void agree(SimTable t) => agreeAmong(t, t.survivors);
