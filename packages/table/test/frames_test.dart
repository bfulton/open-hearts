/// What a view of the table is shown ([TableRules.onFrame]): the table
/// after each change a person could see, one change at a time, each a
/// copy the table goes on without.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// Every frame [c] is shown from here on, in order.
List<Frame> framesOf(TableClient c) {
  final out = <Frame>[];
  c.rules.onFrame = out.add;
  return out;
}

/// Whether [frames] tell the game [rules] played, change by change: each
/// pass and play once and in the table's order, each card on the felt in
/// its own frame, a full trick swept in the very next, a hand left only
/// for the next one, a seat changing hands only where it is said to, and
/// the game at the end as it ended.
void tells(List<Frame> frames, TableRules rules) {
  final moved = [for (final f in frames) if (f.change == FrameChange.passed || f.change == FrameChange.played) f];
  expect(moved.length, rules.moves.length, reason: 'a frame for every pass and play');
  for (var i = 0; i < moved.length; i++) {
    final m = rules.moves[i];
    expect((moved[i].seat, moved[i].change == FrameChange.played, moved[i].game.handNumber), (m.seat, !m.isPass, m.hand), reason: 'move $i');
    if (m.isPass) {
      expect(moved[i].game.hasPassed(m.seat) || moved[i].game.phase == Phase.playing, isTrue, reason: 'move $i: the pass is in');
    } else {
      final trick = moved[i].game.pendingTrick?.plays ?? moved[i].game.trick;
      expect((trick.last.seat, trick.last.card), (m.seat, m.card), reason: 'move $i: the card is on the felt');
      expect(moved[i].played, {
        for (final o in rules.moves.take(i + 1))
          if (o.hand == m.hand && !o.isPass) o.card,
      }, reason: 'move $i: the cards played in the hand by then');
    }
  }
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    if (f.game.pendingTrick != null) {
      expect(i + 1 < frames.length && frames[i + 1].change == FrameChange.collected, isTrue, reason: 'frame $i: a full trick is swept next');
    }
    if (f.change == FrameChange.collected) expect(f.game.pendingTrick, isNull);
    if (i == 0) continue;
    final before = frames[i - 1];
    if (f.game.handNumber != before.game.handNumber) {
      expect(f.game.handNumber, before.game.handNumber + 1, reason: 'frame $i: hands in order');
      expect(f.change, anyOf(FrameChange.nextHand, FrameChange.givenUp), reason: 'frame $i: a hand left for the next');
      if (f.change == FrameChange.nextHand) expect(before.game.phase, Phase.handOver, reason: 'frame $i: after one scored');
    }
    for (var s = 0; s < seatCount; s++) {
      if (f.holders[s] != before.holders[s]) {
        expect((f.change, f.seat), (FrameChange.seat, s), reason: 'frame $i: seat $s changes hands where it says so');
      }
    }
    if (f.change == FrameChange.seat) {
      expect(before.holders[f.seat!], isA<HumanSeat>(), reason: 'frame $i: a person gone');
      expect(f.holders[f.seat!], isA<BotSeat>(), reason: 'frame $i: a bot in their place');
    }
  }
  final seats = [for (final f in frames) if (f.change == FrameChange.seat) f.seat];
  expect(seats.toSet(), rules.removals.keys.toSet(), reason: 'a frame for every person gone');
  expect(frames.last.game.phase, rules.game.phase);
  expect(frames.last.game.handNumber, rules.game.handNumber);
  expect(frames.last.game.totals, rules.game.totals);
  expect(frames.last.holders, rules.holders);
  // Copies: the first is as it was when it was shown.
  expect(frames.first.game.handNumber, 0);
}

