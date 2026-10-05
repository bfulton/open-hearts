/// The jury (docs/04-live-play.md), on the simulator: the rows of the
/// departure matrix that need strangers online — a table of two with
/// one gone quiet, a partition the jury can see across, a juror gone,
/// the foreman gone, the whole jury gone, and nobody to draw from.
library;

import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

import 'matrix_test.dart' show checkAgreement;

/// Everything a table with a jury has to satisfy at the end.
void checkFinishedByJury(SimTable t, {required Set<int> departedSeats, bool expectVerdict = true}) {
  final survivors = t.survivors.toList();
  expect(survivors, isNotEmpty);
  for (final c in survivors) {
    expect(c.done, isTrue, reason: 'the game reaches its end\n${c.describe()}');
    expect(c.pause, isNull);
    for (final s in departedSeats) {
      expect(c.holders[s], isA<BotSeat>(), reason: 'seat $s is a bot');
    }
    final v = verifyRecord(t.spec, c.record, juries: c.juries);
    expect(v.ok, isTrue, reason: v.reason);
    expect(v.complete, isTrue);
    if (expectVerdict) {
      expect(c.record.any((d) => d.verdict != null), isTrue, reason: 'a verdict settled something');
    }
  }
  checkAgreement(t, among: survivors);
  // A juror's record is a record too, and verifies like anyone's.
  for (final j in t.jurors) {
    final c = j.client;
    if (c == null || j.gone) continue;
    final v = verifyRecord(t.spec, c.record, juries: c.juries, allowPartial: true);
    expect(v.ok, isTrue, reason: 'juror record: ${v.reason}');
  }
}

