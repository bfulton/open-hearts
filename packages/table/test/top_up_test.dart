/// The jury tops back up, and whoever joins is given a share.
///
/// A jury that only shrinks runs out: a bot seat's escrow rests on
/// enough of the jurors it was sealed to still being reachable when
/// the seat's holder goes (docs/explanation/live-play.md). Bringing somebody on
/// is the lever, and it is worth nothing unless the newcomer is given
/// a share of what the others hold.
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

  test('a juror drawn after the deal is given a share of an escrow it was never sealed to', () {
    // More jurors online than a jury takes, so there is somebody to
    // bring on when the first lot start going.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4);
    // And a relay's latency, which is what makes there be a hand left
    // to watch. A top-up is a mid-hand thing — a juror brought on
    // while a hand is running — and seeing one needs the hand still
    // running thirty seconds after a jury has been judged short. Over
    // a data channel a bot seat reaches the escrow soon after its
    // holder stops playing (client.dart, botActsWithinMs) and the rest
    // of the jury plays it out before there is anything to see.
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 20 * 60 * 1000);
    final client = t.clients.first;
    final hand = client.game.handNumber;
    final sealedTo = client.juries.where((d) => d.event.hand == hand).map((d) => d.event.jurors.toSet()).first;
    expect(sealedTo, isNotEmpty, reason: 'a jury was drawn for the hand');

    // Two of the jury go. The table should draw replacements rather
    // than carry on with what is left.
    final leaving = sealedTo.take(2).toList();
    for (final k in leaving) {
      t.net.goOffline(k);
    }
    t.clock.advance(60000);

    final now = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    final brought = now.difference(sealedTo);
    expect(brought, isNotEmpty, reason: 'the jury was topped back up: $now against $sealedTo');

    // And the holders make parts of a share for whoever was brought
    // on: two of them, for each newcomer and each bot seat.
    final sent = [
      for (final j in t.jurors)
        if (sealedTo.contains(j.signer.publicKey) && (j.client?.topUpsSent ?? 0) > 0) j.signer.publicKey,
    ];
    expect(sent.length, escrowThreshold, reason: 'two holders answer, not all of them');

    // And the newcomers take the parts up: two parts make one share,
    // and a juror brought on mid-hand holds a piece of the escrow it
    // was never sealed to. This is what the topping up is for — the
    // jury that carries the rest of the hand is the one standing at
    // the end of it, not the one the deal went out to.
    final carried = t.clock.runUntil(() => client.game.handNumber > hand, limitMs: 5 * 60 * 1000);
    expect(carried, isTrue, reason: 'the hand played on: ${client.describe()}');
    // The table does not wait for them: a juror brought on comes to
    // the hand from where it joined it, so it holds its piece a
    // little after the table has moved on.
    final ours = [for (final j in t.jurors) if (brought.contains(j.signer.publicKey)) j];
    final holding = t.clock.runUntil(
      () => ours.every((j) => j.client?.holdsEscrowPiece(hand) ?? false),
      limitMs: 5 * 60 * 1000,
    );
    expect(holding, isTrue,
        reason: 'every juror brought on holds a piece of the hand it was brought on to:\n'
            '${[for (final j in ours) '${j.signer.publicKey.substring(0, 4)}: '
                '${j.client?.holdsEscrowPiece(hand)}'].join('\n')}');
    // And carries the hand to its end, which says the share is a
    // working one rather than a keepsake: the seat whose holder went
    // is opened from the escrow, and the audit at the end of the hand
    // is answered for it.
    final caught = t.clock.runUntil(
      () => ours.every((j) => (j.client?.game.handNumber ?? -1) > hand),
      limitMs: 5 * 60 * 1000,
    );
    expect(caught, isTrue,
        reason: 'every juror brought on carried the hand to its end:\n'
            '${[for (final j in ours) j.client?.describe()].join('\n')}');
    t.stop();
  },
      timeout: const Timeout(Duration(minutes: 10)));

  test('a seat given to the escrow opens for the verifier from a newcomer\'s piece and one other', () {
    // The same table, one hand long, so that the record ends.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 4, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 20 * 60 * 1000);
    final client = t.clients.first;
    final hand = client.game.handNumber;
    final sealedTo = client.juries.where((d) => d.event.hand == hand).map((d) => d.event.jurors.toSet()).first;
    final leaving = sealedTo.take(2).toList();
    for (final k in leaving) {
      t.net.goOffline(k);
    }
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue, reason: client.describe());
    final brought = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet().difference(sealedTo);
    final given = client.escrowedAt(hand).keys.toList();
    expect(given, isNotEmpty, reason: 'a holder went and its seat was given to the escrow');
    final seat = given.first;
    // Of that seat's pieces in the open, one from a juror brought on
    // and one from the jury the deal was sealed to: two, which is all
    // it takes, and one of them at a place in the custodians the seat's
    // own keys never named.
    final open = [for (final r in client.releases) if (r.hand == hand && r.about == seat && r.body['share'] != null) r];
    final newcomer = open.where((r) => brought.contains(r.author)).firstOrNull;
    final original = open.where((r) => sealedTo.contains(r.author)).firstOrNull;
    expect(newcomer, isNotNull, reason: 'a juror brought on released its piece: ${open.map((r) => r.author.substring(0, 4))}');
    expect(original, isNotNull);
    final releases = [
      for (final r in client.releases)
        if (r.hand != hand || r.about != seat || r.body['share'] == null) r,
      newcomer!,
      original!,
    ];
    final v = verifyRecord(t.spec, client.record, juries: client.juries, crypto: crypto, releases: releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('and so it does when the jury was topped up before the seat was keyed', () {
    // A newcomer's piece is weighed by its place among the custodians,
    // and the seat's keys give the list its first places: made after a
    // top-up, they have to list the custodians in the order the top-up
    // counted them in, newcomers last, or the newcomer's piece is weighed
    // for somebody else's place.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 6, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    final client = t.clients.first;
    // The first person's keys held back forty seconds, so the holders
    // key late; two of the jury holding no seat gone first, so the jury
    // is topped up before they do.
    t.net.steer = (from, to, message) {
      if (from != client.signer.publicKey || message['kind'] != 'deal') return null;
      final body = message['body'] as Map<String, Object?>;
      return body['hand'] == 0 && body['round'] == 0 ? 40000 : null;
    };
    t.clock.schedule(2500, () {
      final drawn = client.juries.isEmpty ? const <PublicKey>[] : client.juries.first.event.jurors;
      final held = client.botHolders(0).values.toSet();
      for (final k in drawn.where((k) => !held.contains(k)).take(2)) {
        t.net.goOffline(k);
      }
    });
    t.start();
    expect(t.clock.runUntil(() => client.game.phase == Phase.playing, limitMs: 20 * 60 * 1000), isTrue, reason: client.describe());
    final hand = client.game.handNumber;
    final sealedTo = client.juries.where((d) => d.event.hand == hand).map((d) => d.event.jurors.toSet()).first;
    final brought = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet().difference(sealedTo);
    expect(brought, isNotEmpty, reason: 'the jury was topped up before the seats were keyed');
    // And again while the hand is played: three more of the jury holding
    // no seat go, which leaves it short, and with them a holder, whose
    // seat goes to the escrow. Whoever is drawn now is given a share by
    // the holders of the pieces — parts made for a place in the list,
    // which is the list the seats' keys began — and says it in the open
    // with the rest at the hand's end.
    final held = client.botHolders(hand).values.toSet();
    final before = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    for (final k in before.where((k) => !held.contains(k) && t.net.isUp(k)).take(3)) {
      t.net.goOffline(k);
    }
    t.net.goOffline(held.first);
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue, reason: client.describe());
    final later = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet().difference(before);
    expect(later, isNotEmpty, reason: 'the jury was topped up again');
    final ours = [for (final j in t.jurors) if (later.contains(j.signer.publicKey)) j];
    expect(t.clock.runUntil(() => ours.every((j) => j.client?.holdsEscrowPiece(hand) ?? false), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'every juror brought on the second time holds a piece');
    // Of every bot seat, as the table counts it: a whole set of parts
    // for each, the seats' own jurors among the custodians making them.
    for (final s in client.botHolders(hand).keys) {
      expect(client.pieceHoldersOf(hand, s), containsAll(later), reason: 'seat $s\'s pieces reached every juror brought on');
    }
    final seat = client.escrowedAt(hand).keys.first;
    final open = [for (final r in client.releases) if (r.hand == hand && r.about == seat && r.body['share'] != null) r];
    final newcomer = open.where((r) => later.contains(r.author)).firstOrNull;
    final original = open.where((r) => sealedTo.contains(r.author)).firstOrNull;
    expect(newcomer, isNotNull, reason: 'a juror brought on released its piece: ${open.map((r) => r.author.substring(0, 4))}');
    expect(original, isNotNull);
    final releases = [
      for (final r in client.releases)
        if (r.hand != hand || r.about != seat || r.body['share'] == null) r,
      newcomer!,
      original!,
    ];
    final v = verifyRecord(t.spec, client.record, juries: client.juries, crypto: crypto, releases: releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a draw read first, carried after the deal was sealed to another, moves no custodian\'s place', () {
    // The custodians' list starts with the jury the deal was sealed to,
    // not with whichever draw sorts first: a draw proposed from an
    // earlier place and carried later sorts ahead of it, and the
    // newcomers it brings belong at the end of the list, where the
    // seats' keys and every part made for them put them.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 8, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final client = t.clients.first;
    expect(t.clock.runUntil(() => client.game.phase == Phase.playing && client.sealedTo(0) != null, limitMs: 20 * 60 * 1000), isTrue);
    final hand = client.game.handNumber;
    final sealed = client.juries.firstWhere((d) => d.event.id == client.sealedTo(hand)).event;
    final drawn = client.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    // Six strangers not yet drawn, proposed by the first person from the
    // first place there is in the hand, and backed by the other.
    final snapshot = [for (final j in t.jurors) if (!drawn.contains(j.signer.publicKey)) j.signer.publicKey].take(jurySize).toList()..sort();
    final proposal = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.jury, body: {
      'hand': hand,
      'turn': TurnId.deal(hand, 0, 0).index,
      'seat': 0,
      'jurors': drawJury(t.spec.seed, hand, snapshot),
      'snapshot': snapshot,
    });
    final backed = TableEvent.sign(t.signers[1], table: t.spec.id, kind: EventKind.witness, body: {
      'event': proposal.id,
      'hand': hand,
      'turn': proposal.turn.index,
      'seat': 0,
      'jury': true,
    });
    final relay = t.net.attach('relay-${t.spec.id}');
    relay.broadcast(proposal.toJson());
    relay.broadcast(backed.toJson());
    final brought = proposal.jurors.toSet();
    expect(t.clock.runUntil(() => client.juries.any((d) => d.event.id == proposal.id), limitMs: 10000), isTrue, reason: 'the draw carried');
    final ordered = client.juries.where((d) => d.event.hand == hand).toList()..sort(compareJuries);
    expect(ordered.first.event.id, proposal.id, reason: 'read first by the juries\' own order');
    expect(client.sealedTo(hand), sealed.id, reason: 'the deal stays sealed to its draw');
    // A holder goes, its seat to the escrow; the newcomers are given
    // their shares and say them in the open at the hand's end.
    t.net.goOffline(client.botHolders(hand).values.first);
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue, reason: client.describe());
    final seat = client.escrowedAt(hand).keys.first;
    final open = [for (final r in client.releases) if (r.hand == hand && r.about == seat && r.body['share'] != null) r];
    final newcomer = open.where((r) => brought.contains(r.author)).firstOrNull;
    final original = open.where((r) => sealed.jurors.contains(r.author)).firstOrNull;
    expect(newcomer, isNotNull, reason: 'a juror brought on released its piece: ${open.map((r) => r.author.substring(0, 4))}');
    expect(original, isNotNull);
    final releases = [
      for (final r in client.releases)
        if (r.hand != hand || r.about != seat || r.body['share'] == null) r,
      newcomer!,
      original!,
    ];
    final v = verifyRecord(t.spec, client.record, juries: client.juries, crypto: crypto, releases: releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('two draws carried the other way round at two sides give each newcomer one place, the record\'s', () {
    // A held seat's pieces are indexed by each custodian's place in the
    // escrow's list. Two draws of one hand carried in the other order
    // at two sides would give their newcomers different places, and a
    // third place at the verifier, so the record says the order: a
    // person's own play names the draws that grew it.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize * 3 + 4, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final a = t.clients.first, b = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.sealedTo(0) != null, limitMs: 20 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final sealed = a.juries.firstWhere((d) => d.event.id == a.sealedTo(hand)).event;
    final drawn = a.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    final fresh = [for (final j in t.jurors) if (!drawn.contains(j.signer.publicKey)) j.signer.publicKey]..sort();
    // Two draws of six strangers each, the first proposed from an
    // earlier place than the second, each backed by the other person.
    TableEvent propose(int by, TurnId at, List<PublicKey> snapshot) => TableEvent.sign(t.signers[by], table: t.spec.id, kind: EventKind.jury, body: {
          'hand': hand,
          'turn': at.index,
          'seat': by,
          'jurors': drawJury(t.spec.seed, hand, snapshot),
          'snapshot': snapshot,
        });
    TableEvent back(int by, TableEvent p) => TableEvent.sign(t.signers[by], table: t.spec.id, kind: EventKind.witness, body: {
          'event': p.id,
          'hand': hand,
          'turn': p.turn.index,
          'seat': p.seat,
          'jury': true,
        });
    final first = propose(0, TurnId.deal(hand, 0, 0), fresh.take(jurySize).toList());
    final second = propose(1, TurnId.deal(hand, 1, 1), fresh.skip(jurySize).take(jurySize).toList());
    // Each person hears the other's draw three seconds late, whoever
    // carries it: a carries the second first, b the first.
    String? about(Map<String, Object?> message) {
      final body = message['body'];
      if (body is! Map) return null;
      if (message['kind'] == 'jury') return (body['jurors'] as List).join() == first.jurors.join() ? first.id : second.id;
      if (message['kind'] == 'witness' && body['jury'] == true) return body['event'] as String?;
      return null;
    }
    t.net.steer = (from, to, message) {
      final id = about(message);
      if (id == first.id && to == a.signer.publicKey) return 3000;
      if (id == second.id && to == b.signer.publicKey) return 3000;
      return null;
    };
    final relay = t.net.attach('relay-${t.spec.id}');
    for (final e in [first, back(1, first), second, back(0, second)]) {
      relay.broadcast(e.toJson());
    }
    bool carried(TableClient c) => [first, second].every((p) => c.juries.any((d) => d.event.id == p.id));
    expect(t.clock.runUntil(() => carried(a) && carried(b), limitMs: 30000), isTrue, reason: 'both draws carried at both');
    t.net.steer = null;
    int placeOf(TableClient c, TableEvent p) => c.juries.indexWhere((d) => d.event.id == p.id);
    expect(placeOf(a, second), lessThan(placeOf(a, first)), reason: 'a carried the second draw first');
    expect(placeOf(b, first), lessThan(placeOf(b, second)), reason: 'b carried the first draw first');
    final ordered = a.juries.where((d) => d.event.hand == hand).toList()..sort(compareJuries);
    expect(ordered.indexWhere((d) => d.event.id == first.id), lessThan(ordered.indexWhere((d) => d.event.id == second.id)),
        reason: 'and the juries\' own order has the first ahead of the second');

    // The newcomers go on once a person's play names their draws, and
    // every side has them at the same places.
    final brought = {...first.jurors, ...second.jurors};
    final seats = a.botHolders(hand).keys.toList();
    bool grown(TableClient c) => seats.every((s) => brought.every(c.escrowOrderOf(hand, s).contains));
    expect(t.clock.runUntil(() => grown(a) && grown(b), limitMs: 5 * 60 * 1000), isTrue, reason: 'the escrow grew by both draws');
    final naming = [
      for (final d in a.record)
        if (d.turn.hand == hand && d.event.kind == EventKind.play && d.event.body['grew'] is List) d.event,
    ];
    expect(naming.expand((e) => e.body['grew'] as List).toSet(), containsAll([first.id, second.id]),
        reason: 'the record names both draws, in people\'s plays');
    expect(naming.every((e) => t.spec.seats[e.seat] is HumanSeat && (t.spec.seats[e.seat] as HumanSeat).key == e.author), isTrue);
    for (final s in seats) {
      final order = a.escrowOrderOf(hand, s);
      expect(b.escrowOrderOf(hand, s), order, reason: 'seat $s: one order at both people');
      for (final j in t.jurors) {
        final c = j.client;
        if (c == null || !c.escrowOrderOf(hand, s).toSet().containsAll(brought)) continue;
        expect(c.escrowOrderOf(hand, s), order, reason: 'seat $s: and at juror ${j.signer.publicKey.substring(0, 4)}');
      }
    }

    // Every newcomer is given its share, and then the whole jury the
    // deal was sealed to goes, both holders with it: the seats go to
    // the escrow and the newcomers alone hold it. The first of them in
    // the seat's own order says its moves, and it is the one the
    // others seal their pieces to.
    final ours = [for (final j in t.jurors) if (brought.contains(j.signer.publicKey)) j];
    expect(t.clock.runUntil(() => ours.every((j) => j.client?.holdsEscrowPiece(hand) ?? false), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'every newcomer holds a piece');
    // The pieces said in the open at the hand's end reach the people
    // after they have audited, so no audit carries either seat's secret
    // and the verifier has only the pieces to open them with. A
    // newcomer from each draw says its piece, and those two alone open
    // the seat for the verifier: each weighed at the place its share
    // was made for.
    final people = {a.signer.publicKey, b.signer.publicKey};
    t.net.steer = (from, to, message) {
      final body = message['body'];
      return message['kind'] == 'release' && body is Map && body['share'] != null && people.contains(to) ? 30000 : null;
    };
    for (final k in sealed.jurors) {
      t.net.goOffline(k);
    }
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    final seat = seats.first;
    expect(a.escrowedAt(hand).keys, contains(seat));
    // What was held back on its way to the people lands after they are
    // done; the pieces are what the verifier is handed.
    List<TableEvent> said() => [for (final r in a.releases) if (r.hand == hand && r.about == seat && r.body['share'] != null) r];
    t.clock.runUntil(() => said().any((r) => first.jurors.contains(r.author)) && said().any((r) => second.jurors.contains(r.author)), limitMs: 60000);
    final open = said();
    final one = open.where((r) => first.jurors.contains(r.author)).firstOrNull;
    final other = open.where((r) => second.jurors.contains(r.author)).firstOrNull;
    expect(one, isNotNull, reason: 'a juror of the first draw released its piece: ${open.map((r) => r.author.substring(0, 4))}');
    expect(other, isNotNull, reason: 'and one of the second: ${open.map((r) => r.author.substring(0, 4))}');
    expect(sealed.jurors.contains(one!.author) || sealed.jurors.contains(other!.author), isFalse);
    final rest = [
      for (final r in a.releases)
        if (r.hand != hand || r.about != seat || r.body['share'] == null) r,
    ];
    final without = verifyRecord(t.spec, a.record, juries: a.juries, crypto: crypto, releases: rest);
    expect(without.ok && without.complete, isFalse, reason: 'the seat opens for the verifier from its pieces alone');
    final releases = [...rest, one, other!];
    final v = verifyRecord(t.spec, a.record, juries: a.juries, crypto: crypto, releases: releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a piece refused for a place not yet on the record is taken once the record gives it', () {
    // A seat given to the escrow before a play named the newcomers, a
    // custodian of it still behind that play, and every other custodian
    // on its list gone: the newcomers' pieces reach it from custodians it
    // has no place for yet. Refused, they were refused for good — each
    // of them says its piece again only while it still waits on the
    // secret itself, and they had all opened the seat between them. It
    // was the one left to say the seat's moves, and the table stopped.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize * 2 + 4, target: 1);
    t.net.minLatencyMs = 200;
    t.net.maxLatencyMs = 400;
    t.start();
    final a = t.clients.first;
    expect(t.clock.runUntil(() => a.game.phase == Phase.playing && a.sealedTo(0) != null, limitMs: 20 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final sealed = a.juries.firstWhere((d) => d.event.id == a.sealedTo(hand)).event;
    final holders = a.botHolders(hand);
    final seat = holders.keys.first;
    // The custodian that will be left: one the seat's first pieces are
    // not sealed to, the three ahead of it saying its moves between them.
    final order = [for (final k in a.escrowOrderOf(hand, seat)) if (!holders.values.contains(k)) k];
    final left = order[3];
    // The seat to the escrow, and its moves said again.
    t.net.goOffline(holders[seat]!);
    expect(t.clock.runUntil(() => a.escrowedAt(hand).containsKey(seat), limitMs: 5 * 60 * 1000), isTrue, reason: 'the seat went to the escrow');
    final plays = a.record.where((d) => d.turn.hand == hand && d.turn.isPlay).length;
    expect(t.clock.runUntil(() => a.record.where((d) => d.turn.hand == hand && d.turn.isPlay).length >= plays + 4, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the table plays on, the escrow saying the seat\'s moves');
    // A draw, named by the next person's play — which the one to be left
    // does not hear for a minute.
    final drawn = a.juries.where((d) => d.event.hand == hand).expand((d) => d.event.jurors).toSet();
    final snapshot = [for (final j in t.jurors) if (!drawn.contains(j.signer.publicKey) && t.net.isUp(j.signer.publicKey)) j.signer.publicKey]
        .take(jurySize)
        .toList()
      ..sort();
    final proposal = TableEvent.sign(t.signers.first, table: t.spec.id, kind: EventKind.jury, body: {
      'hand': hand,
      'turn': a.record.last.turn.index,
      'seat': 0,
      'jurors': drawJury(t.spec.seed, hand, snapshot),
      'snapshot': snapshot,
    });
    final backed = TableEvent.sign(t.signers[1], table: t.spec.id, kind: EventKind.witness, body: {
      'event': proposal.id,
      'hand': hand,
      'turn': proposal.turn.index,
      'seat': 0,
      'jury': true,
    });
    t.net.steer = (from, to, message) {
      final body = message['body'];
      return to == left && message['kind'] == 'play' && body is Map && body['grew'] is List ? 60000 : null;
    };
    final relay = t.net.attach('relay-${t.spec.id}');
    relay.broadcast(proposal.toJson());
    relay.broadcast(backed.toJson());
    final brought = proposal.jurors.toSet();
    final ours = [for (final j in t.jurors) if (brought.contains(j.signer.publicKey)) j];
    expect(t.clock.runUntil(() => ours.every((j) => j.client?.holdsEscrowPiece(hand) ?? false), limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the newcomers hold their pieces');
    final behind = t.jurors.firstWhere((j) => j.signer.publicKey == left).client!;
    expect(behind.escrowOrderOf(hand, seat).any(brought.contains), isFalse, reason: 'the one to be left is behind the play that named them');
    // Every other custodian of the jury the deal was sealed to goes.
    for (final k in sealed.jurors) {
      if (k != left) t.net.goOffline(k);
    }
    expect(t.clock.runUntil(() => t.survivors.every((c) => c.done), limitMs: 20 * 60 * 1000), isTrue, reason: a.describe());
    for (final c in [a, t.clients.elementAt(1)]) {
      expect(c.failure, isNull, reason: 'the hand was played out, not ended');
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
