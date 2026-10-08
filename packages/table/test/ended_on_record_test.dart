/// The game's end for a lost quorum, on the record.
///
/// A table stopped where nobody left can move it — a held seat whose
/// jury has gone, a departed seat nobody left can open — ends the game
/// after twenty seconds. The twenty seconds only propose it: a person
/// stopped there claims the end at that turn, the others stopped there
/// back it, and a majority of the people carries it as a boot is
/// carried: one voice each at the turn, which goes to the move, to a
/// removal or to the end. Every record then ends at that turn, and the
/// verifier reads it as a game ended rather than one unfinished
/// (docs/07-states.md).
///
/// Where no majority can be had — a turn split between a move and a
/// boot with the jury gone, every voice spent; the last person, who
/// hears too little of the table — each side still ends for itself,
/// and its record stops at the turn (quorum_lost_test.dart).
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  /// Two people with a jury of their own and strangers to spare, the
  /// whole jury gone once the hand is being played: the table stops at
  /// a held seat, and ends.
  SimTable juryGone() {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue, reason: 'the hand was dealt');
    for (final j in c.juries.last.event.jurors) {
      t.net.goOffline(j);
    }
    expect(t.clock.runUntil(() => t.clients.every((c) => c.failure != null), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${c.describe()}');
    return t;
  }

  test('the game\'s end is on every record, at the same turn, and read as a game ended', () {
    final t = juryGone();
    final a = t.clients.first, b = t.clients.last;
    for (final c in t.clients) {
      final last = c.record.last;
      expect(last.event.kind, EventKind.ended, reason: 'the record ends with the game\'s end');
      expect(last.removal, isTrue);
      expect(last.turn, c.failedAt?.turn);
      expect(c.turnStateOf(last.turn), TurnState.ended);
      // Not allowPartial: a game ended is not a record cut short.
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.ended, isTrue);
      expect(v.complete, isFalse, reason: 'unfinished, and nobody is rated on it');
      expect(v.ratings, isEmpty);
    }
    expect(a.record.map((d) => d.key).toList(), b.record.map((d) => d.key).toList(), reason: 'one record');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('the verifier holds the game\'s end to the record', () {
    late SimTable t;
    late List<Decision> record;
    late TableClient c;
    setUpAll(() {
      t = juryGone();
      c = t.clients.first;
      record = c.record;
    });
    tearDownAll(() => t.stop());

    Verification check(List<Decision> r) => verifyRecord(t.spec, r, juries: c.juries, crypto: crypto, releases: c.releases);

    test('an end without a majority of the people behind it is turned down', () {
      final d = record.last;
      final alone = Decision(turn: d.turn, event: d.event, witnesses: {d.event.author}, removal: true, among: d.among);
      final v = check([...record.take(record.length - 1), alone]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('without a majority'));
    });

    test('a record that goes on past the game\'s end is turned down', () {
      final d = record.last;
      final v = check([...record.take(record.length - 1), d, record[record.length - 2]]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('past the game\'s end'));
    });

    test('an end claimed by somebody not at the table is turned down', () {
      final d = record.last;
      final juror = t.jurors.first.signer;
      final forged = TableEvent.sign(juror, table: t.spec.id, kind: EventKind.ended, body: Map.of(d.event.body));
      final v = check([...record.take(record.length - 1), Decision(turn: d.turn, event: forged, witnesses: d.witnesses, removal: true, among: d.among)]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('not at the table'));
    });

    test('an end claimed at another turn than it was recorded at is turned down', () {
      final d = record.last;
      final elsewhere = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.ended, body: {...d.event.body, 'turn': d.turn.index + 1});
      final v = check([...record.take(record.length - 1), Decision(turn: d.turn, event: elsewhere, witnesses: d.witnesses, removal: true, among: d.among)]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('claim made at'));
    });
  });

  // A voice already given at the turn is not one more for the end, and
  // it is not a reason to end alone either: the side waits for the rest
  // to carry the end, and takes it with them.
  //
  // Three people and a held seat. Its juror's card reaches c and nobody
  // else, c backs it, and the jury goes: a and b give the seat to the
  // escrow, which nobody left can play, and the turn stops. c's voice
  // there went to the juror's card. a and b end the game, and c's record
  // ends with theirs.
  test('a side whose voice went to the move waits for the end the rest carry, and takes it', () {
    final t = SimTable(humans: 3, seed: 9, crypto: crypto, jurors: jurySize, target: 1);
    final a = t.clients.first, b = t.clients.elementAt(1), c = t.clients.last;
    final jurors = {for (final j in t.jurors) j.signer.publicKey};
    final deaf = {a.signer.publicKey, b.signer.publicKey};
    TurnId? turn;
    t.net.steer = (from, to, message) {
      if (message['kind'] != 'play' || !deaf.contains(to)) return null;
      final body = message['body'] as Map<String, Object?>;
      // The first held seat's cards, whoever says them.
      final author = message['author'] as String;
      if (!jurors.contains(author)) return null;
      turn ??= TurnId(body['hand'] as int, body['turn'] as int);
      if (TurnId(body['hand'] as int, body['turn'] as int) != turn) return null;
      return -1;
    };
    t.start();
    expect(t.clock.runUntil(() => turn != null && c.actionAt(turn!) != null, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'a held seat played, and c has its card');
    for (final j in jurors) {
      t.net.goOffline(j);
    }
    expect(t.clock.runUntil(() => t.clients.every((x) => x.failure != null), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${t.clients.map((x) => x.describe()).join('\n')}');
    expect(a.escrowedAt(turn!.hand).values, contains(turn), reason: 'the seat went to the escrow at the turn');
    for (final x in t.clients) {
      expect(x.record.last.event.kind, EventKind.ended, reason: '${x.signer.publicKey.substring(0, 4)}: ${x.describe()}');
      expect(x.record.last.turn, turn);
    }
    expect(c.record.last.witnesses, isNot(contains(c.signer.publicKey)), reason: 'c\'s voice was the card\'s');
    expect(c.record.map((d) => d.key).toList(), a.record.map((d) => d.key).toList());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A departed seat's move is worked out by every side once its hand
  // opens, with nothing said. A side that has said the game ends at that
  // turn and then sees the hand open holds there: gone on, its voice
  // would be on the end and on the table going on at once. Four people,
  // the jury gone, the last one leaves, and the table stops at the
  // leaver's seat. One juror comes back for b alone, and b plays the
  // seat on. a says the game ends, and c backs it, but c's word is held
  // up on the way. Then the juror reaches a too, and a's copy of the
  // hand opens: a holds. Gone on, a and b would have carried the next
  // card between them while c's record ended at the leaver's seat.
  test('a side that said the game ends at a departed seat holds there when the seat opens, and ends with the rest', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final a = t.clients.first, b = t.clients.elementAt(1), c = t.clients.elementAt(2), d = t.clients.last;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1, limitMs: 5 * 60 * 1000), isTrue);
    final jurors = [for (final j in t.jurors) j.signer.publicKey];
    for (final j in jurors) {
      t.net.goOffline(j);
    }
    t.clock.advance(35 * 1000);
    d.leave();
    expect(t.clock.runUntil(() => [a, b, c].every((x) => x.pause == Pause.openingHand), limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the table stopped at the leaver\'s seat:\n${a.describe()}');
    final turn = a.stalled.keys.first;
    final seat = a.stalled[turn]!;
    var claimed = false;
    a.log = (l) {
      if (l.contains('claiming the game\'s end') || l.contains('backing the claim')) claimed = true;
    };
    // c's word on the game's end, and its backing for anyone's, lost on
    // the way until the lift. And nothing that opens the leaver's hand
    // reaches a until it is let through, or c at all — b carries them
    // forward with the pieces once it is ahead — nor does a jury carry
    // anywhere: a juror drawn is taken as about from the draw, and the
    // seat for one that could be opened.
    final claims = <String>{};
    var lift = false, openA = false;
    final ac = {a.signer.publicKey, c.signer.publicKey};
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'];
      if (kind == 'ended') claims.add('${message['id']}');
      if (kind == 'jury' || (kind == 'witness' && body is Map && body['jury'] == true)) return lift ? null : -1;
      if (kind == 'release' && ((to == a.signer.publicKey && !openA) || (to == c.signer.publicKey && !lift))) return -1;
      if (lift || from != c.signer.publicKey) return null;
      if (kind == 'ended' || (kind == 'witness' && body is Map && claims.contains(body['event']))) return -1;
      return null;
    };
    expect(ac, hasLength(2));
    final j = jurors.first;
    t.net.comeOnline(j);
    for (final x in [a, c, d]) {
      t.net.cut(j, x.signer.publicKey);
    }
    expect(t.clock.runUntil(() => b.turnStateOf(turn) == TurnState.settledSilently, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'b opened the leaver\'s hand and played the seat:\n${b.describe()}');
    expect(t.clock.runUntil(() => claimed, limitMs: 2 * 60 * 1000), isTrue, reason: 'a said the game ends:\n${a.describe()}');
    final seen = <TurnState?>{};
    a.changes.listen((_) => seen.add(a.turnStateOf(turn)));
    openA = true;
    t.net.uncut(j, a.signer.publicKey);
    expect(t.clock.runUntil(() => a.dealOf(turn.hand)?.knowsSecret(seat) ?? false, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'the leaver\'s hand opened at a too:\n${a.describe()}');
    t.clock.advance(10 * 1000);
    expect(seen, isNot(contains(TurnState.settledSilently)), reason: 'a held at the turn it said the game ends at');
    lift = true;
    expect(t.clock.runUntil(() => [a, b, c].every((x) => x.failure != null), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the game ended:\n${[a, b, c].map((x) => x.describe()).join('\n')}');
    for (final x in [a, b, c]) {
      expect(x.record.last.event.kind, EventKind.ended, reason: x.describe());
      expect(x.record.last.turn, turn);
    }
    expect(b.record.map((e) => e.key).toList(), a.record.map((e) => e.key).toList());
    expect(c.record.map((e) => e.key).toList(), a.record.map((e) => e.key).toList());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And lets go once the end can no longer carry: the rest stand past
  // the turn, so their voices there are not the end's to have. Four
  // people, the jury gone, the last one leaves. One juror comes back,
  // heard by b and c, so they wait on it rather than stop, and not by
  // a, which says the game ends. Then the pieces come, a's first: a
  // holds while b and c are still at the turn, and they play the
  // leaver's seat on and wait on a, whose card is next. a lets go when
  // their heartbeats say they have gone past, and plays on with them.
  // Holding on, it would wait at the leaver's seat until they put it
  // out at its own turn — and a side holding a hand it has open must not
  // take the seat for one nobody can open either, and end the game
  // alone over it.
  test('a side that said the game ends lets go once the rest stand past the turn', () {
    final t = SimTable(humans: 4, seed: 3, crypto: crypto, jurors: jurySize);
    t.start();
    final a = t.clients.first, b = t.clients.elementAt(1), c = t.clients.elementAt(2), d = t.clients.last;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1, limitMs: 5 * 60 * 1000), isTrue);
    final jurors = [for (final j in t.jurors) j.signer.publicKey];
    for (final j in jurors) {
      t.net.goOffline(j);
    }
    t.clock.advance(35 * 1000);
    d.leave();
    expect(t.clock.runUntil(() => a.pause == Pause.openingHand, limitMs: 2 * 60 * 1000), isTrue);
    final turn = a.stalled.keys.first;
    int? claimedAt;
    a.log = (l) {
      if (l.contains('claiming the game\'s end')) claimedAt ??= t.clock.nowMs;
    };
    // One juror back: heard by b and c, so they wait on it rather than
    // stop, and not by a, which never hears it say it serves. No piece
    // reaches anyone until a has said the game ends — a's first, so that
    // it holds while b and c are still at the turn, and theirs three
    // seconds on — and no jury carries: a juror drawn counts as about
    // from the draw.
    final j = jurors.first;
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'];
      if (kind == 'jury' || (kind == 'witness' && body is Map && body['jury'] == true)) return -1;
      if (kind == 'serve' && from == j && to == a.signer.publicKey) return -1;
      if (kind != 'release') return null;
      final since = claimedAt;
      if (since == null) return -1;
      return to == a.signer.publicKey || t.clock.nowMs >= since + 3000 ? null : -1;
    };
    t.net.comeOnline(j);
    t.net.cut(j, d.signer.publicKey);
    expect(t.clock.runUntil(() => claimedAt != null, limitMs: 2 * 60 * 1000), isTrue, reason: 'a said the game ends:\n${a.describe()}');
    expect(b.failure, isNull);
    expect(t.clock.runUntil(() => b.turnStateOf(turn) == TurnState.settledSilently && c.turnStateOf(turn) == TurnState.settledSilently,
            limitMs: 2 * 60 * 1000),
        isTrue,
        reason: 'b and c played the leaver\'s seat on:\n${b.describe()}');
    expect(t.clock.runUntil(() => a.turnStateOf(turn) == TurnState.settledSilently, limitMs: 2 * 60 * 1000), isTrue,
        reason: 'a let go and played it too:\n${a.describe()}');
    t.clock.advance(60 * 1000);
    expect(a.failure, isNull, reason: 'a plays on:\n${a.describe()}');
    expect(b.removedAt(a.mySeat!), isNull, reason: 'nobody put a out');
    expect(a.record.any((e) => e.event.kind == EventKind.ended), isFalse);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A side's word that the game has ended for it — said where its voice
  // at the turn went elsewhere, or where nothing could carry — is not a
  // vote for the end. Counted as one, a side still deciding would end
  // the game on a voice that was spent on something else. x's word
  // reaches y five seconds into the stop; y, stopped there too, backs
  // it at once, and the game still waits for x's own voice at twenty.
  test('a side\'s word that the game ended for it is not a vote for the end', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final x = t.clients.first, y = t.clients.last;
    expect(t.clock.runUntil(() => x.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue);
    for (final j in x.juries.last.event.jurors) {
      t.net.goOffline(j);
    }
    expect(t.clock.runUntil(() => x.waitingOnGoneJury != null && y.waitingOnGoneJury != null, limitMs: 3 * 60 * 1000), isTrue,
        reason: 'stopped at a held seat nobody left can play:\n${x.describe()}');
    t.clock.advance(5000);
    final at = y.waitingOnGoneJury!;
    final word = TableEvent.sign(x.signer,
        table: t.spec.id, kind: EventKind.ended, body: {'hand': at.turn.hand, 'turn': at.turn.index, 'seat': at.seat, 'vote': false});
    x.transport.broadcast(word.toJson());
    // A word is said by a side ending the game for itself, and that side
    // says nothing after it: not a vote, and no vote coming. So y can
    // put nothing on the record — one voice is not a majority of two —
    // and ends the game for itself too.
    expect(t.clock.runUntil(() => y.failure != null, limitMs: 60000), isTrue, reason: y.describe());
    expect(y.record.any((d) => d.event.kind == EventKind.ended), isFalse,
        reason: 'the word carried nothing onto the record:\n${y.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a side that ended the game for itself is not a vote still coming for the end', () {
    // At a table of two with the jury gone, one person, hearing too
    // little of the table, says its word and ends the game for itself.
    // The other must not take that word as a claim and wait for good
    // on a vote from somebody who has already gone.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4);
    t.start();
    final x = t.clients.first, y = t.clients.last;
    expect(t.clock.runUntil(() => x.game.phase == Phase.playing, limitMs: 5 * 60 * 1000), isTrue);
    for (final j in x.juries.last.event.jurors) {
      t.net.goOffline(j);
    }
    // x stops hearing y; y still hears x.
    t.net.steer = (from, to, message) => from == y.signer.publicKey && to == x.signer.publicKey ? -1 : null;
    expect(t.clock.runUntil(() => x.failure != null, limitMs: 5 * 60 * 1000), isTrue, reason: x.describe());
    expect(x.record.any((d) => d.event.kind == EventKind.ended), isFalse, reason: 'x ended for itself, on no record');
    expect(t.clock.runUntil(() => y.failure != null, limitMs: 60000), isTrue,
        reason: 'y is left with no majority to end it by, and ends it for itself too:\n${y.describe()}');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('an end at a held seat\'s audit comes after the audits said beside it, on the record and to the verifier', () {
    // The table stops at a held seat's audit, given to the escrow with
    // nobody left to open it, and ends the game there. The people's own
    // audits, at the same position and said before it, sort ahead of
    // the end, or the verifier would read the record as going on past
    // it.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, target: 1);
    final jurors = {for (final j in t.jurors) j.signer.publicKey};
    // No held seat's audit is ever said.
    t.net.steer = (from, to, message) {
      final body = message['body'];
      return message['kind'] == 'deal' && body is Map && body['round'] == 4 && jurors.contains(from) ? -1 : null;
    };
    t.start();
    final x = t.clients.first, y = t.clients.last;
    expect(t.clock.runUntil(() => x.game.phase == Phase.handOver || x.game.phase == Phase.gameOver, limitMs: 20 * 60 * 1000), isTrue,
        reason: x.describe());
    for (final k in jurors) {
      t.net.goOffline(k);
    }
    expect(t.clock.runUntil(() => x.failure != null && y.failure != null, limitMs: 5 * 60 * 1000), isTrue,
        reason: '${x.describe()}\n${y.describe()}');
    for (final c in [x, y]) {
      final end = c.record.lastWhere((d) => d.event.kind == EventKind.ended, orElse: () => throw 'no end on the record:\n${c.describe()}');
      expect(end.turn.isAudit, isTrue);
      expect(c.record.last, same(end), reason: 'the end is the last thing on the record');
      expect(c.record.where((d) => d.turn.isAudit && !d.removal).length, 2, reason: 'both people audited, at the same position');
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.ended, isTrue);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
