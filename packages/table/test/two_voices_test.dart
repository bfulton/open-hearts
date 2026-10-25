/// A bot seat played twice, the same card by two voices.
///
/// A seat a juror holds is played by that juror until the table gives
/// it to the escrow — on the record, at the seat's own turn, for the
/// juror's silence or slowness — and from then on by the first of the
/// hand's custodians still about. A juror that was slow rather than
/// gone has its move on the wire all the same, and it can land after
/// the escrow, where it is a move by a juror of the hand at a seat the
/// escrow holds: as good as the custodian's. Two events, the same
/// card. Each person witnesses whichever came first, and at a table of
/// two the turn needs both of them, so neither move can carry; only
/// the jury breaks that, and the table must see that it has to rather
/// than sit at the card for good.
///
/// Set up by holding the juror's card back until a custodian has said
/// its own and letting each person hear a different one first.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  test('the same card said for a bot seat by its late juror and, after the escrow, a custodian is settled by the jury', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final a = t.clients.first;
    final b = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && b.game.phase == Phase.playing, limitMs: 5 * 60 * 1000),
        isTrue);
    final hand = a.game.handNumber;
    final held = a.botHolders(hand);
    // The held seat that plays soonest from here.
    final seat = [for (var i = 0; i < seatCount; i++) (a.game.currentSeat! + i) % seatCount].firstWhere(held.containsKey);
    final holder = held[seat]!;

    // The juror says its card on time, and nobody hears it until
    // seventeen seconds past a card's allowance: long enough for the
    // people to give the seat to the escrow and a custodian to say the
    // card for it. Then b hears the juror's card first and a the
    // custodian's, every copy of the custodian's to b held until well
    // after.
    String? custodian;
    int? released;
    int? until;
    t.net.steer = (from, to, message) {
      if (message['kind'] != 'play') return null;
      final body = message['body'] as Map<String, Object?>;
      if (body['hand'] != hand || body['seat'] != seat) return null;
      final author = message['author'] as String;
      if (author == holder) {
        if (custodian == null) {
          released ??= t.clock.nowMs + TableTiming.standard.botActsMs + 17000;
          return released! - t.clock.nowMs;
        }
        return null;
      }
      if (custodian == null) {
        custodian = author;
        until = [t.clock.nowMs + 15000, (released ?? t.clock.nowMs) + 5000].reduce((x, y) => x > y ? x : y);
      }
      if (to != b.signer.publicKey || t.clock.nowMs >= until!) return null;
      return until! - t.clock.nowMs;
    };

    // And neither voice says its card again for a person who has
    // backed the other: theirs is one vote, and it is spent
    // (client.dart, _sayAgainTo).
    final lines = <String>[];
    for (final c in [a, b]) {
      c.log = lines.add;
    }
    for (final j in t.jurors) {
      j.log = lines.add;
    }
    final cards = <Object?>{};
    final backed = <String, int>{};
    t.net.onSend = (from, message) {
      final body = message['body'];
      if (body is! Map || body['hand'] != hand) return;
      if (message['kind'] == 'play' && body['seat'] == seat) cards.add(message['id']);
      if (message['kind'] == 'witness' && cards.contains(body['event'])) backed.putIfAbsent(from.substring(0, 4), () => t.clock.nowMs);
    };

    final through = t.clock.runUntil(() => [a, b].every((c) => c.game.tricksPlayed >= 1), limitMs: 3 * 60 * 1000);
    for (final l in lines.where((l) => l.contains(' again: ') && l.contains('for seat $seat '))) {
      final at = int.parse(l.trimLeft().split(' ').first);
      final person = RegExp(r'again: (\w{4}) is here').firstMatch(l)!.group(1)!;
      final since = backed[person];
      expect(since == null || at < since + 1000, isTrue, reason: 'said again for $person, who backed a card at $since: $l');
    }
    expect(custodian, isNotNull, reason: 'a custodian said the seat\'s card');
    expect(through, isTrue, reason: 'the table moved past the seat:\n${a.describe()}\n${b.describe()}');
    Decision at(TableClient c, {required bool removal}) =>
        c.record.firstWhere((d) => d.turn.hand == hand && d.turn.isPlay && d.event.seat == seat && d.removal == removal);
    for (final c in [a, b]) {
      expect(at(c, removal: true).event.kind, EventKind.escrow, reason: 'the escrow is on the record');
    }
    final da = at(a, removal: false);
    final db = at(b, removal: false);
    expect(db.event.id, da.event.id, reason: 'both hold the same one of the two');
    expect(da.verdict, isNotNull, reason: 'the jury chose it');
    for (final c in [a, b]) {
      final v = verifyRecord(t.spec, c.record, allowPartial: true, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
