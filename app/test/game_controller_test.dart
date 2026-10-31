/// The solo controller's pacing at the end of a hand, on a fake clock:
/// the last trick is held like any other, swept, and only after a beat
/// of bare felt is the sheet due — so the hand is seen to end rather
/// than cut to the scores.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/pacing.dart';
import 'package:open_hearts/record_store.dart';

void main() {
  test('the last trick is held, swept, and then the sheet is due, a beat later', () {
    fakeAsync((async) {
      final c = GameController(seed: 4, paced: true, store: MemoryRecordStore());
      // Play the hand at the engine's pace, the human answering every
      // ask at once; the bots take their time on the fake clock.
      var reachedOver = false;
      int? overAtMs;
      var elapsed = 0;
      var lastTrickHeldFor = 0;
      for (var i = 0; i < 4000 && !reachedOver; i++) {
        if (c.awaitingPass) {
          for (final card in c.game.handOf(c.mySeat).take(3)) {
            c.toggleSelected(card);
          }
          c.confirmPass();
        } else if (c.awaitingPlay) {
          expect(c.playCard(c.legalNow.first), isNull);
        }
        // The hold on the hand's last trick: pending, with everyone's
        // hand empty, until it is collected.
        if (c.game.pendingTrick != null && c.game.handSizeOf(0) == 0) lastTrickHeldFor += 50;
        async.elapse(const Duration(milliseconds: 50));
        elapsed += 50;
        if (c.game.phase == Phase.handOver) {
          reachedOver = true;
          overAtMs = elapsed;
        }
      }
      expect(reachedOver, isTrue, reason: 'a hand ends on the fake clock');
      expect(lastTrickHeldFor, inInclusiveRange(900, 1000), reason: 'the last trick sits like any other');
      // The trick is gone and the sheet is not yet due.
      expect(c.game.pendingTrick, isNull);
      expect(c.sheetDue, isFalse, reason: 'a beat of felt first');
      async.elapse(Pacing.sweepBeat - const Duration(milliseconds: 60));
      expect(c.sheetDue, isFalse);
      async.elapse(const Duration(milliseconds: 120));
      expect(c.sheetDue, isTrue, reason: 'due after the beat');
      expect(overAtMs, isNotNull);
      // And the next hand clears it.
      c.nextHand();
      expect(c.sheetDue, isFalse);
      expect(c.game.phase, Phase.passing);
      c.dispose();
    });
  });

  test('at the share of its beats a driven build asks for, every beat is there, that much shorter', () {
    // `?e2e=1&pace=0.25` (net/address.dart), as a browser suite asks.
    tableBeats = 0.25;
    addTearDown(() => tableBeats = 1);
    fakeAsync((async) {
      final c = GameController(seed: 4, paced: true, store: MemoryRecordStore());
      var lastTrickHeldFor = 0;
      for (var i = 0; i < 16000 && c.game.phase != Phase.handOver; i++) {
        if (c.awaitingPass) {
          for (final card in c.game.handOf(c.mySeat).take(3)) {
            c.toggleSelected(card);
          }
          c.confirmPass();
        } else if (c.awaitingPlay) {
          expect(c.playCard(c.legalNow.first), isNull);
        }
        if (c.game.pendingTrick != null && c.game.handSizeOf(0) == 0) lastTrickHeldFor += 10;
        async.elapse(const Duration(milliseconds: 10));
      }
      expect(c.game.phase, Phase.handOver, reason: 'a hand ends on the fake clock');
      expect(lastTrickHeldFor, inInclusiveRange(220, 260), reason: 'the trick held a quarter of 950 ms');
      expect(c.sheetDue, isFalse, reason: 'still a beat of felt first');
      async.elapse(Pacing.sweepBeat * 0.25 - const Duration(milliseconds: 20));
      expect(c.sheetDue, isFalse);
      async.elapse(const Duration(milliseconds: 40));
      expect(c.sheetDue, isTrue, reason: 'due after a quarter of the beat');
      c.dispose();
    });
  });

  test('unpaced, the sheet is due the moment the hand is over', () {
    fakeAsync((async) {
      final c = GameController(seed: 4, paced: false, store: MemoryRecordStore());
      for (var i = 0; i < 400 && c.game.phase != Phase.handOver; i++) {
        if (c.awaitingPass) {
          for (final card in c.game.handOf(c.mySeat).take(3)) {
            c.toggleSelected(card);
          }
          c.confirmPass();
        } else if (c.awaitingPlay) {
          c.playCard(c.legalNow.first);
        }
        async.flushMicrotasks();
      }
      expect(c.game.phase, Phase.handOver);
      expect(c.sheetDue, isTrue);
      c.dispose();
    });
  });

  /// [hands] hands at a solo table whose player answers their nth turn
  /// [playerMs] (n) after it opens: how long after the card before it
  /// each bot played each of its cards, from the player's first card on,
  /// with how many of the player's cards came before it, and whether it
  /// led a trick (after the one before it was held and swept) or played
  /// into one. A bot that opens a hand is timed from the hand's opening:
  /// the pass resolved, or, in a hand without one, the hand dealt. On
  /// the fake clock, timed as each card lands.
  List<({int theirs, int ms, bool lead, bool opens})> botTimes(int Function(int card) playerMs, {int hands = 1}) {
    final times = <({int theirs, int ms, bool lead, bool opens})>[];
    fakeAsync((async) {
      final c = GameController(seed: 4, paced: true, store: MemoryRecordStore(), screenClock: () => async.elapsed.inMilliseconds);
      var seen = 0;
      var lastAt = 0;
      int? openedAt;
      var theirs = 0;
      var played = 0;
      var playing = false;
      Timer? answer;
      c.addListener(() {
        final n = c.playedThisHand.length;
        if (n < seen) seen = 0; // the next hand
        if (c.game.phase == Phase.playing && n == 0) openedAt ??= async.elapsed.inMilliseconds;
        if (n > seen) {
          final at = async.elapsed.inMilliseconds;
          if (playing) {
            theirs++;
          } else if (theirs > 0 && n == 1) {
            times.add((theirs: theirs, ms: at - openedAt!, lead: true, opens: true));
          } else if (theirs > 0) {
            times.add((theirs: theirs, ms: at - lastAt, lead: (n - 1) % seatCount == 0, opens: false));
          }
          seen = n;
          lastAt = at;
        }
        if (c.game.phase == Phase.handOver && openedAt != null) {
          // Once a hand: the sheet coming due is told too.
          openedAt = null;
          if (++played < hands) Timer(Duration.zero, c.nextHand);
        } else if (c.awaitingPass && answer == null) {
          answer = Timer(Duration.zero, () {
            answer = null;
            for (final card in c.game.handOf(c.mySeat).take(3)) {
              c.toggleSelected(card);
            }
            c.confirmPass();
          });
        } else if (c.awaitingPlay && c.game.pendingTrick == null && answer == null) {
          answer = Timer(Duration(milliseconds: playerMs(theirs)), () {
            answer = null;
            playing = true;
            expect(c.playCard(c.legalNow.first), isNull);
            playing = false;
          });
        }
      });
      c.notifyListeners();
      for (var i = 0; i < 3000 * hands && played < hands; i++) {
        async.elapse(const Duration(milliseconds: 100));
      }
      expect(played, hands, reason: 'the hands end on the fake clock');
      expect(theirs, 13 * hands, reason: 'the player played their hands');
      c.dispose();
    });
    return times;
  }

  test('a player who plays fast has bots that keep up with them', () {
    // Every persona thinks longer than this player takes.
    final times = [for (final t in botTimes((_) => 300)) if (!t.lead) t.ms];
    expect(times.length, greaterThan(15));
    expect(times, everyElement(300), reason: 'no bot takes longer over a card than the player');
  });

  test('however fast the player, a bot\'s card waits for the one before it to land', () {
    final times = [for (final t in botTimes((_) => 100)) if (!t.lead) t.ms];
    expect(times.length, greaterThan(15));
    expect(times, everyElement(Pacing.cardLands.inMilliseconds));
  });

  test('however fast the player, a bot leads only once the trick before is swept', () {
    final leads = [for (final t in botTimes((_) => 100)) if (t.lead && !t.opens) t.ms];
    expect(leads, isNotEmpty);
    expect(leads, everyElement((Pacing.trickHold + Pacing.trickSweeps).inMilliseconds),
        reason: 'held, swept, and only then led: no card lands on a trick still leaving the felt');
  });

  test('a bot that opens a hand keeps up with a fast player, there being no trick to sweep', () {
    final opens = [for (final t in botTimes((_) => 100, hands: 2)) if (t.opens) t];
    expect(opens, isNotEmpty, reason: 'a bot holds the 2♣ in a hand after the first');
    expect([for (final t in opens) t.ms], everyElement(100), reason: 'at the player\'s pace, as Auto would lead it at once');
  });

  test('a player who takes their time slows no bot down', () {
    final times = [for (final t in botTimes((_) => 3000)) if (!t.lead) t.ms];
    expect(times.length, greaterThan(15));
    expect(times, everyElement(inInclusiveRange(BotPace.quick.minMs, BotPace.slow.maxMs)), reason: 'each bot its own moment');
    expect(times.toSet().length, greaterThan(5), reason: 'drawn, not kept to anybody');
  });

  test('a player who speeds up has the bots keep up within two of their cards, whatever came before', () {
    // Six slow cards, then quick ones: the middle of the last three.
    final times = [for (final t in botTimes((card) => card < 6 ? 3000 : 300)) if (!t.lead) t];
    final slow = [for (final t in times) if (t.theirs <= 7) t.ms];
    final quick = [for (final t in times) if (t.theirs >= 8) t.ms];
    expect(slow, everyElement(greaterThanOrEqualTo(BotPace.quick.minMs)), reason: 'while the player is slow, and after one quick card');
    expect(quick.length, greaterThan(5));
    expect(quick, everyElement(300), reason: 'after two quick cards');
  });
}
