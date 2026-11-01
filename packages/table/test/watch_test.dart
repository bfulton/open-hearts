/// Watching a table from outside it (watch.dart): what a view says,
/// that it reads back as it was written and nonsense does not read, and
/// who answers a watcher, when.
library;

import 'dart:async';
import 'dart:convert';

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  const names = ['Ada', 'Bao', 'Cy', 'Dee'];

  test('a view mid-game: this hand\'s cards in order, the scores, whose turn; and only what anyone at the table can see', () {
    final t = SimTable(humans: 4, seed: 5);
    t.start();
    // Into the play of the first hand: some tricks in, the hand not over.
    final c = t.people.first.client;
    expect(t.clock.runUntil(() => c.started && c.game.phase == Phase.playing && c.game.tricksPlayed >= 2, limitMs: 10 * 60 * 1000), isTrue);
    final v = WatchedTable.of(c, names);
    expect(v.table, c.tableSpec!.id);
    expect(v.hand, c.game.handNumber);
    expect(v.phase, Phase.playing);
    expect(v.plays.length, greaterThanOrEqualTo(8));
    expect(v.plays.map((p) => p.card).toSet().length, v.plays.length, reason: 'each card once');
    expect(v.plays.first.card, twoOfClubs, reason: 'the hand opens on the two of clubs');
    expect(v.taken, c.game.taken);
    // Nothing hidden in it: no hand held, no pass, nothing of the deal.
    expect(v.toJson().keys.toSet(), {'table', 'target', 'seq', 'hand', 'phase', 'names', 'totals', 'taken', 'plays', 'toPlay', 'keys', 'accounts'});
    // The seats' keys, whose reactions a watcher shows (reactions.dart),
    // and accounts, whom a watcher may have blocked: public already,
    // named by the start event and the record.
    expect(v.keys, [for (final h in c.holders) h is HumanSeat ? h.key : null]);
    expect(v.accounts, [for (final h in c.holders) h is HumanSeat ? h.account : null]);
    final json = jsonEncode(v.toJson());
    final back = WatchedTable.parse(jsonDecode(json), table: c.tableSpec!.id)!;
    expect(back.toJson(), v.toJson());
    expect(WatchedTable.parse(jsonDecode(json), table: 'another table'), isNull, reason: 'a view of one table is not another\'s');

    // To the end: the winners are in the last view.
    expect(t.run(), isTrue);
    final end = WatchedTable.of(c, names);
    expect(end.over, isTrue);
    expect(end.winners, c.game.winners);
    t.close();
  });

  test('nonsense does not read as a view', () {
    final good = WatchedTable(
      table: 'x',
      target: 50,
      seq: 3,
      hand: 0,
      phase: Phase.playing,
      names: names,
      totals: const [0, 0, 0, 0],
      taken: const [0, 0, 0, 0],
      plays: [(seat: 0, card: twoOfClubs)],
      toPlay: 1,
    ).toJson();
    expect(WatchedTable.parse(good, table: 'x'), isNotNull);
    expect(WatchedTable.parse({...good, 'names': ['\u{1F600}' * longestName, 'b', 'c', 'd']}, table: 'x'), isNotNull,
        reason: 'the longest name is a name, though each of its characters is two UTF-16 units');
    expect(WatchedTable.parse({...good, 'accounts': ['ab' * 16, null, 'cd' * 32, null]}, table: 'x')?.accounts, ['ab' * 16, null, 'cd' * 32, null]);
    for (final (what, change) in <(String, void Function(Map<String, Object?>))>[
      ('three names', (m) => m['names'] = ['a', 'b', 'c']),
      ('a card off the deck', (m) => m['plays'] = [[0, 52]]),
      ('a seat off the table', (m) => m['plays'] = [[4, 0]]),
      ('a turn off the table', (m) => m['toPlay'] = 7),
      ('a phase nobody plays', (m) => m['phase'] = 'cheating'),
      ('a score that is not a number', (m) => m['totals'] = [0, 0, 'x', 0]),
      ('a name too long to be one', (m) => m['names'] = ['a' * (longestName + 1), 'b', 'c', 'd']),
      ('a name of emoji too long to be one', (m) => m['names'] = ['\u{1F600}' * (longestName + 1), 'b', 'c', 'd']),
      ('three accounts', (m) => m['accounts'] = ['ab' * 16, null, null]),
      ('an account that is not one', (m) => m['accounts'] = ['AB' * 16, null, null, null]),
    ]) {
      final m = jsonDecode(jsonEncode(good)) as Map<String, Object?>;
      change(m);
      expect(WatchedTable.parse(m, table: 'x'), isNull, reason: what);
    }
    expect(WatchedTable.parse('not a map', table: 'x'), isNull);
  });

  test('a watcher gets the table at once and after every move for a minute after saying so; not before, and not after', () {
    var now = 0;
    var seq = 0;
    var mine = true;
    final said = <Map<String, Object?>>[];
    final heard = StreamController<({PublicKey from, Map<String, Object?> content})>(sync: true);
    final b = WatchBroadcast(
      heard: heard.stream,
      say: said.add,
      view: () => WatchedTable(
        table: 'x',
        target: 50,
        seq: seq,
        hand: 0,
        phase: Phase.playing,
        names: names,
        totals: const [0, 0, 0, 0],
        taken: const [0, 0, 0, 0],
        plays: const [],
      ),
      answering: () => mine,
      now: () => now,
    );
    void watching() => heard.add((from: 'w' * 64, content: {'watching': true}));

    seq = 1;
    b.changed();
    expect(said, isEmpty, reason: 'nobody watching: nothing said');
    watching();
    expect(said.length, 1, reason: 'the table, as soon as someone says they are watching');
    expect((said.last['view'] as Map)['seq'], 1);
    b.changed();
    expect(said.length, 1, reason: 'nothing moved: nothing new to say');
    seq = 2;
    now += 1000;
    b.changed();
    expect(said.length, 2, reason: 'a move: the table again');
    now += 500;
    watching();
    expect(said.length, 2, reason: 'a second watcher in the same moment gets the next view, not another now');

    // Somebody else's to answer: this device says nothing.
    mine = false;
    seq = 3;
    b.changed();
    expect(said.length, 2);
    mine = true;

    // A minute and more since anyone said they were watching: quiet.
    now += WatchBroadcast.watchedFor.inMilliseconds + 1;
    seq = 4;
    b.changed();
    expect(said.length, 2, reason: 'nobody has said they are watching for a minute');
    b.close();
  });

  test('of the people seated and here, the lowest key answers, and only it', () {
    final t = SimTable(humans: 3, seed: 2);
    t.start();
    final c = t.people.first.client;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue);
    final keys = [for (final p in t.people) p.client.signer.publicKey]..sort();
    final answering = [
      for (final p in t.people)
        if (WatchBroadcast.answers(p.client, p.client.signer.publicKey)) p.client.signer.publicKey,
    ];
    expect(answering, [keys.first], reason: 'exactly one, the lowest');
    t.close();
  });
}