/// Each hand of a sealed game is dealt in a frame of its own, before
/// anything is passed or played in it, with only what this side sees.
void dealtOnce(List<Frame> frames, TableClient c) {
  final dealt = <int>{};
  for (final f in frames) {
    final hand = f.game.handNumber;
    if (f.change == FrameChange.dealt) {
      expect(dealt.add(hand), isTrue, reason: 'hand $hand dealt once');
      expect(f.game.knowsHand(c.mySeat!), isTrue, reason: 'hand $hand: its own cards');
    }
    if (f.change == FrameChange.passed || f.change == FrameChange.played) expect(dealt, contains(hand), reason: 'hand $hand dealt first');
  }
}

void main() {
  test('a seeded table: every side is shown the same game, bots and all, change by change', () {
    final t = SimTable(humans: 2, seed: 4);
    final frames = [for (final c in t.clients) framesOf(c)];
    t.start();
    expect(t.run(), isTrue);
    for (final (i, c) in t.clients.indexed) {
      tells(frames[i], c.rules);
    }
    String story(List<Frame> fs) => [for (final f in fs) '${f.change.name} ${f.seat} ${f.game.handNumber}'].join(', ');
    expect(story(frames[1]), story(frames[0]), reason: 'nothing hidden at a seeded table');
    expect(frames[0].where((f) => f.change == FrameChange.nextHand).length, t.clients[0].game.handNumber, reason: 'every hand after the first');
    t.close();
  });

  group('sealed', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    test('one person and three bots the house holds: the person is shown its moves as they land', () {
      final t = SimTable(humans: 1, seed: 5, crypto: crypto);
      final frames = framesOf(t.clients.first);
      t.start();
      expect(t.run(), isTrue);
      final c = t.clients.first;
      tells(frames, c.rules);
      dealtOnce(frames, c);
      for (final f in frames) {
        for (var s = 0; s < seatCount; s++) {
          if (s != c.mySeat) expect(f.game.knowsHand(s), isFalse, reason: 'a bot\'s cards are the house\'s alone');
        }
      }
      t.close();
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a person gone mid-trick, and their hand never opened: the seat changes hands, and the hand is given up', () {
      final t = SimTable(humans: 2, seed: 63, crypto: crypto, conducts: {1: Lie.withhold});
      t.people[0]
        ..going = Going.leave
        ..goAt = Moment.midTrick;
      final frames = framesOf(t.clients[1]);
      t.start();
      expect(t.run(), isTrue);
      final c = t.clients[1];
      tells(frames, c.rules);
      dealtOnce(frames, c);
      final gone = frames.indexWhere((f) => f.change == FrameChange.seat);
      expect(frames[gone].seat, 0);
      expect(frames[gone].holders[0], isA<BotSeat>());
      final givenUp = frames.indexWhere((f) => f.change == FrameChange.givenUp);
      expect(givenUp, greaterThan(gone));
      expect(frames[givenUp].game.handNumber, c.rules.removals[0]!.hand + 1);
      expect(frames[givenUp].game.phase, Phase.dealing, reason: 'the next hand, before its deal');
      t.close();
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the lead card said to be nowhere: the hand is given up, and the liar\'s seat changes hands', () {
      final t = SimTable(humans: 2, seed: 61, crypto: crypto, conducts: {0: Lie.declare});
      final frames = framesOf(t.clients[1]);
      t.start();
      expect(t.clock.runUntil(() => t.clients[1].started && t.clients[1].rules.removals.isNotEmpty, limitMs: 60 * 60000), isTrue);
      t.people[0].depart(Going.crash);
      expect(t.run(), isTrue);
      final c = t.clients[1];
      tells(frames, c.rules);
      final givenUp = frames.indexWhere((f) => f.change == FrameChange.givenUp);
      expect(givenUp, greaterThanOrEqualTo(0));
      expect(frames[givenUp - 1].change, FrameChange.seat, reason: 'the liar is out in the hand they lied in');
      expect(frames.sublist(0, givenUp).where((f) => f.change == FrameChange.played && f.game.handNumber == frames[givenUp - 1].game.handNumber),
          isEmpty,
          reason: 'nothing of that hand was played');
      t.close();
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
