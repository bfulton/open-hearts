/// A held seat given to the escrow, on the record.
///
/// A bot seat a juror holds is played by that juror. When the juror is
/// gone, or too slow on the seat's turn, the people claim the seat for
/// the escrow at that turn, and the claim is carried the way a boot is:
/// by a majority of them, or by the jury where they split. From there
/// to the end of the hand the seat is played by the first of the
/// escrow's jurors still about (docs/07-states.md, "Next").
///
/// It used to be each side's own judgement, from its own clocks, with
/// nothing in the record: two sides could give the seat up at
/// different turns, or one could and the other not, and nothing
/// reconciled them.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  /// The table at the start of play, and the held seat that plays
  /// soonest from there, with its juror and the turn it plays at.
  ({int hand, int seat, PublicKey holder, TurnId turn}) soonestHeld(SimTable t) {
    final a = t.clients.first;
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.playing), limitMs: 5 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final held = a.botHolders(hand);
    final from = a.game.currentSeat!;
    final ahead = [for (var i = 0; i < seatCount; i++) (from + i) % seatCount].indexWhere(held.containsKey);
    expect(ahead, greaterThan(0), reason: 'a held seat that has not played yet');
    final seat = (from + ahead) % seatCount;
    return (hand: hand, seat: seat, holder: held[seat]!, turn: TurnId.play(hand, a.game.tricksPlayed * seatCount + ahead));
  }

  group('a held seat whose juror is gone at its turn', () {
    late SimTable t;
    late ({int hand, int seat, PublicKey holder, TurnId turn}) at;
    late List<Decision> record;

    setUpAll(() {
      t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
      t.start();
      at = soonestHeld(t);
      t.net.goOffline(at.holder);
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
          reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
      record = t.clients.first.record;
    });
    tearDownAll(() => t.stop());

    Iterable<TableClient> following() => [
          ...t.clients,
          for (final j in t.jurors)
            if (j.client != null && t.net.isUp(j.signer.publicKey)) j.client!,
        ];

    test('every record gives the seat to the escrow, once, at its turn', () {
      for (final c in following()) {
        final given = c.record.where((d) => d.removal && d.turn.hand == at.hand && d.event.seat == at.seat).toList();
        final who = c.signer.publicKey.substring(0, 4);
        expect(given.map((d) => (d.turn, d.event.kind)), [(at.turn, EventKind.escrow)], reason: 'at $who');
        expect(c.escrowedAt(at.hand), {at.seat: at.turn}, reason: 'at $who');
      }
      final people = t.clients.map((c) => c.record.map((d) => d.key).toList()).toList();
      expect(people.last, people.first, reason: 'one record');
    });

    test('another juror of the hand plays the seat from there', () {
      final jurors = {for (final d in t.clients.first.juries) if (d.event.hand == at.hand) ...d.event.jurors};
      final moves = record.where((d) => !d.removal && d.turn.hand == at.hand && d.turn.isPlay && d.event.seat == at.seat).toList();
      expect(moves.first.turn, at.turn, reason: 'the turn the escrow reopened is played');
      for (final d in moves) {
        expect(d.event.author, isNot(at.holder), reason: 'at ${d.turn}');
        expect(jurors, contains(d.event.author), reason: 'at ${d.turn}');
      }
    });

    test('its audit closes with nothing said, and the record checks out', () {
      for (final c in t.clients) {
        expect(c.record.where((d) => d.turn == TurnId.audit(at.hand, at.seat)), isEmpty);
        final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
        expect(v.ok && v.complete, isTrue, reason: v.reason);
      }
    });

    // What the record says is what the verifier holds the table to.
    Verification check(List<Decision> r) {
      final c = t.clients.first;
      return verifyRecord(t.spec, r, juries: c.juries, crypto: crypto, releases: c.releases);
    }

    int escrowAt() => record.indexWhere((d) => d.removal && d.event.kind == EventKind.escrow);

    Decision withEvent(Decision d, TableEvent e, {Set<PublicKey>? witnesses}) =>
        Decision(turn: d.turn, event: e, witnesses: witnesses ?? d.witnesses, removal: d.removal, among: d.among, verdict: d.verdict);

    test('the verifier turns down another juror playing the seat with no escrow on the record', () {
      final v = check([...record]..removeAt(escrowAt()));
      expect(v.ok, isFalse);
      expect(v.reason, contains('did not hold seat ${at.seat}'));
    });

    test('the verifier turns down an escrow claimed by someone not at the table', () {
      final i = escrowAt();
      final d = record[i];
      final juror = t.jurors.firstWhere((j) => j.signer.publicKey != at.holder).signer;
      final forged = TableEvent.sign(juror, table: t.spec.id, kind: EventKind.escrow, body: Map.of(d.event.body));
      final v = check([...record]..[i] = withEvent(d, forged));
      expect(v.ok, isFalse);
      expect(v.reason, contains('not at the table'));
    });

    test('the verifier turns down an escrow without a majority behind it', () {
      final i = escrowAt();
      final d = record[i];
      final v = check([...record]..[i] = withEvent(d, d.event, witnesses: {d.event.author}));
      expect(v.ok, isFalse);
      expect(v.reason, contains('without a majority'));
    });

    test('the verifier turns down an escrow of a person\'s seat', () {
      final i = escrowAt();
      final d = record[i];
      final person = [for (var s = 0; s < seatCount; s++) s].firstWhere((s) => t.spec.seats[s] is HumanSeat);
      final claim = t.clients.firstWhere((c) => c.signer.publicKey == d.event.author).signer;
      final e = TableEvent.sign(claim, table: t.spec.id, kind: EventKind.escrow, body: {...d.event.body, 'seat': person});
      final v = check([...record]..[i] = withEvent(d, e));
      expect(v.ok, isFalse);
      expect(v.reason, contains('a person\'s'));
    });

    test('the verifier turns down a held seat\'s audit missing where the record did not give the seat up', () {
      final other = t.clients.first.botHolders(at.hand).keys.firstWhere((s) => s != at.seat);
      final audit = record.indexWhere((d) => !d.removal && d.turn == TurnId.audit(at.hand, other));
      expect(audit, isNot(-1), reason: 'seat $other said its own audit');
      final v = check([...record]..removeAt(audit));
      expect(v.ok, isFalse, reason: 'seat $other opened from its pieces instead');
    });

    test('the verifier turns down a record that goes on past the end of the game', () {
      final v = check([...record, record.firstWhere((d) => d.turn.isPlay)]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('past the end'));
    });

    test('the verifier turns down a seat audited twice', () {
      expect(record.last.turn.isAudit, isTrue);
      final v = check([...record, record.last]);
      expect(v.ok, isFalse);
      expect(v.reason, contains('audited twice'));
    });

    test('the verifier turns down a seat given to the escrow twice', () {
      final i = escrowAt();
      final v = check([...record]..insert(i + 1, record[i]));
      expect(v.ok, isFalse);
      expect(v.reason, contains('twice'));
    });
  });

  // Its juror gone once it has played its last card, with nothing left
  // to say in the hand but its audit: the escrow is claimed at the
  // audit, and the seat's pieces, said in the open, are its account of
  // the hand. Every card it played was said by its own juror before
  // that, and is checked against the hand those pieces open.
  group('a held seat whose juror is gone at its audit', () {
    late SimTable t;
    late int hand, seat;
    late List<Decision> record;

    setUpAll(() {
      t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
      t.start();
      final a = t.clients.first;
      expect(
          t.clock.runUntil(() {
            if (a.game.phase != Phase.playing || a.game.tricksPlayed != 12) return false;
            final held = a.botHolders(a.game.handNumber);
            return a.game.trick.any((p) => held.containsKey(p.seat));
          }, limitMs: 10 * 60 * 1000),
          isTrue,
          reason: 'a held seat played to the last trick');
      hand = a.game.handNumber;
      final held = a.botHolders(hand);
      seat = a.game.trick.firstWhere((p) => held.containsKey(p.seat)).seat;
      t.net.goOffline(held[seat]!);
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
          reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
      record = a.record;
    });
    tearDownAll(() => t.stop());

    test('every record gives the seat to the escrow at its audit, and closes it with nothing said', () {
      for (final c in t.clients) {
        final at = c.record.where((d) => d.turn == TurnId.audit(hand, seat)).map((d) => (d.removal, d.event.kind));
        expect(at, [(true, EventKind.escrow)]);
      }
      final people = t.clients.map((c) => c.record.map((d) => d.key).toList()).toList();
      expect(people.last, people.first, reason: 'one record');
    });

    test('the record checks out, every card the seat played checked against the hand its pieces open', () {
      for (final c in t.clients) {
        final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
        expect(v.ok && v.complete, isTrue, reason: v.reason);
      }
    });

    test('the verifier turns down the record without the escrow: pieces are no substitute for the audit', () {
      final c = t.clients.first;
      final v = verifyRecord(t.spec, [...record]..removeWhere((d) => d.removal && d.event.kind == EventKind.escrow),
          juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok, isFalse);
    });
  });

  // The audit of a seat the record gave to the escrow is its pieces,
  // said in the open, and nobody's move. Its juror, slow rather than
  // gone, says its own audit before it knows; held back until after
  // the escrow, and reaching the people while the pieces are still on
  // their way, it would be taken and witnessed where the rest of the
  // table closed the turn from the pieces.
  test('a held seat\'s own audit said too late is not taken once the record has given the seat to the escrow', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final a = t.clients.first;
    expect(
        t.clock.runUntil(() {
          if (a.game.phase != Phase.playing || a.game.tricksPlayed != 12) return false;
          final held = a.botHolders(a.game.handNumber);
          return a.game.trick.any((p) => held.containsKey(p.seat));
        }, limitMs: 10 * 60 * 1000),
        isTrue);
    final hand = a.game.handNumber;
    final held = a.botHolders(hand);
    final seat = a.game.trick.firstWhere((p) => held.containsKey(p.seat)).seat;
    final holder = held[seat]!;
    final people = {for (final c in t.clients) c.signer.publicKey};
    // Its audit held back twenty seconds, past the escrow claimed at
    // ten; the seat's pieces kept from the people until four seconds
    // after that.
    int? said;
    TableEvent? audit;
    t.net.steer = (from, to, message) {
      final body = message['body'] as Map<String, Object?>;
      if (message['kind'] == 'deal' && from == holder && body['round'] == 4) {
        audit ??= TableEvent.parse(message);
        said ??= t.clock.nowMs;
        return said! + 20000 - t.clock.nowMs;
      }
      if (message['kind'] == 'release' && body['about'] == seat && people.contains(to) && said != null) {
        final until = said! + 24000;
        return t.clock.nowMs < until ? until - t.clock.nowMs : null;
      }
      return null;
    };
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
    expect(said, isNotNull, reason: 'the juror said its audit');
    for (final c in t.clients) {
      final at = c.record.where((d) => d.turn == TurnId.audit(hand, seat)).map((d) => (d.removal, d.event.kind));
      expect(at, [(true, EventKind.escrow)], reason: 'the escrow, and nothing said');
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    // And a record that took it anyway, witnessed by both, is turned
    // down: the audit is the true secret, and still not the seat's to
    // say once the record gave it up.
    final c = t.clients.first;
    final i = c.record.indexWhere((d) => d.turn == TurnId.audit(hand, seat));
    final escrow = c.record[i];
    final taken = [...c.record]
      ..insert(i + 1, Decision(turn: escrow.turn, event: audit!, witnesses: people, among: escrow.among));
    final v = verifyRecord(t.spec, taken, juries: c.juries, crypto: crypto, releases: c.releases);
    expect(v.ok, isFalse);
    expect(v.reason, contains('gave to the escrow'));
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // And one already heard when the record gives the seat up: three
  // people, the juror's audit reaching b and nobody else, and a and c
  // giving the seat to the escrow between them. At b the audit is in
  // the turn the escrow reopens, and it is not a move there any more
  // than one arriving later: kept, it would wait for witnesses a and c
  // will never give, since they close the turn from the pieces.
  test('a held seat\'s audit one person holds when the rest give the seat to the escrow closes from the pieces there too', () {
    final t = SimTable(humans: 3, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final a = t.clients.first;
    final b = t.clients.elementAt(1);
    expect(t.clock.runUntil(() => a.botHolders(a.game.handNumber).isNotEmpty, limitMs: 5 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final MapEntry(key: seat, value: holder) = a.botHolders(hand).entries.single;
    var toB = 0;
    t.net.steer = (from, to, message) {
      final body = message['body'] as Map<String, Object?>;
      if (message['kind'] != 'deal' || message['author'] != holder || body['round'] != 4) return null;
      if (to != b.signer.publicKey) return -1;
      toB++;
      return null;
    };
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
    expect(toB, greaterThan(0), reason: 'b had the juror\'s audit');
    for (final c in t.clients) {
      final at = c.record.where((d) => d.turn == TurnId.audit(hand, seat)).map((d) => (d.removal, d.event.kind));
      expect(at, [(true, EventKind.escrow)], reason: 'the escrow, and nothing said');
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
      expect(c.record.map((d) => d.key).toList(), a.record.map((d) => d.key).toList(), reason: 'one record');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A split at a held seat's deal step: its keys reach one person and
  // not the other, who claims the seat for the escrow. The jury rules
  // for the keys — the juror is heard, and said them — and every side
  // takes that ruling, as it would a ruling for a card.
  test('a held seat\'s keys one person heard and the other did not are ruled for by the jury, on both records', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final a = t.clients.first;
    final b = t.clients.last;
    expect(t.clock.runUntil(() => a.botHolders(a.game.handNumber).isNotEmpty, limitMs: 5 * 60 * 1000), isTrue);
    final hand = a.game.handNumber;
    final MapEntry(key: seat, value: holder) = a.botHolders(hand).entries.first;
    final until = t.clock.nowMs + 15000;
    t.net.steer = (from, to, message) {
      final body = message['body'] as Map<String, Object?>;
      // Every copy, whoever passes it on: the people say an unsettled
      // step again too.
      final keys = message['kind'] == 'deal' && message['author'] == holder && body['round'] == 0 && body['seat'] == seat;
      return keys && to == a.signer.publicKey && t.clock.nowMs < until ? -1 : null;
    };
    final claimed = <String>{};
    t.net.swallow = (from, message) {
      if (message['kind'] == 'escrow') claimed.add(from);
      return false;
    };
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 10 * 60 * 1000), isTrue,
        reason: 'the game was played out:\n${t.clients.map((c) => c.describe()).join('\n')}');
    expect(claimed, contains(a.signer.publicKey), reason: 'a claimed the escrow');
    final keys = a.record.firstWhere((d) => d.turn == TurnId.deal(hand, 0, seat));
    expect(keys.removal, isFalse);
    expect(keys.verdict, isNotNull, reason: 'the jury ruled for the keys');
    expect(a.escrowedAt(hand), isEmpty);
    expect(b.record.map((d) => d.key).toList(), a.record.map((d) => d.key).toList(), reason: 'one record');
    for (final c in [a, b]) {
      final v = verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // At a seed where the juror sorts first in the escrow's order, so
  // that the first of the jurors still about is the very one the seat
  // was taken from, unless the order leaves it to last.
  test('a held seat whose juror is heard but too slow goes to the escrow at its turn, and another juror plays it', () {
    final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final at = soonestHeld(t);
    final order = t.clients.first.juries.firstWhere((d) => d.event.hand == at.hand).event.jurors.toList()..sort();
    expect(order.first, at.holder, reason: 'the seat\'s juror is first in the escrow\'s order');
    // Its moves for the seat never leave; everything else of it does.
    var heard = 0;
    t.net.steer = (from, to, message) {
      if (from != at.holder) return null;
      if (message['kind'] == 'heartbeat' || message['kind'] == 'serve') heard++;
      if (message['kind'] != 'play' || (message['body'] as Map<String, Object?>)['seat'] != at.seat) return null;
      return -1;
    };
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.tricksPlayed >= 1), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table moved past the seat:\n${t.clients.map((c) => c.describe()).join('\n')}');
    expect(heard, greaterThan(0), reason: 'the juror was heard from all along');
    for (final c in t.clients) {
      expect(c.escrowedAt(at.hand), {at.seat: at.turn});
      final move = c.record.firstWhere((d) => !d.removal && d.turn == at.turn);
      expect(move.event.author, isNot(at.holder), reason: 'the escrow played it, not the juror it was taken from');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  // The seat's own juror is left to last among those who say the
  // escrow's moves, not left out: when it is the one juror back, the
  // seat is its to play or nobody's. Three people and one bot seat, so
  // that no other held seat needs a juror that is not back.
  test('a held seat\'s own juror, the one juror back, plays the seat on as the escrow\'s', () {
    final t = SimTable(humans: 3, seed: 9, crypto: crypto, jurors: jurySize);
    t.start();
    final c = t.clients.first;
    expect(t.clock.runUntil(() => t.clients.every((c) => c.game.phase == Phase.playing), limitMs: 5 * 60 * 1000), isTrue);
    final hand = c.game.handNumber;
    final held = c.botHolders(hand);
    expect(held, hasLength(1));
    final MapEntry(key: seat, value: holder) = held.entries.single;
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    expect(t.clock.runUntil(() => c.escrowedAt(hand).containsKey(seat), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the seat went to the escrow while the jury was away:\n${c.describe()}');
    t.net.comeOnline(holder);
    expect(t.clock.runUntil(() => c.game.handNumber > hand || c.game.tricksPlayed == 13, limitMs: 5 * 60 * 1000), isTrue,
        reason: 'the hand was played out:\n${c.describe()}');
    final after = c.record.where((d) => !d.removal && d.turn.hand == hand && d.turn.isPlay && d.event.seat == seat).where((d) =>
        d.turn.index > c.escrowedAt(hand)[seat]!.index);
    expect(after, isNotEmpty, reason: 'the seat had turns after the one it was given up at');
    for (final d in after) {
      expect(d.event.author, holder, reason: 'at ${d.turn}');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A turn that holds both the escrow and a move after it can settle
  // by the move first where the claims come late: three people, a and
  // b carrying the escrow between them and then backing the juror's
  // card, which lands after it; c, whose copies of their claims are
  // held back, holding the card and their backing for it first. The
  // claims that come after are taken all the same, and c's record is
  // theirs.
  test('an escrow carried elsewhere is taken where its turn settled by the move first', () {
    final t = SimTable(humans: 3, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final a = t.clients.first;
    final c = t.clients.last;
    final at = soonestHeld(t);
    // The seat's juror the one juror up, so that the card it said is
    // the only one the seat will have.
    for (final j in t.jurors) {
      if (j.signer.publicKey != at.holder) t.net.goOffline(j.signer.publicKey);
    }
    final claims = <String>{};
    int? cardAt, claimsUntil;
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'] as Map<String, Object?>;
      if (kind == 'play' && message['author'] == at.holder && body['hand'] == at.hand && body['seat'] == at.seat) {
        cardAt ??= t.clock.nowMs + 6000;
        return t.clock.nowMs < cardAt! ? cardAt! - t.clock.nowMs : null;
      }
      if (kind == 'escrow') {
        claims.add(message['id'] as String);
        claimsUntil ??= t.clock.nowMs + 12000;
      } else if (kind != 'witness' || !claims.contains(body['event'])) {
        return null;
      }
      if (to != c.signer.publicKey || from == c.signer.publicKey || t.clock.nowMs >= claimsUntil!) return null;
      return claimsUntil! - t.clock.nowMs;
    };
    final lines = <String>[];
    c.log = lines.add;
    expect(t.clock.runUntil(() => t.clients.every((x) => x.game.tricksPlayed >= 1), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table moved past the seat:\n${t.clients.map((x) => x.describe()).join('\n')}');
    t.clock.advance(15000);
    expect(lines.any((l) => l.contains('settled ${at.turn} play')), isTrue);
    final settledFirst = lines.indexWhere((l) => l.contains('settled ${at.turn} play'));
    final givenAfter = lines.indexWhere((l) => l.contains('bot seat ${at.seat} to the escrow at ${at.turn}'));
    expect(givenAfter, greaterThan(settledFirst), reason: 'c settled the card first, and took the escrow after');
    for (final x in t.clients) {
      expect(x.escrowedAt(at.hand), {at.seat: at.turn}, reason: 'at ${x.signer.publicKey.substring(0, 4)}');
      final upTo = x.record.where((d) => d.turn.hand == at.hand && d.turn.index <= at.turn.index).map((d) => d.key).toList();
      expect(upTo, a.record.where((d) => d.turn.hand == at.hand && d.turn.index <= at.turn.index).map((d) => d.key).toList(),
          reason: 'one record as far as the seat\'s turn');
      final v = verifyRecord(t.spec, x.record, allowPartial: true, juries: x.juries, crypto: crypto, releases: x.releases);
      expect(v.ok, isTrue, reason: v.reason);
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));

  // A custodian says the seat's move once the escrow is carried where
  // it is, and that can be before it is carried somewhere else. There
  // the move is by a juror the seat is not yet given to, so it is kept
  // until the escrow comes — not taken as the seat's own, which would
  // settle the turn with no escrow in that side's record, and not
  // dropped, which would leave that side unable to take it up again.
  test('a custodian\'s move that arrives before the escrow is kept, and taken once the escrow is carried', () {
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: jurySize + 2, target: 1);
    t.start();
    final a = t.clients.first;
    final b = t.clients.last;
    final at = soonestHeld(t);
    t.net.goOffline(at.holder);
    final lines = <String>[];
    b.log = lines.add;
    // Every claim for the escrow, and every witness to one, kept from
    // b for ten seconds from the first.
    final claims = <String>{};
    int? until;
    t.net.steer = (from, to, message) {
      final kind = message['kind'];
      final body = message['body'] as Map<String, Object?>;
      if (kind == 'escrow') {
        claims.add(message['id'] as String);
        until ??= t.clock.nowMs + 10000;
      } else if (kind != 'witness' || !claims.contains(body['event'])) {
        return null;
      }
      if (to != b.signer.publicKey || t.clock.nowMs >= until!) return null;
      return until! - t.clock.nowMs;
    };
    expect(t.clock.runUntil(() => [a, b].every((c) => c.game.tricksPlayed >= 1), limitMs: 3 * 60 * 1000), isTrue,
        reason: 'the table moved past the seat:\n${a.describe()}\n${b.describe()}');
    final move = b.record.firstWhere((d) => !d.removal && d.turn == at.turn).event;
    final author = move.author.substring(0, 4);
    final kept = lines.indexWhere((l) => l.contains('defer play@${at.turn} from $author'));
    final given = lines.indexWhere((l) => l.contains('bot seat ${at.seat} to the escrow at ${at.turn}'));
    expect(kept, isNot(-1), reason: 'the move reached b first, and was kept');
    expect(given, greaterThan(kept), reason: 'then the escrow');
    expect(b.escrowedAt(at.hand), a.escrowedAt(at.hand));
    expect(b.record.map((d) => d.key).toList(), a.record.map((d) => d.key).toList(), reason: 'one record');
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
