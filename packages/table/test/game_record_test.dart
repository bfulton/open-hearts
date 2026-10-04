/// A game's record written out and read back is the same game: it
/// verifies as the one played did, to the end — and a copy tampered
/// with does not read at all.
library;

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  /// Plays [t] out and returns the first person's record, written out.
  String playedOut(SimTable t) {
    t.start();
    expect(t.run(), isTrue, reason: t.people.first.client.describe());
    final json = jsonEncode(GameRecord.of(t.people.first.client).toJson());
    t.stop();
    return json;
  }

  void verifiesComplete(String json) {
    final read = GameRecord.parse(jsonDecode(json));
    expect(read, isNotNull);
    final v = verifyRecord(read!.spec, read.record, juries: read.juries, crypto: crypto, releases: read.releases);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue);
  }

  test('a sealed game of two and two bots, written out and read back, verifies to the end', () {
    final json = playedOut(SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4));
    verifiesComplete(json);
    final bytes = utf8.encode(json).length;
    final packed = gzip.encode(utf8.encode(json)).length;
    // What one costs to keep, said where a test run shows it.
    print('a game\'s record: ${(bytes / 1024).toStringAsFixed(0)} KB, ${(packed / 1024).toStringAsFixed(0)} KB packed');
  });

  test('the replay of a verified record: every hand dealt, passed and played, and the scores as the game kept them', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    t.start();
    expect(t.run(), isTrue);
    final client = t.people.first.client;
    final read = GameRecord.parse(jsonDecode(jsonEncode(GameRecord.of(client).toJson())))!;
    t.stop();
    // Each hand announced as its check is done, as a page shows them
    // while the rest is checked: read back from its JSON, as a worker
    // sends it, the last word on each hand is the hand.
    final announced = <int, Map<String, Object?>>{};
    final order = <int>[];
    final replay = TableReplay(onHand: (h) {
      announced[h.number] = jsonDecode(jsonEncode(h.toJson())) as Map<String, Object?>;
      order.add(h.number);
    });
    final v = verifyRecord(read.spec, read.record, juries: read.juries, crypto: crypto, releases: read.releases, replay: replay);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    expect(replay.hands.length, client.game.handNumber + 1, reason: 'every hand of the game');
    expect(order.first, 0, reason: 'the first hand announced before the second');
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThanOrEqualTo(order[i - 1]), reason: 'in order');
    }
    expect(announced.keys.toList()..sort(), [for (final h in replay.hands) h.number]);
    for (final h in replay.hands) {
      expect(TableReplayHand.fromJson(announced[h.number]!).toJson(), h.toJson(), reason: 'hand ${h.number} as announced');
    }
    for (final h in replay.hands) {
      expect(h.plays.length, 52, reason: 'hand ${h.number}');
      expect(h.tricks.length, 13);
      expect(h.plays.map((p) => p.card).toSet().length, 52, reason: 'every card once');
      final dealt = h.dealt!;
      final held = h.held!;
      expect(dealt.expand((c) => c).toSet().length, 52);
      for (var s = 0; s < seatCount; s++) {
        expect(dealt[s].length, 13);
        expect(held[s].length, 13);
        // What a seat held is what it played.
        expect(h.plays.where((p) => p.seat == s).map((p) => p.card).toSet(), held[s].toSet(), reason: 'hand ${h.number}, seat $s');
        final passed = h.passedBy(s);
        expect(passed.length, PassDirection.forHand(h.number) == PassDirection.hold ? 0 : 3, reason: 'hand ${h.number}, seat $s');
      }
      expect(h.scores.reduce((a, b) => a + b), anyOf(26, 78), reason: 'twenty-six a hand, or a moon');
    }
    expect(replay.hands.last.totals, client.game.totals, reason: 'the game\'s own totals');
  });

  test('one who left mid-game: the escrow released for their seat is in the record too', () {
    final t = SimTable(humans: 2, seed: 61, crypto: crypto, jurors: jurySize + 4);
    t.people[1]
      ..exit = Exit.idle
      ..exitAt = Moment.offTurn;
    final json = playedOut(t);
    verifiesComplete(json);
  });

  test('names travel with the record, as labels, and nonsense in them is dropped', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto);
    t.start();
    expect(t.run(), isTrue);
    final json = GameRecord.of(t.people.first.client, names: {0: 'Ada', 2: 'Cy'}).toJson();
    t.stop();
    (json['names'] as Map)['9'] = 'nobody';
    (json['names'] as Map)['1'] = 'x' * 500;
    final read = GameRecord.parse(jsonDecode(jsonEncode(json)))!;
    expect(read.names, {0: 'Ada', 1: 'x' * 40, 2: 'Cy'});
  });

  test('a copy with one event changed, or an event from another table, does not read', () {
    final json = jsonDecode(playedOut(SimTable(humans: 4, seed: 3, crypto: crypto))) as Map<String, Object?>;
    final record = json['record'] as List;
    final event = (record[20] as Map)['event'] as Map;
    final body = Map<String, Object?>.from(event['body'] as Map)..['seat'] = ((event['body'] as Map)['seat'] as int) ^ 1;
    final forged = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
    ((forged['record'] as List)[20] as Map)['event'] = {...event, 'body': body};
    expect(GameRecord.parse(forged), isNull, reason: 'its id no longer matches what it says');
    final moved = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
    (moved['spec'] as Map)['id'] = 'another-table';
    expect(GameRecord.parse(moved), isNull, reason: 'every event is the table\'s own');
    expect(GameRecord.parse(json), isNotNull);
  });
}
