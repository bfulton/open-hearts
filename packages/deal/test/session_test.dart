/// A whole hand's deal among four sessions in one process — two people
/// and two bots, then four people — the way the table will drive it:
/// keys, shuffles in order, tokens, hands; a pass; plays each opened
/// for all; one seat gone and its hand rebuilt from escrowed shares;
/// the audit.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto d;
  setUpAll(() async => d = await DealCrypto.load());

  /// Delivers a message to every session but the sender's.
  void broadcast(List<DealSession> all, int from, bool Function(DealSession) accept) {
    for (var s = 0; s < all.length; s++) {
      if (s == from) continue;
      expect(accept(all[s]), isTrue, reason: 'session $s refused a message from $from');
    }
  }

  DealSession make(List<DealSeat> seats, int? seat, {List<Uint8List> custodians = const [], int seed = 1}) => DealSession(
        d,
        tableId: 'T1',
        tableSeed: 77,
        hand: 2,
        seats: seats,
        mySeat: seat,
        custodians: custodians,
        random: Random(seed * 100 + (seat ?? 99)),
      );

  /// Runs the deal to dealt hands; returns the sessions by seat (a
  /// bot seat's entry follows the table without a seat, as a juror
  /// would).
  List<DealSession> dealOut(List<DealSeat> seats, {List<Uint8List> custodians = const []}) {
    final all = [for (var s = 0; s < 4; s++) make(seats, seats[s] is HumanDealSeat ? s : null, custodians: custodians)];
    final humans = [for (var s = 0; s < 4; s++) if (seats[s] is HumanDealSeat) s];
    for (final h in humans) {
      broadcast(all, h, (x) => x.acceptKeys(all[h].myKeys()!));
    }
    for (final x in all) {
      expect(x.phase, DealPhase.shuffles, reason: 'every key in');
    }
    // Shuffles in seat order: a person's when it is next, a bot's by all.
    for (var s = 0; s < 4; s++) {
      if (seats[s] is! HumanDealSeat) continue;
      expect(all[s].nextShuffler, s, reason: 'seat $s is next');
      final m = all[s].myShuffle()!;
      broadcast(all, s, (x) => x.acceptShuffle(m));
    }
    for (final x in all) {
      expect(x.deck, isNotNull);
    }
    for (final h in humans) {
      final m = all[h].myTokens()!;
      broadcast(all, h, (x) => x.acceptTokens(m));
    }
    for (final x in all) {
      expect(x.phase, DealPhase.dealt);
    }
    return all;
  }

  test('two people and two bots: each person sees its own hand and the bots\', not the other person\'s', () {
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const BotDealSeat(), const BotDealSeat()];
    final all = dealOut(seats);
    final a = all[0].handOf(0)!;
    expect(a.length, 13);
    expect(all[0].handOf(1), isNull, reason: 'the other person\'s hand is closed');
    expect(all[0].handOf(2), isNotNull, reason: 'a bot\'s hand is open to all');
    expect(all[1].handOf(2), all[0].handOf(2));
    expect(all[1].handOf(0), isNull);
    final b = all[1].handOf(1)!;
    expect({...a, ...b, ...all[0].handOf(2)!, ...all[0].handOf(3)!}.length, 52, reason: 'one deck, dealt once');
  });

  test('a pass carries cards across, a play opens one for all, a leaver\'s hand is rebuilt, the audit opens everything', () {
    final seats = [for (final k in ['a', 'b', 'c', 'd']) HumanDealSeat(k)];
    final custodianSecret = Uint8List(32)..[0] = 42;
    final custodianPk = d.keygen(custodianSecret);
    final all = dealOut(seats, custodians: [custodianPk]);
    for (var s = 0; s < 4; s++) {
      final m = all[s].myShares()!;
      broadcast(all, s, (x) => x.acceptShares(m));
      all[s].acceptShares(m); // the sender keeps its own as sent too
    }
    // Seat 0 passes three cards to seat 1 (left).
    final before = all[0].handOf(0)!;
    final positions = [0, 5, 12];
    final passed = [for (final p in positions) all[0].cardAt(p)!];
    final pass = all[0].passMessage(1, positions)!;
    broadcast(all, 0, (x) => x.acceptPass(pass));
    all[0].acceptPass(pass);
    expect(all[0].handOf(0)!.length, 10);
    expect(all[1].handOf(1)!.length, 16, reason: 'seat 1 opened the three it was passed');
    for (final c in passed) {
      expect(all[1].handOf(1), contains(c));
      expect(before, contains(c));
    }
    expect(all[2].handOf(1), isNull, reason: 'a third seat still sees nothing of seat 1');
    // Seat 1 plays one of the passed cards: the token that opens it is
    // seat 0's, which seat 1 holds.
    final play = all[1].playToken(positions[0])!;
    for (var s = 0; s < 4; s++) {
      if (s == 1) continue;
      expect(all[s].acceptPlay(1, play), passed[0], reason: 'seat $s opened the play');
    }
    expect(all[2].acceptPlay(1, {'position': 13, 'token': play['token']}), isNull, reason: 'a token is for its position alone');
    // Seat 2 plays one of its own.
    final own = all[2].positionOf(2, all[2].handOf(2)!.first)!;
    final play2 = all[2].playToken(own)!;
    for (var s = 0; s < 4; s++) {
      if (s == 2) continue;
      expect(all[s].acceptPlay(2, play2), all[2].handOf(2)!.first);
    }
    // Seat 3 leaves. The others release their shares of its secret,
    // and the custodian its; then seat 3's hand is open everywhere.
    final custody = DealSession.custodyShare(d, all[3].myShares()!, custodianSecret, all[3].pkOf(3)!, 2, 0)!;
    final releases = [for (final s in [0, 1, 2]) all[s].releaseShare(3)!];
    for (final s in [0, 1, 2]) {
      expect(all[s].handOf(3), isNull);
      for (final r in releases) {
        all[s].acceptRelease(r);
      }
      expect(all[s].handOf(3), isNull, reason: 'three seats\' shares alone open nothing');
      expect(all[s].acceptRelease({'about': 3, 'holder': -1, 'share': base64Of(custody)}), isTrue);
      expect(all[s].handOf(3), isNotNull, reason: 'with the custodian\'s, the hand is open');
      expect(all[s].handOf(3), all[3].handOf(3));
    }
    // The audit: every secret, every card.
    for (var s = 0; s < 3; s++) {
      final m = all[s].myAudit()!;
      broadcast(all, s, (x) => x.acceptAudit(m));
    }
    for (final s in [0, 1, 2]) {
      expect(all[s].phase, DealPhase.audited);
      expect(all[s].fullDeal, isNotNull);
      expect(all[s].fullDeal, all[0].fullDeal);
    }
    expect(all[0].acceptAudit({'seat': 1, 'secret': base64Of(Uint8List(32))}), isTrue, reason: 'a second audit for a seat is ignored');
  });
}

String base64Of(Uint8List b) => base64Encode(b);
