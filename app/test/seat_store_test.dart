/// The seat kept for coming back to after a reload (net/seat_store.dart):
/// every event as it is signed and each hand's secret, read back as they
/// were; nothing once it is too long ago, or let go.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/net/seat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

void main() {
  final me = FakeSigner('me');
  final spec = TableSpec(
    id: newTableId(),
    seed: 3,
    sealed: true,
    target: 50,
    seats: [HumanSeat(me.publicKey), HumanSeat(FakeSigner('b').publicKey), HumanSeat(FakeSigner('c').publicKey), HumanSeat(FakeSigner('d').publicKey)],
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('what is kept is what comes back: the table, the names, each event signed, each secret', () async {
    final store = await SeatStore.open();
    final journal = store.keep(spec, {0: 'Ada', 1: 'Bao'}, {0: const Avatar(icon: 'rocket')});
    final a = TableEvent.sign(me, table: spec.id, kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C'});
    final b = TableEvent.sign(me, table: spec.id, kind: EventKind.witness, body: {'hand': 0, 'turn': 5, 'of': 'x'});
    journal.said(a);
    journal.said(TableEvent.sign(me, table: spec.id, kind: EventKind.heartbeat, body: {'hand': 0, 'step': 1}));
    journal.said(b);
    journal.said(a);
    journal.keep(0, Uint8List.fromList(List.filled(32, 7)));

    final kept = (await SeatStore.open()).load()!;
    expect(kept.spec.id, spec.id);
    expect(kept.names, {0: 'Ada', 1: 'Bao'});
    expect(kept.avatars[0]!.icon, 'rocket');
    expect([for (final e in kept.journal.saidSoFar) e['id']], [a.id, b.id], reason: 'in order, once each, no heartbeat');
    expect(kept.journal.secretFor(0), List.filled(32, 7));

    // Read back and kept again, it goes on where it was.
    final again = store.keep(kept.spec, kept.names, kept.avatars, journal: kept.journal);
    final c = TableEvent.sign(me, table: spec.id, kind: EventKind.play, body: {'hand': 0, 'turn': 8, 'seat': 0, 'card': '3C'});
    again.said(c);
    expect([for (final e in store.load()!.journal.saidSoFar) e['id']], [a.id, b.id, c.id]);
  });

  test('too long ago to come back to, or let go: nothing kept', () async {
    final store = await SeatStore.open();
    store.keep(spec, const {}, const {});
    expect(store.load(now: DateTime.now().add(SeatStore.comeBackWithin + const Duration(seconds: 1))), isNull);
    expect(store.load(), isNull, reason: 'cleared on the way');
    store.keep(spec, const {}, const {});
    store.clear();
    expect(store.load(), isNull);
  });
}
