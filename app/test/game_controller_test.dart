/// The solo controller's pacing at the end of a hand, on a fake clock:
/// the last trick is held like any other, swept, and only after a beat
/// of bare felt is the sheet due — so the hand is seen to end rather
/// than cut to the scores.
library;

import 'package:engine/engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/pacing.dart';

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
}
