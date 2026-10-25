/// The bots' moves lost in a dropped connection, and the table that
/// stopped for it (table 64cf65a3, 2026-10-24).
///
/// Alone with three bots the backup jurors held, a person's phone lost
/// its connection 43 ms after the jurors said the bots' passes, and was
/// back 16 seconds later. A juror says its own move again on a widening
/// schedule, the next time half a minute after the first, and the phone
/// gave each bot 15 seconds from the moment it was back. So at 15
/// seconds it took all three seats off their jurors for not passing,
/// and with those three left out of the next draw, the one backup juror
/// left could not hold the bot seats of the next hand: the table sat at
/// "Waiting for jury…" until the person left.
///
/// Two things went wrong, and each is held here on its own: the passes
/// were not said again when the phone was back, and a table with
/// nobody else to draw never drew the jurors it had let go.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  void playedOut(SimTable t, TableClient ada) {
    expect(t.run(limitMs: 3 * 60 * 60 * 1000), isTrue, reason: 'the game played out:\n${ada.describe()}');
    expect(ada.failure, isNull);
    final v = verifyRecord(t.spec, ada.record, juries: ada.juries, crypto: crypto, releases: ada.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }

  // However long the line is down. What decided the table's fate was
  // where each juror's widening repeat fell against the fifteen
  // seconds, and at 16 seconds this simulation's jurors happen to say
  // theirs in time where the real ones did not; at 17 they do not.
  for (final down in [16, 17, 20, 24, 31]) {
    test('the bots\' passes lost in a $down-second drop reach the person once they are back, and the game goes on', () {
      final t = SimTable(humans: 1, seed: 4, crypto: crypto, target: 30, lastResort: true);
      final ada = t.people[0].client;
      final key = ada.signer.publicKey;
      final jurors = {for (final j in t.jurors) j.signer.publicKey};
      final lines = <String>[];
      for (final j in t.jurors) {
        j.log = lines.add;
      }
      int? droppedAt;
      t.net.onSend = (from, message) {
        final body = message['body'];
        if (droppedAt != null || message['kind'] != 'pass' || !jurors.contains(from) || body is! Map || body['hand'] != 0) return;
        // The first bot pass said, and the line goes before it arrives:
        // every copy of every bot pass said while it is down is lost.
        droppedAt = t.clock.nowMs;
        t.net.goOffline(key);
        t.clock.schedule(down * 1000, () => t.net.comeOnline(key));
      };
      t.start();
      expect(t.clock.runUntil(() => droppedAt != null, limitMs: 10 * 60 * 1000), isTrue, reason: 'the bots passed');
      // Back, and the passes settled here inside the bots' 15 seconds.
      expect(t.clock.runUntil(() => ada.game.phase == Phase.playing, limitMs: down * 1000 + TableTiming.standard.botActsMs), isTrue,
          reason: 'the hand passed and was played:\n${ada.describe()}');
      expect(ada.escrowedAt(0), isEmpty, reason: 'no bot seat given up for a pass this side had lost');
      expect([for (final j in t.jurors) j.client?.saidAgainOnHeartbeat ?? 0].fold(0, (a, b) => a + b), greaterThan(0),
          reason: 'said again by their jurors on hearing the person back');
      // By each seat's own juror, and no other: every juror heard every
      // pass, and four saying each of them again is four times the wire.
      for (final l in lines.where((l) => l.contains(' again: '))) {
        final seat = int.parse(RegExp(r'for seat (\d)').firstMatch(l)!.group(1)!);
        expect(l.trimLeft().split(' ')[1], startsWith('${ada.botHolders(0)[seat]!.substring(0, 4)}/'), reason: l);
      }
      expect(ada.letGo, isEmpty, reason: 'no juror left out of the next draw');
      expect(t.clock.runUntil(() => ada.game.handNumber == 1 && ada.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue,
          reason: 'the next hand was dealt:\n${ada.describe()}');
      playedOut(t, ada);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // Said by whoever made the move, for whoever missed it, and no one
  // else: at a table of two, the person who has the bots' passes is
  // heard the whole time, and their heartbeats back what they backed.
  test('with two people, a move is said again by its maker for the person who missed it, and only them', () {
    final t = SimTable(humans: 2, seed: 4, crypto: crypto, target: 30, lastResort: true);
    final (ada, bea) = (t.people[0].client, t.people[1].client);
    final lines = <String>[];
    for (final c in t.clients) {
      c.log = lines.add;
    }
    for (final j in t.jurors) {
      j.log = lines.add;
    }
    final jurors = {for (final j in t.jurors) j.signer.publicKey};
    final key = bea.signer.publicKey;
    int? droppedAt;
    t.net.onSend = (from, message) {
      final body = message['body'];
      if (droppedAt != null || message['kind'] != 'pass' || !jurors.contains(from) || body is! Map || body['hand'] != 0) return;
      droppedAt = t.clock.nowMs;
      t.net.goOffline(key);
      t.clock.schedule(17000, () => t.net.comeOnline(key));
    };
    t.start();
    expect(t.clock.runUntil(() => droppedAt != null, limitMs: 10 * 60 * 1000), isTrue, reason: 'the bots passed');
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.playing), limitMs: 17000 + TableTiming.standard.botActsMs),
        isTrue,
        reason: 'the hand passed and was played:\n${bea.describe()}');
    for (final c in t.clients) {
      expect(c.escrowedAt(0), isEmpty, reason: c.describe());
    }
    final again = [for (final l in lines) if (l.contains(' again: ')) l];
    expect(again, isNotEmpty, reason: 'the moves bea missed were said again');
    final makers = {
      for (final MapEntry(key: seat, value: k) in ada.botHolders(0).entries) seat: k.substring(0, 4),
      0: ada.signer.publicKey.substring(0, 4),
      1: key.substring(0, 4),
    };
    for (final l in again) {
      final seat = int.parse(RegExp(r'for seat (\d)').firstMatch(l)!.group(1)!);
      expect(l.trimLeft().split(' ')[1], startsWith('${makers[seat]}/'), reason: 'by the move\'s maker: $l');
      // Bea's own pass was made while she was away, and lost the same
      // way: ada is the one who missed that one.
      final missed = seat == 1 ? makers[0] : makers[1];
      expect(l, contains('again: $missed is here'), reason: 'for the person who missed it: $l');
    }
    playedOut(t, ada);
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And only then. A heartbeat can leave before the move it does not
  // back has arrived, which at a relay's latency is a good part of every
  // move, and taken for a person missing it, each would be said twice.
  test('on a line that loses nothing, no move is said again for a heartbeat', () {
    for (var seed = 7; seed < 11; seed++) {
      final t = SimTable(humans: 2, seed: seed, crypto: crypto, jurors: jurySize, target: 1)
        ..net.minLatencyMs = 200
        ..net.maxLatencyMs = 400;
      t.start();
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue,
          reason: 'seed $seed played out:\n${t.clients.first.describe()}');
      final clients = [...t.clients, for (final j in t.jurors) ?j.client];
      for (final c in clients) {
        expect(c.saidAgainOnHeartbeat, 0, reason: 'seed $seed: ${c.signer.publicKey.substring(0, 4)}');
      }
      t.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  /// Alone with the backup jurors, a bot seat's juror heard and idle
  /// at its play until the seat is taken off it, and let go; then [up]
  /// to the juror, from the moment it is.
  (SimTable, TableClient, PublicKey) letOneGo({required void Function(SimTable t, PublicKey juror) up}) {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, target: 30, lastResort: true);
    final ada = t.people[0].client;
    t.start();
    expect(t.clock.runUntil(() => ada.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    final juror = ada.botHolders(0).values.first;
    t.net.doze(juror);
    expect(t.clock.runUntil(() => ada.letGo.contains(juror), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the idle juror let go:\n${ada.describe()}');
    expect(ada.game.handNumber, 0);
    up(t, juror);
    return (t, ada, juror);
  }

  // The other half of it. A juror let go is left out of later draws,
  // and the backup jurors are as many as a jury that holds three bot
  // seats needs, so the table could never deal again.
  test('a juror let go is drawn again when there is nobody else, and the game goes on', () {
    final (t, ada, juror) = letOneGo(up: (t, juror) => t.net.wake(juror));
    expect(t.clock.runUntil(() => ada.game.handNumber == 1 && ada.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the next hand was dealt:\n${ada.describe()}');
    expect(ada.jurorsOf(1), contains(juror), reason: 'by a jury with the juror let go on it');
    expect(ada.letGo, isEmpty);
    playedOut(t, ada);
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And once. Idle again, it is out for good, and the table says it is
  // waiting for a jury rather than giving up hand after hand to it.
  test('a juror let go twice is not drawn a third time: the table waits for a jury', () {
    final (t, ada, juror) = letOneGo(up: (t, juror) {});
    expect(t.clock.runUntil(() => ada.game.handNumber == 1 && ada.jurorsOf(1).contains(juror), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'drawn again for the next hand:\n${ada.describe()}');
    expect(ada.botHolders(1).values, contains(juror), reason: 'holding a seat there, which is what the case is about');
    expect(t.clock.runUntil(() => ada.game.handNumber == 2, limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the hand given up to it:\n${ada.describe()}');
    expect(ada.letGo, contains(juror), reason: 'and let go again');
    t.clock.advance(10 * 60 * 1000);
    expect(ada.game.handNumber, 2, reason: 'no hand after it given up to the same juror:\n${ada.describe()}');
    expect(ada.shortOfJurors, isTrue, reason: 'the table says it waits for a jury');
    expect(ada.juries.where((d) => d.event.hand == 2), isEmpty, reason: 'no jury drawn for it');
    expect(ada.failure, isNull);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
