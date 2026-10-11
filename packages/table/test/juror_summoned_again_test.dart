/// A juror summoned to a table it has served before, after its client
/// there was let go of.
///
/// The duty lets go of a table once it has moved past every hand the
/// juror serves (juror_duty.dart), and a later summons starts a new
/// client, which reads the record from the first hand. The record names
/// its key as the holder of whatever bot seat its earlier client held;
/// a new client that took that as its own would draw fresh keys for a
/// seat keyed hands ago, keep them over the ones on the record, and
/// verify nothing shuffled from them. So it has no part in the hands
/// before its first summons ([SimTable.sweepJurors] lets go of a
/// juror's client as the duty does).
@Tags(['slow'])
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('a juror summoned again holds its seat, and has no part in the hands before', () {
    // More strangers than a jury, so a juror sits some hands out and is
    // drawn again later.
    final t = SimTable(humans: 1, seed: 2, crypto: crypto, jurors: jurySize + 3, sweepJurors: true);
    final lines = <String>[];
    for (final j in t.jurors) {
      j.log = lines.add;
    }
    t.start();
    expect(t.run(limitMs: 60 * 60 * 1000), isTrue, reason: 'the game was played out:\n${t.clients.first.describe()}');
    final a = t.clients.first;
    final last = a.game.handNumber;
    // Summoned again, to a hand where it holds a seat, after a hand
    // where its earlier client held one: the case.
    final again = [
      for (final j in t.jurors)
        for (final h in j.startedFor.skip(1))
          if (a.botHolders(h).containsValue(j.signer.publicKey) &&
              [for (var e = 0; e < h; e++) e].any((e) => a.botHolders(e).containsValue(j.signer.publicKey)))
            (j, h),
    ];
    expect(again, isNotEmpty, reason: 'a juror held a seat, was let go of, and was summoned to hold another');
    // Every seat was held to the end by the juror the record names: no
    // fault was put in, so nothing went to the escrow.
    final escrows = [for (final d in a.record) if (d.removal && d.event.kind == EventKind.escrow) d.turn];
    expect(escrows, isEmpty, reason: 'seats given to the escrow');
    // Nor did any juror wait on a hand it could not open: it held
    // nothing there, and there is nothing else to wait on at a table
    // with no fault in it.
    expect(lines.where((l) => l.contains('stalled at')).take(3), isEmpty);
    // Nothing said about a hand before a client's summons, and every
    // client still serving is where the table is.
    for (final j in t.jurors) {
      expect(j.saidBeforeSummons, 0, reason: '${j.signer.publicKey.substring(0, 6)} spoke in a hand it had no part in');
      final c = j.client;
      if (c == null) continue;
      expect(c.game.handNumber, last, reason: 'with the table:\n${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a summons to a hand its last client had reached starts nothing', () {
    // A player behind, catching up on a jury it missed, summons that
    // jury's jurors as though the hand were new. One of them held a
    // seat in it and has since been let go of; a client started on the
    // summons would read the seat as its own again.
    final t = SimTable(humans: 1, seed: 2, crypto: crypto, jurors: jurySize + 3, sweepJurors: true);
    t.start();
    final a = t.clients.first;
    SimJuror? held() {
      final holders = a.botHolders(0).values.toSet();
      for (final j in t.jurors) {
        if (j.client == null && j.swept > 0 && holders.contains(j.signer.publicKey)) return j;
      }
      return null;
    }

    expect(t.clock.runUntil(() => held() != null, limitMs: 30 * 60 * 1000), isTrue, reason: 'a holder of hand 0 was let go of');
    final j = held()!;
    final first = a.juries.firstWhere((d) => d.event.hand == 0).event;
    j.summoned(t.spec, 0, first.jurors, juryId: first.id, first: true);
    expect(j.client, isNull, reason: 'no client started for a hand it had followed past');
    expect(j.stale, 1);
    expect(t.run(limitMs: 60 * 60 * 1000), isTrue, reason: 'the game was played out:\n${a.describe()}');
    final escrows = [for (final d in a.record) if (d.removal && d.event.kind == EventKind.escrow) d.turn];
    expect(escrows, isEmpty, reason: 'seats given to the escrow');
    for (final j in t.jurors) {
      expect(j.saidBeforeSummons, 0);
      final c = j.client;
      if (c != null) expect(c.game.handNumber, a.game.handNumber, reason: 'with the table:\n${c.describe()}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('nor makes parts of a share for a juror brought on in a hand before', () {
    // Two jurors holding no seat go quiet during the first hand's deal,
    // the jury is drawn again and topped up, and the holders make the
    // newcomers their parts. A juror of that hand summoned again reads
    // the redraw in the record and is one of those holders by key.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, sweepJurors: true);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    final a = t.clients.first;
    t.clock.schedule(2500, () {
      final drawn = a.juries.isEmpty ? const <PublicKey>[] : a.juries.first.event.jurors;
      final held = a.botHolders(a.game.handNumber).values.toSet();
      for (final k in drawn.where((k) => !held.contains(k)).take(2)) {
        t.net.goOffline(k);
      }
    });
    t.start();
    expect(t.run(limitMs: 60 * 60 * 1000), isTrue, reason: 'the game was played out:\n${a.describe()}');
    expect(a.juries.where((d) => d.event.hand == 0).length, greaterThan(1), reason: 'the first hand was topped up');
    final first = a.juries.firstWhere((d) => d.event.hand == 0).event.jurors.toSet();
    expect([for (final j in t.jurors) if (first.contains(j.signer.publicKey) && j.startedFor.length > 1) j], isNotEmpty,
        reason: 'a juror of the first hand was summoned again');
    for (final j in t.jurors) {
      expect(j.saidBeforeSummons, 0, reason: '${j.signer.publicKey.substring(0, 6)} spoke in a hand it had no part in');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('nor releases its piece of a seat given up in a hand before', () {
    // A person leaves during the first hand, and the jury the deal was
    // sealed to releases its pieces of their seat. Jurors of that hand
    // let go of and summoned again read the leave in the record, and
    // their key is among the seat's custodians; the pieces were said
    // by the clients that served the hand.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 3, sweepJurors: true);
    t.start();
    final leaver = t.people.last;
    t.clock.runUntil(() => leaver.client.game.phase == Phase.playing && leaver.client.game.tricksPlayed >= 2, limitMs: 5 * 60 * 1000);
    leaver.depart(Exit.leave);
    expect(t.run(limitMs: 60 * 60 * 1000), isTrue, reason: 'the game was played out:\n${t.clients.first.describe()}');
    final a = t.clients.first;
    final first = a.juries.firstWhere((d) => d.event.hand == 0).event.jurors.toSet();
    final again = [for (final j in t.jurors) if (first.contains(j.signer.publicKey) && j.startedFor.length > 1) j];
    expect(again, isNotEmpty, reason: 'a juror of the first hand was summoned again');
    for (final j in t.jurors) {
      expect(j.saidBeforeSummons, 0, reason: '${j.signer.publicKey.substring(0, 6)} spoke in a hand it had no part in');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
