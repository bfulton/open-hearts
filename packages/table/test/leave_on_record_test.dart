/// The leave on the record: its author's own word, carried as a boot is.
///
/// A leave needed nobody's agreement, and took effect wherever it
/// arrived before the seat was removed some other way. Where it crossed
/// a boot — the leave reaching some sides only after the rest had
/// booted the seat for its silence — a side that had booted the seat
/// passed over the leave and one that had the leave passed over the
/// boot, and the people and the jurors kept different exits for as long
/// as they served (chaos seed 43). Now the people back a leave as it
/// reaches them, a majority of them at its turn carries it with the
/// leaver's own signature among them, and each person backs one way
/// out of a seat: a leave and a boot cannot both carry
/// (docs/07-states.md, "The leave on the record").
library;

import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  /// Every side following the table: the people, and the jurors serving.
  List<TableClient> sides(SimTable t) => [
        for (final p in t.people) p.client,
        for (final j in t.jurors)
          if (j.client != null) j.client!,
      ];

  /// How [c]'s record has [seat] go, if it does: the kind of the
  /// removal and where.
  String? exitOf(TableClient c, int seat, PublicKey key) {
    for (final d in c.record) {
      if (!d.removal || d.event.seat != seat) continue;
      final k = d.event.kind;
      if (k == EventKind.leave || k == EventKind.boot || k == EventKind.absent) return '${k.name}@${d.turn}';
    }
    return null;
  }

  test('at a table of two people a leave carries with the other\'s backing, at once', () {
    final t = SimTable(humans: 2, seed: 3, jurors: jurySize, target: 1);
    t.start();
    final a = t.people[0].client, b = t.people[1].client;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 2, limitMs: 10 * 60 * 1000), isTrue);
    t.people[1].depart(Exit.leave);
    // A turn needs both people at a table of two, and the leaver is
    // gone: were the leave settled at the seat's own next turn, the
    // turns before it could not carry, and the table would stop.
    expect(t.clock.runUntil(() => a.seatStateOf(1) == SeatState.left, limitMs: 5000), isTrue, reason: a.describe());
    final d = a.record.firstWhere((d) => d.removal && d.event.kind == EventKind.leave);
    expect(d.witnesses, {a.signer.publicKey, b.signer.publicKey}, reason: 'the leaver and the other person back it');
    expect(d.verdict, isNull, reason: 'the people carried it, not the jury');
    expect(t.clock.runUntil(() => a.done, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    t.clock.advance(20000);
    for (final c in sides(t)) {
      expect(exitOf(c, 1, b.signer.publicKey), 'leave@${d.turn}', reason: '${c.signer.publicKey.substring(0, 4)} has the leave');
    }
    final v = verifyRecord(t.spec, a.record, juries: a.juries);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    // And a leave its author alone backs is not one: the verifier turns
    // it down.
    final alone = [
      for (final x in a.record)
        x == d ? Decision(turn: x.turn, event: x.event, witnesses: {b.signer.publicKey}, among: x.among, removal: true) : x,
    ];
    final w = verifyRecord(t.spec, alone, juries: a.juries);
    expect(w.ok, isFalse);
    expect(w.reason, contains('a leave of seat 1'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  /// A table of three people where the first leaves at its own turn,
  /// with short clocks so that the others' Boot comes up quickly.
  (SimTable, TurnId) leaveAtOwnTurn(int seed) {
    final t = SimTable(
      humans: 3,
      seed: seed,
      jurors: jurySize,
      target: 1,
      timeBank: const TimeBank(graceMs: 2000, passGraceMs: 2000, bankMs: 2000, fixedMs: 4000),
    );
    t.start();
    final a = t.people[0].client;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1 && a.awaitingMyPlay, limitMs: 10 * 60 * 1000),
        isTrue);
    final turn = TurnId.play(a.game.handNumber, a.game.tricksPlayed * seatCount + a.game.trick.length);
    return (t, turn);
  }

  test('a leave that reaches the people only after they have booted the seat is not carried anywhere', () {
    final (t, turn) = leaveAtOwnTurn(5);
    final leaver = t.people[0].client;
    final others = {t.people[1].client.signer.publicKey, t.people[2].client.signer.publicKey};
    // The jurors hear the leave at once; the other two people, two
    // minutes on, by when they have booted the seat for its silence.
    t.net.steer = (from, to, message) => message['kind'] == 'leave' && others.contains(to) ? 120000 : null;
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => t.people[1].client.seatStateOf(0) != SeatState.human, limitMs: 60000), isTrue,
        reason: t.people[1].client.describe());
    expect(t.people[1].client.seatStateOf(0), SeatState.booted);
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    // Past the two minutes: everyone has heard the leave by now.
    t.clock.advance(150000);
    for (final c in [leaver, ...sides(t)]) {
      expect(exitOf(c, 0, leaver.signer.publicKey), 'boot@$turn',
          reason: '${c.signer.publicKey.substring(0, 4)}: one exit on every record, the jurors\' too');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a leave backed by a majority carries at a side that had already booted the seat', () {
    final (t, turn) = leaveAtOwnTurn(5);
    final leaver = t.people[0].client;
    final late = t.people[2].client;
    // One of the two others hears the leave at once and backs it, which
    // with the leaver's own signature is a majority of three. The other
    // hears it — from anyone — only fifteen seconds on, boots the seat
    // meanwhile, and then carries the leave with the backing it was
    // sent ahead of it.
    var booted = false;
    t.net.steer = (from, to, message) {
      if (message['kind'] == 'boot' && from == late.signer.publicKey) booted = true;
      return message['kind'] == 'leave' && to == late.signer.publicKey ? 15000 : null;
    };
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => t.people[1].client.seatStateOf(0) == SeatState.left, limitMs: 5000), isTrue,
        reason: t.people[1].client.describe());
    expect(t.clock.runUntil(() => late.seatStateOf(0) != SeatState.human, limitMs: 60000), isTrue, reason: late.describe());
    expect(booted, isTrue, reason: 'the late one booted the seat before it heard the leave');
    expect(late.seatStateOf(0), SeatState.left, reason: 'the leave, carried by the others, and not the boot it made');
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    t.clock.advance(150000);
    for (final c in [leaver, ...sides(t)]) {
      expect(exitOf(c, 0, leaver.signer.publicKey), 'leave@$turn', reason: c.signer.publicKey.substring(0, 4));
    }
    final v = verifyRecord(t.spec, late.record, juries: late.juries);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  // One voice on a seat's way out, both ways round. Two majorities of
  // one table meet in somebody, and that somebody backing both is how a
  // leave and a boot would both carry: each side then goes by whichever
  // it heard carry first, the people one way and the jurors the other.

  test('a person who has booted the seat does not back its leave while the boot can still carry', () {
    final (t, turn) = leaveAtOwnTurn(5);
    final leaver = t.people[0].client;
    final b = t.people[1].client, c = t.people[2].client;
    bool atTurn(Map<String, Object?> m) {
      final body = m['body'];
      return body is Map && body['hand'] == turn.hand && body['turn'] == turn.index;
    }

    // Both boot the seat; c's vote reaches b half a minute late, by
    // every path, so the boot has not carried at b when the leave
    // reaches it, eight seconds in. The jurors have it all at once.
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      if (kind == 'leave' && to == b.signer.publicKey) return 8000;
      if (kind == 'leave' && to == c.signer.publicKey) return 40000;
      // By whoever carries it: the others forward c's vote too.
      if (message['author'] == c.signer.publicKey && to == b.signer.publicKey && (kind == 'boot' || kind == 'witness') && atTurn(message)) {
        return 30000;
      }
      return null;
    };
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => b.seatStateOf(0) != SeatState.human && c.seatStateOf(0) != SeatState.human, limitMs: 90000), isTrue,
        reason: b.describe());
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    t.clock.advance(150000);
    for (final x in [leaver, ...sides(t)]) {
      expect(exitOf(x, 0, leaver.signer.publicKey), 'boot@$turn', reason: x.signer.publicKey.substring(0, 4));
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a person who has backed a leave does not back a boot of the seat while the leave can still carry', () {
    final t = SimTable(
      humans: 4,
      seed: 5,
      jurors: jurySize,
      target: 1,
      timeBank: const TimeBank(graceMs: 2000, passGraceMs: 2000, bankMs: 2000, fixedMs: 4000),
    );
    t.start();
    final leaver = t.people[0].client;
    expect(
        t.clock.runUntil(() => leaver.game.phase == Phase.playing && leaver.game.tricksPlayed >= 1 && leaver.awaitingMyPlay,
            limitMs: 10 * 60 * 1000),
        isTrue);
    final turn = TurnId.play(leaver.game.handNumber, leaver.game.tricksPlayed * 4 + leaver.game.trick.length);
    final b = t.people[1].client, c = t.people[2].client, d = t.people[3].client;
    final bc = {b.signer.publicKey, c.signer.publicKey};
    // b and c back the leave at once, but neither hears the other's
    // backing for half a minute, by any path, so the leave has not
    // carried at either when d's boot comes to them; d hears of the
    // leave twelve seconds on, having booted the seat. With b's and c's
    // backing a boot carries, three of four, while the jurors — who have
    // all of it at once — hold the leave carried.
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'];
      final author = message['author'];
      final said = kind == 'leave' || (kind == 'witness' && body is Map && body['leave'] == true);
      if (said && to == d.signer.publicKey) return 12000;
      if (kind == 'witness' && body is Map && body['leave'] == true && bc.contains(author) && bc.contains(to) && author != to) return 30000;
      return null;
    };
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.seatStateOf(0) != SeatState.human), limitMs: 120000), isTrue,
        reason: b.describe());
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    t.clock.advance(150000);
    for (final x in [leaver, ...sides(t)]) {
      expect(exitOf(x, 0, leaver.signer.publicKey), 'leave@$turn', reason: x.signer.publicKey.substring(0, 4));
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a leave and its backing reach a juror that missed them from whoever has them', () {
    final (t, turn) = leaveAtOwnTurn(5);
    final leaver = t.people[0].client;
    final juror = t.jurors.firstWhere((j) => j.client != null).client!;
    // Neither the leave nor anybody's backing of it reaches one of the
    // jurors from the one who said it. A juror has no voice of its own
    // to make the majority with: it carries the leave on the backing
    // it is handed, by whoever has it, the leaver being gone.
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'];
      final said = kind == 'leave' || (kind == 'witness' && body is Map && body['leave'] == true);
      return said && to == juror.signer.publicKey && from == message['author'] ? -1 : null;
    };
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => juror.seatStateOf(0) != SeatState.human, limitMs: 60000), isTrue, reason: juror.describe());
    expect(juror.seatStateOf(0), SeatState.left);
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    for (final x in [leaver, ...sides(t)]) {
      expect(exitOf(x, 0, leaver.signer.publicKey), 'leave@$turn', reason: x.signer.publicKey.substring(0, 4));
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a leave and a boot two against two at a table of four go to the jury, and one of them carries', () {
    final t = SimTable(
      humans: 4,
      seed: 5,
      jurors: jurySize,
      target: 1,
      timeBank: const TimeBank(graceMs: 2000, passGraceMs: 2000, bankMs: 2000, fixedMs: 4000),
    );
    t.start();
    final leaver = t.people[0].client;
    expect(
        t.clock.runUntil(() => leaver.game.phase == Phase.playing && leaver.game.tricksPlayed >= 1 && leaver.awaitingMyPlay,
            limitMs: 10 * 60 * 1000),
        isTrue);
    final turn = TurnId.play(leaver.game.handNumber, leaver.game.tricksPlayed * 4 + leaver.game.trick.length);
    final c = t.people[2].client, d = t.people[3].client;
    // b backs the leave at once; c and d hear of it only a minute on,
    // and boot the seat. The leave has two of four behind it and the
    // boot two, and nobody left to back either: the one that backed the
    // leave will not back the boot, and a turn neither side can carry
    // is the jury's. It waited on b for good.
    t.net.steer = (from, to, message) =>
        message['kind'] == 'leave' && (to == c.signer.publicKey || to == d.signer.publicKey) ? 60000 : null;
    t.people[0].depart(Exit.leave);
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.seatStateOf(0) != SeatState.human), limitMs: 50000), isTrue,
        reason: c.describe());
    expect(t.clock.runUntil(() => t.people.skip(1).every((p) => p.client.done), limitMs: 20 * 60 * 1000), isTrue);
    t.clock.advance(150000);
    final exits = {for (final x in [leaver, ...sides(t)]) x.signer.publicKey.substring(0, 4): exitOf(x, 0, leaver.signer.publicKey)};
    expect(exits.values.toSet(), hasLength(1), reason: 'one exit on every record: $exits');
    expect(exits.values.first, 'boot@$turn', reason: 'the jury ruled the boot, the seat having left');
    final ruled = c.record.firstWhere((x) => x.removal && x.event.seat == 0);
    expect(ruled.verdict, isNotNull, reason: 'by the jury, the people split');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
