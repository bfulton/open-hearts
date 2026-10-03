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
    final replay = TableReplay();
    final v = verifyRecord(read.spec, read.record, juries: read.juries, crypto: crypto, releases: read.releases, replay: replay);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    expect(replay.hands.length, client.game.handNumber + 1, reason: 'every hand of the game');
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
