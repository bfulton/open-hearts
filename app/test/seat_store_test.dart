/// The seat kept for coming back to after a reload (net/seat_store.dart):
/// the table and each hand's secret, read back as they were; nothing
/// once it is too long ago, or let go — and a seat too long ago told of
/// on the way, for the wait after a game left early
/// (live/left_early.dart).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/net/seat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

void main() {
  final me = FakeSigner('me');
  final spec = TableSpec(
    id: newTableId(),
    seed: 3,
    sealed: true,
    target: 50,
    house: FakeSigner('house').publicKey,
    seats: [HumanSeat(me.publicKey), HumanSeat(FakeSigner('b').publicKey), HumanSeat(FakeSigner('c').publicKey), HumanSeat(FakeSigner('d').publicKey)],
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('what is kept is what comes back: the table, the names, each secret', () async {
    final store = await SeatStore.open();
    final journal = store.keep(spec, {0: 'Ada', 1: 'Bao'}, {0: const Avatar(icon: 'rocket')});
    journal.keep(0, Uint8List.fromList(List.filled(32, 7)));

    final kept = (await SeatStore.open()).load()!;
    expect(kept.spec.id, spec.id);
    expect(kept.names, {0: 'Ada', 1: 'Bao'});
    expect(kept.avatars[0]!.icon, 'rocket');
    expect(kept.journal.secretFor(0), List.filled(32, 7));

    // Read back and kept again, it goes on where it was.
    final again = store.keep(kept.spec, kept.names, kept.avatars, journal: kept.journal);
    again.keep(1, Uint8List.fromList(List.filled(32, 9)));
    final back = store.load()!.journal;
    expect(back.secretFor(0), List.filled(32, 7));
    expect(back.secretFor(1), List.filled(32, 9));
  });

  test('what a build before kept of the events a device signed is let go with the seat, and read as nothing', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await SeatStore.open();
    store.keep(spec, const {}, const {});
    await prefs.setInt('seat.said', 1);
    await prefs.setString('seat.said.0', '{"id": "x"}');
    expect(store.load(), isNotNull);
    store.clear();
    expect(prefs.getKeys().where((k) => k.startsWith('seat.')), isEmpty);
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

  test('whether Play live seated the table is kept with it, and a seat kept by a build before is not one it seated', () async {
    final store = await SeatStore.open();
    store.keep(spec, const {}, const {}, strangers: true);
    final kept = store.load()!;
    expect(kept.strangers, isTrue);
    // Kept again on coming back, as it was.
    store.keep(kept.spec, kept.names, kept.avatars, journal: kept.journal, strangers: kept.strangers);
    expect(store.load()!.strangers, isTrue);
    store.keep(spec, const {}, const {});
    expect(store.load()!.strangers, isFalse, reason: 'a friends\' room');
    // A note written before the flag was.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('seat.table', '{"spec": ${jsonEncode(spec.toJson())}, "names": {}, "avatars": {}}');
    expect(store.load()!.strangers, isFalse);
  });

  test('a seat too long ago to come back to is told of as it is let go: the table, when, and whether Play live seated it', () async {
    final store = await SeatStore.open();
    final before = DateTime.now();
    store.keep(spec, const {0: 'Ada'}, const {}, strangers: true);
    final told = <KeptSeat>[];
    expect(store.load(now: DateTime.now().add(SeatStore.comeBackWithin + const Duration(seconds: 1)), gone: told.add), isNull);
    expect(told, hasLength(1));
    expect(told.single.spec.id, spec.id);
    expect(told.single.strangers, isTrue);
    expect(told.single.at, inInclusiveRange(before.millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch));
    expect(store.load(gone: told.add), isNull, reason: 'cleared on the way, and told of once');
    expect(told, hasLength(1));
  });

  test('a seat to come back to is not told of as gone, nor one from a clock set back', () async {
    final store = await SeatStore.open();
    final told = <KeptSeat>[];
    store.keep(spec, const {}, const {}, strangers: true);
    expect(store.load(now: DateTime.now().add(SeatStore.comeBackWithin - const Duration(seconds: 5)), gone: told.add), isNotNull);
    expect(told, isEmpty);
    // Last here "later" than now: the clock moved, and how long ago is
    // not known, so it is let go without a word.
    expect(store.load(now: DateTime.now().subtract(const Duration(minutes: 1)), gone: told.add), isNull);
    expect(told, isEmpty);
  });
}
