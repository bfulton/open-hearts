/// The draw a hand's deal is sealed to, on the record.
///
/// A draw proposed from an earlier place can arrive after one proposed
/// from a later place, so sides reading the draw for themselves could
/// settle steps on different draws. So every seat's keys name the draw
/// they were sealed to, and the draw named by the first person whose
/// keys settle is the hand's. A held seat's keys are taken only after
/// that, naming the same draw, from the juror it names for the seat;
/// its juror waits for it (_checkSealed in client.dart, sealedAt in
/// record.dart).
library;

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a juror makes no keys until the record has said which draw the hand is sealed to', () {
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: jurySize);
    final a = t.clients.first;
    // The first person's keys, which name the hand's draw, held back
    // three seconds on their way to every juror.
    final people = {for (final s in t.signers) s.publicKey};
    t.net.steer = (from, to, message) {
      if (from != a.signer.publicKey || people.contains(to) || message['kind'] != 'deal') return null;
      final body = message['body'] as Map<String, Object?>;
      return body['hand'] == 0 && body['round'] == 0 ? 3000 : null;
    };
    final said = <String, int>{};
    final keyed = <String, int>{};
    for (final j in t.jurors) {
      final k = j.signer.publicKey.substring(0, 4);
      j.log = (l) {
        final at = int.tryParse(l.substring(0, 7).trim());
        if (at == null) return;
        if (l.contains('hand 0: sealed to')) said.putIfAbsent(k, () => at);
        if (l.contains('emit deal {hand: 0,') && l.contains('round: 0')) keyed.putIfAbsent(k, () => at);
      };
    }
    t.start();
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    expect(keyed, isNotEmpty, reason: 'the jury held bot seats and keyed them');
    for (final e in keyed.entries) {
      expect(said[e.key], isNotNull, reason: '${e.key} keyed a seat without the record saying the draw');
      expect(e.value, greaterThanOrEqualTo(said[e.key]!), reason: '${e.key} keyed before the record said the draw');
    }
    expect(a.record.where((d) => d.removal && d.event.kind == EventKind.escrow), isEmpty, reason: 'every holder keyed in time');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('keys that come before the draw they name is carried here are taken up when it is', () {
    // A summons without the hand's draws, as an app from before they
    // were sent with it says one: the juror hears it a moment after the
    // table has its jury, and the people key at once, so their keys
    // reach it before the jury event does.
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: 4);
    t.presence!.withDraws = false;
    final a = t.clients.first;
    final heldBack = <String>{};
    for (final j in t.jurors) {
      final k = j.signer.publicKey.substring(0, 4);
      j.log = (l) {
        if (l.contains('defer deal@h0/deal0.')) heldBack.add(k);
      };
    }
    t.start();
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    expect(heldBack, isNotEmpty, reason: 'keys reached a juror before the draw they name');
    expect(a.botHolders(0), isNotEmpty);
    for (final j in t.jurors) {
      expect(j.client?.sealedTo(0), a.sealedTo(0), reason: 'every juror read the draw');
    }
    expect(a.record.where((d) => d.removal && d.event.kind == EventKind.escrow), isEmpty, reason: 'every holder keyed its seat');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a juror summoned into a redraw has the hand\'s draws from its summons', () {
    // The explore tool's topup scenario: two of the jury holding no
    // seat go quiet during the deal and the jury is drawn again, a
    // hand's first draw at a play turn. Every carry says every jury, so
    // the table has just said the first draw again, to the sides
    // already there, a moment before the newcomers are; an event goes
    // once per eight seconds whoever is asking, so by carry alone they
    // would sit at the keys that long, reading the redraw for the
    // hand's.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.clock.schedule(2500, () {
      final c = t.clients.first;
      final held = c.botHolders(0).values.toSet();
      for (final k in c.juries.first.event.jurors.where((k) => !held.contains(k)).take(2)) {
        t.net.goOffline(k);
      }
    });
    final a = t.clients.first;
    final apart = <String>{};
    t.start();
    // Read every quarter second, as the explore tool reads every second.
    void look() {
      for (final j in t.jurors) {
        final s = j.client?.sealedTo(0);
        if (s != null && s != a.sealedTo(0)) apart.add(j.signer.publicKey.substring(0, 4));
      }
      if (t.clock.nowMs < 60000) t.clock.schedule(250, look);
    }

    t.clock.schedule(250, look);
    expect(t.clock.runUntil(() => a.juries.length >= 2 && t.clock.nowMs >= 60000, limitMs: 5 * 60 * 1000), isTrue, reason: a.describe());
    final redraw = a.juries.last.event;
    final newcomers = redraw.jurors.where((k) => !a.juries.first.event.jurors.contains(k)).toList();
    expect(newcomers, isNotEmpty, reason: 'the redraw brought jurors new to the hand');
    expect(apart, isEmpty, reason: 'a newcomer read another draw for the hand than the table\'s');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a holder\'s time for its keys starts when the record says the draw, not when the turn opened', () {
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: jurySize);
    final a = t.clients.first;
    // The first person's keys held back forty seconds on their way to
    // everyone: four times what a held seat is given for a deal step.
    t.net.steer = (from, to, message) {
      if (from != a.signer.publicKey || message['kind'] != 'deal') return null;
      final body = message['body'] as Map<String, Object?>;
      return body['hand'] == 0 && body['round'] == 0 ? 40000 : null;
    };
    t.start();
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    expect(a.handOutcome(0), HandState.over, reason: 'hand 0 was played');
    expect(a.record.where((d) => d.removal && d.event.kind == EventKind.escrow), isEmpty, reason: 'no holder was out of time');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a claim that comes before this side has the draw is kept for when it does', () {
    // Three people, one of whom hears nothing of the jury for a minute,
    // and a holder gone from the start. The other two give its seat to
    // the escrow at its keys; the third has their claims before it can
    // tell whose the seat is, and takes them up the moment it can.
    final t = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize);
    final a = t.clients.first;
    final late = t.clients.elementAt(2);
    t.net.steer = (from, to, message) {
      if (to != late.signer.publicKey) return null;
      if (message['kind'] == 'jury') return 60000;
      final body = message['body'];
      return message['kind'] == 'witness' && body is Map && body['jury'] == true ? 60000 : null;
    };
    var sealedAt = -1;
    var escrowAt = -1;
    late.log = (l) {
      final at = int.tryParse(l.substring(0, 7).trim());
      if (at == null) return;
      if (sealedAt < 0 && l.contains('hand 0: sealed to')) sealedAt = at;
      if (escrowAt < 0 && l.contains('to the escrow at h0/deal0.')) escrowAt = at;
    };
    var crashed = false;
    void crashAHolder() {
      final held = a.botHolders(0);
      if (held.isEmpty) {
        t.clock.schedule(100, crashAHolder);
        return;
      }
      t.net.crash(held.values.first);
      crashed = true;
    }

    t.clock.schedule(100, crashAHolder);
    t.start();
    expect(t.clock.runUntil(() => escrowAt >= 0, limitMs: 10 * 60 * 1000), isTrue, reason: late.describe());
    expect(crashed, isTrue);
    expect(sealedAt, greaterThanOrEqualTo(60000), reason: 'the late side read the draw only once its jury came');
    expect(escrowAt - sealedAt, lessThan(1000), reason: 'the claims it already had, taken up as it read the draw');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a person who hears of no jury waits for one, and never deals the bots in the open', () {
    // The first person hears nothing of the jury for a minute; the
    // other two have a jury long before. It waits, and to the others it
    // is a seat that has not taken its deal step: put out at the step's
    // clock like any other, while the hand is dealt to the jury.
    final t = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize);
    final first = t.clients.first;
    t.net.steer = (from, to, message) {
      if (to != first.signer.publicKey) return null;
      if (message['kind'] == 'jury') return 60000;
      final body = message['body'];
      return message['kind'] == 'witness' && body is Map && body['jury'] == true ? 60000 : null;
    };
    t.start();
    final b = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => b.botHolders(0).isNotEmpty, limitMs: 30000), isTrue, reason: 'the others had a jury for the hand');
    t.clock.runUntil(() => t.clock.nowMs >= 55000, limitMs: 60000);
    expect(first.dealOf(0), isNull, reason: 'still waiting for a jury at fifty-five seconds');
    expect(first.game.handNumber, 0);
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.game.handNumber >= 1), limitMs: 20 * 60 * 1000), isTrue,
        reason: t.clients.map((c) => c.describe()).join('\n'));
    for (final c in t.survivors) {
      expect(c.sealedTo(0), isNotNull, reason: 'sealed to the draw');
      expect(c.botHolders(0), isNotEmpty, reason: 'the bot seats held by the jury');
    }
    final survivor = t.survivors.first;
    final removed = survivor.record.where((d) => d.removal).toList();
    expect(removed, hasLength(1), reason: 'only the person who could not deal');
    expect(removed.single.turn.isDeal, isTrue, reason: 'put out at its deal step');
    final v = verifyRecord(t.spec, survivor.record, allowPartial: true, juries: survivor.juries, crypto: crypto, releases: survivor.releases);
    expect(v.ok, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('the verifier holds the keys to the draw', () {
    late SimTable t;
    late TableClient a;
    setUpAll(() {
      t = SimTable(humans: 1, seed: 4, crypto: crypto, jurors: jurySize, target: 1);
      t.start();
      expect(t.run(limitMs: 30 * 60 * 1000), isTrue);
      a = t.clients.first;
    });
    tearDownAll(() => t.stop());

    Verification check(List<Decision> r, [List<Decision>? juries]) =>
        verifyRecord(t.spec, r, juries: juries ?? a.juries, crypto: crypto, releases: a.releases);

    Decision withEvent(Decision d, TableEvent e) =>
        Decision(turn: d.turn, event: e, witnesses: d.witnesses, removal: d.removal, among: d.among, verdict: d.verdict);

    // Another draw for hand 0, carried: one that can hold the bot seats.
    Decision otherDraw() {
      final snapshot = [for (var k = 0; k < jurySize; k++) FakeSigner('elsewhere-$k').publicKey]..sort();
      final e = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.jury, body: {
        'hand': 0,
        'turn': TurnId.play(0, 9).index,
        'seat': 0,
        'jurors': drawJury(t.spec.seed, 0, snapshot),
        'snapshot': snapshot,
      });
      final me = {a.signer.publicKey};
      return Decision(turn: e.turn, event: e, witnesses: me, among: me, jury: true);
    }

    int keysOf(int seat) => a.record.indexWhere((d) => !d.removal && d.turn == TurnId.deal(0, 0, seat));

    test('as played, the record checks out, sealed to the draw the first person named', () {
      final v = check(a.record);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
      expect(a.record[keysOf(0)].event.body['jury'], a.sealedTo(0));
    });

    test('a held seat\'s keys naming another draw the hand carried are turned down', () {
      final other = otherDraw();
      final seat = a.botHolders(0).keys.first;
      final i = keysOf(seat);
      final d = a.record[i];
      final juror = t.jurors.firstWhere((j) => j.signer.publicKey == d.event.author).signer;
      final e = TableEvent.sign(juror, table: t.spec.id, kind: EventKind.deal, body: {...d.event.body, 'jury': other.event.id});
      final v = check([...a.record]..[i] = withEvent(d, e), [...a.juries, other]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('sealed to another draw'));
    });

    test('a held seat\'s keys from a juror of the hand the draw does not name for it are turned down', () {
      final seat = a.botHolders(0).keys.first;
      final i = keysOf(seat);
      final d = a.record[i];
      final other = t.jurors.firstWhere((j) => a.jurorsOf(0).contains(j.signer.publicKey) && j.signer.publicKey != d.event.author).signer;
      final e = TableEvent.sign(other, table: t.spec.id, kind: EventKind.deal, body: Map.of(d.event.body));
      final v = check([...a.record]..[i] = withEvent(d, e));
      expect(v.ok, isFalse);
      expect(v.reason, contains('does not name for it'));
    });

    test('a person\'s keys naming a draw the hand never carried are turned down', () {
      final i = keysOf(0);
      final d = a.record[i];
      final e = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.deal, body: {...d.event.body, 'jury': 'f' * 64});
      final v = check([...a.record]..[i] = withEvent(d, e));
      expect(v.ok, isFalse);
      expect(v.reason, contains('never carried'));
    });
  });

  test('a held seat\'s keys said by a juror the draw does not name for it are not taken', () {
    // The holder's own keys, signed again by another juror of the hand
    // and carried to one person ahead of the real ones.
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: jurySize);
    final a = t.clients.first;
    final relay = t.net.attach('relay-${t.spec.id}');
    String? forged;
    PublicKey? holder;
    int? seat;
    t.net.steer = (from, to, message) {
      if (message['id'] == forged) return to == a.signer.publicKey ? null : -1;
      if (message['kind'] != 'deal' || from != message['author']) return null;
      final body = message['body'] as Map<String, Object?>;
      if (body['hand'] != 0 || body['round'] != 0 || !a.botHolders(0).containsValue(from)) return null;
      if (forged == null) {
        holder = from;
        seat = body['seat'] as int;
        final other = t.jurors.firstWhere((j) => a.jurorsOf(0).contains(j.signer.publicKey) && j.signer.publicKey != from).signer;
        final e = TableEvent.sign(other, table: t.spec.id, kind: EventKind.deal, body: Map.of(body));
        forged = e.id;
        t.clock.schedule(1, () => relay.broadcast(e.toJson()));
      }
      return from == holder && to == a.signer.publicKey ? 2000 : null;
    };
    t.start();
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    expect(forged, isNotNull, reason: 'a holder keyed its seat');
    expect(a.keyedBy(0)[seat!], holder, reason: 'the seat keyed by its holder, not by the juror that signed a copy');
    final b = t.clients.elementAt(1);
    expect(a.record.map((d) => d.key).toList(), b.record.map((d) => d.key).toList());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a held seat is claimed for the escrow at its keys only once the record has said whose it is', () {
    // A claim names the seat and the turn, not the juror: made against
    // the holder this side guessed, it would count against the one the
    // record names.
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: jurySize);
    final a = t.clients.first;
    // The first person's keys held back forty seconds on their way to
    // everyone, and a holder gone from the start.
    t.net.steer = (from, to, message) {
      if (from != a.signer.publicKey || message['kind'] != 'deal') return null;
      final body = message['body'] as Map<String, Object?>;
      return body['hand'] == 0 && body['round'] == 0 ? 40000 : null;
    };
    final said = <String, int>{};
    final claimed = <String, int>{};
    for (final c in t.clients) {
      final k = c.signer.publicKey.substring(0, 4);
      c.log = (l) {
        final at = int.tryParse(l.substring(0, 7).trim());
        if (at == null) return;
        if (l.contains('hand 0: sealed to')) said.putIfAbsent(k, () => at);
        if (l.contains('emit escrow {hand: 0,')) claimed.putIfAbsent(k, () => at);
      };
    }
    var crashed = false;
    void crashAHolder() {
      final held = a.botHolders(0);
      if (held.isEmpty) {
        t.clock.schedule(100, crashAHolder);
        return;
      }
      t.net.crash(held.values.first);
      crashed = true;
    }

    t.clock.schedule(100, crashAHolder);
    t.start();
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    expect(crashed, isTrue, reason: 'a holder was named by then');
    expect(claimed, isNotEmpty, reason: 'the seat was claimed');
    for (final e in claimed.entries) {
      expect(said[e.key], isNotNull);
      expect(e.value, greaterThanOrEqualTo(said[e.key]!), reason: '${e.key} claimed before the record said whose the seat was');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a person gone before their keys is passed over, and the next person\'s keys say the draw', () {
    final t = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize);
    final gone = t.people.first;
    t.start();
    gone.depart(Exit.crash);
    final a = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => a.game.handNumber >= 1, limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    final out = a.record.firstWhere((d) => d.turn.hand == 0 && d.turn.isDeal);
    expect(out.removal && out.turn == TurnId.deal(0, 0, 0), isTrue, reason: 'the first seat went at its keys: $out');
    final next = a.record.firstWhere((d) => !d.removal && d.turn == TurnId.deal(0, 0, 1));
    expect(a.sealedTo(0), isNotNull);
    expect(next.event.body['jury'], a.sealedTo(0));
    for (final c in t.survivors) {
      expect(c.sealedTo(0), a.sealedTo(0));
    }
    final v = verifyRecord(t.spec, a.record, allowPartial: true, juries: a.juries, crypto: crypto, releases: a.releases);
    expect(v.ok, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
