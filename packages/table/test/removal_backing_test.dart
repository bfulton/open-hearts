/// A removal counts on the record only by the signed word of those who
/// backed it (Decision.backing): a key the record names with nothing
/// signed behind it is no backer.
///
/// A record names a removal's backers. Kept before removals carried
/// their backing (GameRecord, version 1), it named them by key alone,
/// and anyone keeping a record could name the others at the table as
/// backing a boot they never saw, or the game's end. Records now carry
/// the claims and witnesses themselves, and the verifier counts those.
library;

import 'dart:convert';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late SimTable t;
  late GameRecord played;
  late List<PublicKey> humans;
  Signer signerOf(PublicKey key) => t.people.firstWhere((p) => p.client.signer.publicKey == key).client.signer;

  setUpAll(() {
    t = SimTable(humans: 4, seed: 3, target: 1);
    t.start();
    expect(t.run(), isTrue, reason: t.people.first.client.describe());
    played = GameRecord.of(t.people.first.client);
    humans = [for (final h in played.spec.seats) if (h is HumanSeat) h.key];
  });
  tearDownAll(() => t.stop());

  /// [record] as a kept game travels: written out and read back.
  GameRecord kept(List<Decision> record) =>
      GameRecord.parse(jsonDecode(jsonEncode(GameRecord(spec: played.spec, record: record).toJson())))!;

  Verification check(GameRecord g) => verifyRecord(g.spec, g.record);

  test('the game as played verifies', () {
    final v = check(kept(played.record));
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue);
  });

  /// The last play of the game, which a forged boot takes the place of:
  /// the seat's bot plays the one card left, so the game goes on to the
  /// same end.
  (int, Decision) lastPlay() {
    final i = played.record.lastIndexWhere((d) => d.event.kind == EventKind.play && humans.contains(d.event.author));
    return (i, played.record[i]);
  }

  Decision bootOf(Decision victim, {required List<TableEvent> backing, PublicKey? by}) {
    final forger = by ?? humans.firstWhere((k) => k != victim.event.author);
    final boot = TableEvent.sign(signerOf(forger),
        table: played.spec.id, kind: EventKind.boot, body: {'hand': victim.turn.hand, 'turn': victim.turn.index, 'seat': victim.event.seat});
    return Decision(
      turn: victim.turn,
      event: boot,
      witnesses: {...humans}..remove(victim.event.author),
      removal: true,
      among: {...humans},
      backing: [boot, ...backing],
    );
  }

  test('a boot whose backers are named and not signed is refused', () {
    final (i, victim) = lastPlay();
    final forged = [...played.record.sublist(0, i), bootOf(victim, backing: const []), ...played.record.sublist(i + 1)];
    final v = check(kept(forged));
    expect(v.ok, isFalse);
    expect(v.reason, 'a boot of seat ${victim.event.seat} at ${victim.turn} without a majority behind it (1 of 4)');
  });

  test('a boot with the others\' signed word behind it counts', () {
    final (i, victim) = lastPlay();
    final forger = humans.firstWhere((k) => k != victim.event.author);
    final draft = bootOf(victim, backing: const [], by: forger);
    // The witnesses a third and a fourth person would have signed.
    final witnesses = [
      for (final k in humans)
        if (k != forger && k != victim.event.author)
          TableEvent.sign(signerOf(k), table: played.spec.id, kind: EventKind.witness, body: {
            'event': draft.event.id,
            'hand': victim.turn.hand,
            'turn': victim.turn.index,
            'seat': victim.event.seat,
          }),
    ];
    final backed = Decision(
      turn: draft.turn,
      event: draft.event,
      witnesses: draft.witnesses,
      removal: true,
      among: draft.among,
      backing: [draft.event, ...witnesses],
    );
    final v = check(kept([...played.record.sublist(0, i), backed, ...played.record.sublist(i + 1)]));
    expect(v.ok, isTrue, reason: v.reason);
  });

  /// The game cut short halfway: a claim that it ends there, by
  /// [claimants], with [backing] beside the first's.
  List<Decision> endedAt(List<PublicKey> claimants, {List<TableEvent> Function(Decision at)? backing}) {
    final cut = played.record.length ~/ 2;
    final at = played.record[cut];
    final claims = [
      for (final k in claimants)
        TableEvent.sign(signerOf(k),
            table: played.spec.id,
            kind: EventKind.ended,
            body: {'hand': at.turn.hand, 'turn': at.turn.index, 'seat': at.event.seat, 'vote': true}),
    ];
    return [
      ...played.record.sublist(0, cut),
      Decision(
        turn: at.turn,
        event: claims.first,
        witnesses: {...humans},
        removal: true,
        among: {...humans},
        backing: [...claims, ...?backing?.call(at)],
      ),
    ];
  }

  test('the game\'s end claimed by one person, the rest named and not signed, is refused', () {
    final forged = endedAt([humans.first]);
    final v = check(kept(forged));
    expect(v.ok, isFalse);
    expect(v.reason, 'the game ended at ${forged.last.turn} without a majority behind it (1 of 4)');
  });

  test('the game\'s end claimed by a majority, each by their own signed word, counts', () {
    final v = check(kept(endedAt(humans.take(3).toList())));
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.ended, isTrue);
  });

  test('signed word for another way out, or for another event, backs no end', () {
    final forged = endedAt([humans.first], backing: (at) => [
          // Boots of the seat at that turn: a way out, not the end.
          for (final k in humans.skip(1).take(2))
            TableEvent.sign(signerOf(k),
                table: played.spec.id, kind: EventKind.boot, body: {'hand': at.turn.hand, 'turn': at.turn.index, 'seat': at.event.seat}),
          // And a witness of the move that settled the turn.
          TableEvent.sign(signerOf(humans[3]), table: played.spec.id, kind: EventKind.witness, body: {
            'event': at.event.id,
            'hand': at.turn.hand,
            'turn': at.turn.index,
            'seat': at.event.seat,
          }),
        ]);
    final v = check(kept(forged));
    expect(v.ok, isFalse);
    expect(v.reason, 'the game ended at ${forged.last.turn} without a majority behind it (1 of 4)');
  });

  test('a record kept before removals carried their backing reads as it did, by its keys', () {
    // Version 1: no backing beside any removal, and the keys named are
    // all there is (records.mjs keeps no new record of that form).
    final (i, victim) = lastPlay();
    final json = GameRecord(
      spec: played.spec,
      record: [...played.record.sublist(0, i), bootOf(victim, backing: const []), ...played.record.sublist(i + 1)],
    ).toJson()
      ..['v'] = 1;
    for (final d in json['record']! as List) {
      (d as Map).remove('backing');
    }
    final read = GameRecord.parse(jsonDecode(jsonEncode(json)))!;
    expect(read.record.where((d) => d.removal).single.backing, isNull);
    expect(check(read).ok, isTrue);
  });
}
