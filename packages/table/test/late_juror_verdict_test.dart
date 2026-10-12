/// A juror summoned late, and a seat the jury ruled out before it came.
///
/// A juror summoned a few hands in reads the record from the first
/// hand, carried forward by the table. Every carry sends every removal
/// in the record with the verdict that carried it, wherever the asker
/// stands, ahead of the juries those verdicts rest on — so a juror far
/// behind hears a removal's verdict before it knows the jury that gave
/// it. Dropped then, the verdict was a repeat ever after and never
/// read again: the juror stopped at the removal for good, counted the
/// seat a person's, and read every later hand's bot seats a seat short
/// of the table — one juror on a seat the table gave another
/// (docs/explanation/table-states.md). The chaos walk found it
/// (`tool/chaos.dart --sealed-only 4 --jurors 9 --sweep --twins`).
///
/// The same for a verdict carrying a held seat's keys, heard before
/// the record has said here which draw the hand is sealed to: keys
/// this side cannot take yet are kept, and the verdict on them now is
/// too (`--sealed-only 9`).
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

  test('a juror summoned after the jury ruled a seat out reads the table\'s bot seats', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 2);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    // The other person goes quiet in the first hand's play. With two at
    // the table one is no majority, so the seat is the jury's to rule
    // out, and it is: the removal is on the record with its verdict.
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 2, limitMs: 10 * 60 * 1000), isTrue);
    quiet.depart(Exit.idle);
    bool ruledOut() => a.record.any((d) => d.removal && d.verdict != null && d.event.seat == quiet.client.mySeat);
    expect(t.clock.runUntil(ruledOut, limitMs: 10 * 60 * 1000), isTrue, reason: 'the jury ruled the seat out:\n${a.describe()}');
    // Two hands on, the seat a bot the jury holds.
    expect(t.clock.runUntil(() => a.game.handNumber >= 2 && a.game.phase == Phase.playing, limitMs: 30 * 60 * 1000), isTrue,
        reason: 'the table went on:\n${a.describe()}');
    final hand = a.game.handNumber;
    final first = a.juries.firstWhere((d) => d.event.hand == hand).event;

    // A juror nobody has heard of until now, summoned to this hand.
    final late = SimJuror(FakeSigner('late juror'), t.net, t.clock, crypto: crypto);
    t.jurors.add(late);
    late.summoned(t.spec, hand, first.jurors, juryId: first.id, first: true);
    final c = late.client!;
    expect(t.clock.runUntil(() => c.game.handNumber >= hand && c.botHolders(hand).isNotEmpty, limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the late juror reached the table\'s hand:\n${c.describe()}');
    expect(c.participants, a.participants, reason: 'the seat ruled out is out here too');
    expect(c.botHolders(hand), a.botHolders(hand), reason: 'the same juror on every bot seat');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('and one summoned after the jury carried a held seat\'s keys reads them', () {
    // The second hand's held seats' jurors are out of the people's
    // earshot for a few seconds as it is dealt, so the people's own
    // keys settle first, and then the other person goes quiet: one
    // person is no majority, so the jury rules each held seat's keys
    // in. A juror reading the record later opens those turns before
    // the record has said here which draw the hand is sealed to, and
    // the verdict carrying the keys is not one it can take yet.
    // Dropped then, it was a repeat ever after, and the juror waited
    // at the seat's keys for good.
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 2);
    t.start();
    final a = t.clients.first;
    final quiet = t.people.last;
    final people = [for (final p in t.people) p.client.signer.publicKey];
    expect(t.clock.runUntil(() => a.juries.any((d) => d.event.hand == 1), limitMs: 30 * 60 * 1000), isTrue);
    final holders = a.botHolders(1).values.toList();
    for (final h in holders) {
      for (final p in people) {
        t.net.cut(h, p);
      }
    }
    t.clock.schedule(5000, () {
      for (final h in holders) {
        for (final p in people) {
          t.net.uncut(h, p);
        }
      }
    });
    expect(t.clock.runUntil(() => a.keyedBy(1).containsKey(quiet.client.mySeat), limitMs: 5000), isTrue, reason: 'the people keyed first');
    quiet.depart(Exit.idle);
    bool ruledKeys() => a.record.any((d) => d.verdict != null && !d.removal && d.turn.hand == 1 && d.turn.isDeal && d.turn.dealRound == 0);
    expect(t.clock.runUntil(() => ruledKeys() && a.game.handNumber >= 2 && a.game.phase == Phase.playing, limitMs: 30 * 60 * 1000), isTrue,
        reason: 'the jury ruled a held seat\'s keys in, and the table went on:\n${a.describe()}');
    final hand = a.game.handNumber;
    final first = a.juries.firstWhere((d) => d.event.hand == hand).event;

    final late = SimJuror(FakeSigner('late juror'), t.net, t.clock, crypto: crypto);
    t.jurors.add(late);
    // The people's keys for that hand reach it a little after
    // everything else, so the verdict on a held seat's keys comes
    // before the record has said here which draw the hand is sealed
    // to: the order a carry happened to give a juror in the chaos walk.
    final lateKey = late.signer.publicKey;
    t.net.steer = (from, to, m) {
      final body = m['body'];
      if (to != lateKey || m['kind'] != 'deal' || body is! Map) return null;
      return body['hand'] == 1 && body['round'] == 0 && people.contains(m['author']) ? 3000 : null;
    };
    late.summoned(t.spec, hand, first.jurors, juryId: first.id, first: true);
    final c = late.client!;
    expect(t.clock.runUntil(() => c.game.handNumber >= hand && c.botHolders(hand).isNotEmpty, limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the late juror reached the table\'s hand:\n${c.describe()}');
    expect(c.participants, a.participants);
    expect(c.botHolders(hand), a.botHolders(hand), reason: 'the same juror on every bot seat');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