void main() {
  test('the draw is a function of the seed, the hand and the snapshot', () {
    // More online than the jury takes, so the draw is a selection and
    // not just an ordering of everybody there is.
    final pool = ['k3', 'k1', 'k5', 'k2', 'k4', 'k6', 'k7', 'k8'];
    final a = drawJury(7, 2, pool);
    expect(a.length, jurySize);
    expect(drawJury(7, 2, pool.reversed), a, reason: 'the snapshot is a set');
    expect(drawJury(7, 3, pool), isNot(a), reason: 'every hand draws afresh');
    expect(drawJury(8, 2, pool), isNot(a));
    expect(drawJury(7, 2, ['k1', 'k2']).toSet(), {'k1', 'k2'}, reason: 'fewer online than the draw asks for is the jury there is');
  });

  group('a table of two', () {
    test('one goes quiet off turn: the jury rules for the action, and the table finishes', () {
      final t = SimTable(humans: 2, seed: 61, jurors: 4);
      t.people[1]
        ..exit = Exit.idle
        ..exitAt = Moment.offTurn;
      t.start();
      expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.describe()}');
      expect(t.people[1].gone, isTrue);
      checkFinishedByJury(t, departedSeats: {1});
      final c = t.people[0].client;
      final byVerdict = c.record.where((d) => d.verdict != null).toList();
      expect(byVerdict.any((d) => !d.removal), isTrue, reason: 'the survivor\'s own play was carried by a verdict');
      expect(byVerdict.any((d) => d.removal && d.event.seat == 1), isTrue, reason: 'and the quiet seat removed at its own turn by one');
      expect(c.juries, isNotEmpty);
      expect(t.jurors.map((j) => j.verdicts).reduce((a, b) => a + b), greaterThan(0));
      t.stop();
    });

    test('one goes quiet on its own turn: the jury rules for the removal', () {
      final t = SimTable(humans: 2, seed: 62, jurors: 4);
      t.people[1]
        ..exit = Exit.idle
        ..exitAt = Moment.onOwnTurn;
      t.start();
      expect(t.run(), isTrue, reason: 'finished\n${t.people[0].client.describe()}');
      checkFinishedByJury(t, departedSeats: {1});
      final c = t.people[0].client;
      expect(c.record.any((d) => d.verdict != null && d.removal && d.event.seat == 1), isTrue);
      expect(c.seatStateOf(1), SeatState.absent);
      t.stop();
    });

    test('one crashes: the transport\'s word is not the jury\'s, but the jury agrees soon enough', () {
      final t = SimTable(humans: 2, seed: 63, jurors: 4);
      t.people[0]
        ..exit = Exit.crash
        ..exitAt = Moment.midTrick;
      t.start();
      expect(t.run(), isTrue);
      checkFinishedByJury(t, departedSeats: {0});
      t.stop();
    });
  });

  group('partitions the jury can see across', () {
    test('four humans cut two and two, every juror reaching all four: carried through, nobody removed', () {
      final t = SimTable(humans: 4, seed: 64, jurors: 4);
      final keys = t.signers.map((s) => s.publicKey).toList();
      t.start();
      t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 3600000);
      for (final a in [keys[0], keys[1]]) {
        for (final b in [keys[2], keys[3]]) {
          t.net.cut(a, b);
        }
      }
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 6 * 3600000), isTrue,
          reason: 'the table finishes through the jury\n${t.clients.map((c) => c.describe()).join()}');
      for (final c in t.clients) {
        expect(c.participants.length, 4, reason: 'nobody was removed');
      }
      checkFinishedByJury(t, departedSeats: {}, expectVerdict: false);
      t.stop();
    });
  });

  group('jurors go', () {
    test('the foreman crashes: the next juror rules', () {
      final t = SimTable(humans: 2, seed: 65, jurors: 4);
      t.people[1]
        ..exit = Exit.idle
        ..exitAt = Moment.offTurn;
      t.start();
      // Once the first jury has carried, its foreman dies.
      t.clock.runUntil(() => t.people[0].client.juries.isNotEmpty, limitMs: 600000);
      final foreman = t.people[0].client.juries.first.event.jurors.first;
      t.jurors.firstWhere((j) => j.signer.publicKey == foreman).depart(Exit.crash);
      expect(t.run(), isTrue, reason: t.people[0].client.describe());
      checkFinishedByJury(t, departedSeats: {1});
      final verdicts = t.people[0].client.record.where((d) => d.verdict != null).map((d) => d.verdict!.author).toSet();
      expect(verdicts, isNotEmpty);
      expect(verdicts.contains(foreman), isFalse, reason: 'the dead foreman ruled nothing');
      t.stop();
    });

    test('the whole jury goes quiet: another is drawn from whoever is left', () {
      // Two more online than a jury takes, so there is somebody left
      // to draw the second one from.
      final t = SimTable(humans: 3, seed: 66, jurors: 8);
      t.people[2]
        ..exit = Exit.idle
        ..exitAt = Moment('off turn, hand 2', Moment.offTurn.holds, fromHand: 2);
      t.start();
      t.clock.runUntil(() => t.people[0].client.juries.isNotEmpty, limitMs: 600000);
      final first = t.people[0].client.juries.first.event.jurors.toSet();
      expect(first.length, jurySize);
      for (final j in t.jurors) {
        if (first.contains(j.signer.publicKey)) j.depart(Exit.idle);
      }
      expect(t.run(), isTrue, reason: t.people[0].client.describe());
      // Three humans, one quiet: the two carry on by majority; a verdict
      // is not needed, but a jury was redrawn from the two left.
      final c = t.people[0].client;
      final later = c.juries.where((d) => !first.containsAll(d.event.jurors)).toList();
      expect(later, isNotEmpty, reason: 'a jury was drawn from the jurors still up\n${c.describe()}');
      for (final d in later) {
        expect(d.event.jurors.toSet().intersection(first), isEmpty, reason: 'the quiet jurors were not drawn again');
      }
      checkFinishedByJury(t, departedSeats: {2}, expectVerdict: false);
      t.stop();
    });

    test('nobody online to draw from: the table says so, and a juror of last resort answers', () {
      final t = SimTable(humans: 2, seed: 67, lastResort: true);
      t.people[1]
        ..exit = Exit.idle
        ..exitAt = Moment.offTurn;
      t.start();
      expect(t.run(), isTrue, reason: t.people[0].client.describe());
      expect(t.presence!.calls, greaterThan(0), reason: 'the table called for a juror');
      checkFinishedByJury(t, departedSeats: {1});
      // Any of the bench: the call brings them all up and the draw
      // orders them, so which one is foreman is the draw's to say.
      final bench = {for (final j in t.presence!.lastResorts) j.signer.publicKey};
      expect(t.people[0].client.record.where((d) => bench.contains(d.verdict?.author)), isNotEmpty);
      t.stop();
    });

    // Nobody comes. The table cannot go on without a juror, and none
    // can be found: once the other person has been silent as long as a
    // person is given, the game ends rather than wait for good
    // (docs/04-live-play.md).
    test('nobody online and no last resort: the table pauses and says why, then the game ends', () {
      final t = SimTable(humans: 2, seed: 68, withPresence: true);
      t.people[1]
        ..exit = Exit.idle
        ..exitAt = Moment.offTurn;
      t.start();
      final c = t.people[0].client;
      expect(t.clock.runUntil(() => c.pause == Pause.waitingForJury, limitMs: 20 * 60 * 1000), isTrue, reason: c.describe());
      expect(c.needsJuror, isTrue);
      expect(t.presence!.calls, greaterThan(0));
      expect(c.juries, isEmpty);
      expect(t.clock.runUntil(() => c.failure != null, limitMs: 10 * 60 * 1000), isTrue, reason: c.describe());
      expect(c.failure, Failure.jurorQuorumLost);
      expect(c.done, isFalse, reason: 'unfinished, so unscored');
      t.stop();
    });
  });

  test('a bot seat to a juror each, the foreman left free', () {
    final jury = ['j0', 'j1', 'j2', 'j3'];
    expect(assignBots(jury, [1, 3]), {1: 'j1', 3: 'j2'}, reason: 'in seat order, past the foreman');
    expect(assignBots(jury, [3, 1]), {1: 'j1', 3: 'j2'}, reason: 'the seats are a set, not an order');
    expect(assignBots(jury, const []), isEmpty);

    // One seat each: a juror holding two of them at a table of one
    // person holds twenty-six cards and subtracts the rest.
    final three = assignBots(jury, [1, 2, 3]);
    expect(three.values.toSet().length, 3, reason: 'no juror holds two');
    expect(three.containsValue('j0'), isFalse, reason: 'and not the foreman');

    // Every seat held, at more seats than a table can really have:
    // the holders run out only past three bots, and a fourth bot seat
    // would be a table with nobody at it.
    expect(assignBots([...jury, 'j4'], [1, 2, 3, 0]), {0: 'j1', 1: 'j2', 2: 'j3', 3: 'j4'});

    // And under four, nothing is held at all: a bot seat's escrow is
    // the jury's own in two sides with the holder in one of them, so a
    // jury this small cannot open the seat again once its holder goes.
    expect(assignBots(['j0', 'j1'], [1, 2, 3]), isEmpty);
    expect(assignBots(['j0', 'j1', 'j2'], [1]), isEmpty, reason: 'three is still too few');
    expect(assignBots(['j0'], [1]), isEmpty, reason: 'a jury of one is a foreman and nobody else');
  });
}
