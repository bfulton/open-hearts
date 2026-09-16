/// A whole hand's deal among four sessions in one process — two people
/// and two bots, then four people — the way the table will drive it:
/// keys with their escrow, shuffles in order, tokens, hands, the lead
/// declared; a pass; plays each opened for all; a seat gone and its
/// hand rebuilt from the pieces the others and a juror hold; the audit;
/// and a verifier's session that saw only the messages.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deal/deal.dart';
import 'package:test/test.dart';

/// The simulator's shared secret: a hash of the two keys, symmetric.
Uint8List Function(String) wrapFor(String me) => (other) {
      final pair = [me, other]..sort();
      return Uint8List.fromList(sha256.convert(utf8.encode('fake-shared:${pair[0]}|${pair[1]}')).bytes);
    };

const leadCard = 0; // the deck index the lead card has, whatever it is

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

  DealSession make(List<DealSeat> seats, int? seat,
          {String? key, List<String> custodians = const [], int seed = 1, bool verifier = false}) =>
      DealSession(
        d,
        tableId: 'T1',
        tableSeed: 77,
        hand: 2,
        seats: seats,
        leadCard: leadCard,
        mySeat: seat,
        myKey: key ?? (seat == null ? null : (seats[seat] as HumanDealSeat).key),
        wrap: verifier ? null : wrapFor(key ?? (seat == null ? 'nobody' : (seats[seat] as HumanDealSeat).key)),
        custodians: custodians,
        random: Random(seed * 100 + (seat ?? 99)),
      );

  /// Runs the deal to dealt hands, the lead declared; returns the
  /// sessions by seat (a bot seat's entry follows without a seat, as
  /// a juror would), plus any [extra] followers to keep in step.
  List<DealSession> dealOut(List<DealSeat> seats, {List<String> custodians = const [], List<DealSession> extra = const []}) {
    final all = [
      for (var s = 0; s < 4; s++) make(seats, seats[s] is HumanDealSeat ? s : null, custodians: custodians),
      ...extra,
    ];
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
      expect(x.phase, DealPhase.declare);
    }
    for (final h in humans) {
      final m = all[h].myDeclaration()!;
      broadcast(all, h, (x) => x.acceptDeclaration(m));
    }
    for (final x in all) {
      expect(x.phase, DealPhase.dealt);
      expect(x.leader, isNotNull, reason: 'the lead card was found');
      expect(x.leader, all.first.leader);
    }
    return all;
  }

  test('a seat that says it holds the lead card nowhere: the deal says so, and the audit says which', () {
    // Four people, every one of whom declares the lead card nowhere.
    // Three of them are telling the truth.
    final seats = [for (var s = 0; s < 4; s++) HumanDealSeat('p$s')];
    final all = [for (var s = 0; s < 4; s++) make(seats, s)];
    for (var s = 0; s < 4; s++) {
      broadcast(all, s, (x) => x.acceptKeys(all[s].myKeys()!));
    }
    for (var s = 0; s < 4; s++) {
      final m = all[s].myShuffle()!;
      broadcast(all, s, (x) => x.acceptShuffle(m));
    }
    for (var s = 0; s < 4; s++) {
      final m = all[s].myTokens()!;
      broadcast(all, s, (x) => x.acceptTokens(m));
    }
    // Which seat was dealt the card, for the test to check against
    // afterwards; nobody at the table can see this yet.
    final dealt = [for (var s = 0; s < 4; s++) s].firstWhere((s) => all[s].handOf(s)!.contains(leadCard));
    for (var s = 0; s < 4; s++) {
      final honest = all[s].myDeclaration()!;
      expect(honest['position'] == -1, s != dealt, reason: 'only the seat holding it has anything to declare');
      broadcast(all, s, (x) => x.acceptDeclaration({'seat': s, 'position': -1}));
      expect(all[s].acceptDeclaration({'seat': s, 'position': -1}), isTrue, reason: 'and it takes its own word too');
    }

    for (var s = 0; s < 4; s++) {
      expect(all[s].leadDisclaimed, isTrue, reason: 'nobody claims the card');
      expect(all[s].awaitsAnySecret, isFalse, reason: 'and nobody is owed a hand from escrow');
      // Only the seat that lied can see the card, in its own hand. To
      // everyone else the hand is simply unleadable.
      expect(all[s].leader, s == dealt ? dealt : isNull);
      expect(all[s].lied, s == dealt ? dealt : isNull);
    }

    // The audit opens every hand, and then the deal names the seat: it
    // was dealt the card and said it held it nowhere.
    for (var s = 0; s < 4; s++) {
      final m = all[s].myAudit()!;
      broadcast(all, s, (x) => x.acceptAudit(m));
    }
    for (var s = 0; s < 4; s++) {
      expect(all[s].fullDeal, isNotNull, reason: 'every card is open');
      expect(all[s].lied, dealt);
      expect(all[s].leader, dealt, reason: 'and it could have led all along');
    }
  });

  test('four true words and a hand that leads itself: a bot holding the card is not a lie', () {
    // Two people and two bots, dealt until somebody leads. Where the
    // card fell to a bot, both people say "not me" and mean it: every
    // word on the lead card is a disclaimer and the hand leads anyway,
    // off a hand that is open to everybody.
    for (var seed = 1; seed <= 6; seed++) {
      final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const BotDealSeat(), const BotDealSeat()];
      final all = [for (var s = 0; s < 4; s++) make(seats, seats[s] is HumanDealSeat ? s : null, seed: seed)];
      for (final h in [0, 1]) {
        broadcast(all, h, (x) => x.acceptKeys(all[h].myKeys()!));
      }
      for (final h in [0, 1]) {
        final m = all[h].myShuffle()!;
        broadcast(all, h, (x) => x.acceptShuffle(m));
      }
      for (final h in [0, 1]) {
        final m = all[h].myTokens()!;
        broadcast(all, h, (x) => x.acceptTokens(m));
      }
      for (final h in [0, 1]) {
        final m = all[h].myDeclaration()!;
        broadcast(all, h, (x) => x.acceptDeclaration(m));
        expect(all[h].acceptDeclaration(m), isTrue);
      }
      for (final x in all) {
        expect(x.leader, isNotNull, reason: 'somebody leads, whoever was dealt it');
        expect(x.lied, isNull, reason: 'and nobody said otherwise');
        expect(x.leadDisclaimed, x.leader! >= 2,
            reason: 'both people disclaim it exactly when a bot holds it, and are right to');
      }
    }
  });

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
    // The lead: whoever holds it, everyone agrees where.
    final holder = all[0].leader!;
    if (seats[holder] is HumanDealSeat) {
      expect(all[holder].handOf(holder), contains(leadCard));
    } else {
      expect(all[0].handOf(holder), contains(leadCard));
    }
  });

  test('a pass carries cards across, a play opens one for all, a leaver\'s hand is rebuilt, the audit opens everything', () {
    final seats = [for (final k in ['a', 'b', 'c', 'd']) HumanDealSeat(k)];
    final juror = make(seats, null, key: 'juror');
    final all = dealOut(seats, custodians: ['juror', 'other-juror'], extra: [juror]);
    expect(juror.handOf(0), isNull, reason: 'a juror sees nothing');
    // Seat 0 passes three cards to seat 1 (left).
    final before = all[0].handOf(0)!;
    final positions = [0, 5, 12];
    final passed = [for (final p in positions) all[0].openedCardAt(p)!];
    final pass = all[0].passMessage(1, positions)!;
    expect(pass['sealed'], isNotNull, reason: 'sealed to a person');

    // A seal is for one seat's eyes, and every seat checks it all the
    // same: the argument beside it says what is in there without
    // opening it (docs/03-fair-deal.md). A passer that seals the
    // receiver something else is refused here, by everybody, rather
    // than leaving the receiver with three cards it cannot play and
    // nobody else able to say whose fault that was.
    final bent = {
      ...pass,
      'sealed': [
        for (final (i, s) in (pass['sealed']! as List).indexed)
          if (i == 1) base64.encode(List.filled(sealedBytes + sealProofBytes, 9)) else s as String,
      ],
    };
    for (final x in all) {
      expect(x.verifyPass(bent), isFalse, reason: 'a seal of nothing, refused by every side');
      expect(x.acceptPass(bent), isFalse);
    }
    final elsewhere = {...pass, 'to': 2};
    for (final x in all) {
      expect(x.verifyPass(elsewhere), isFalse, reason: 'and a seal is bound to the seat it was for');
    }

    broadcast(all, 0, (x) => x.acceptPass(pass));
    all[0].acceptPass(pass);
    expect(all[0].handOf(0)!.length, 10);
    expect(all[1].handOf(1)!.length, 16, reason: 'seat 1 opened the three it was passed');
    for (final c in passed) {
      expect(all[1].handOf(1), contains(c));
      expect(before, contains(c));
    }
    expect(all[2].handOf(1), isNull, reason: 'a third seat still sees nothing of seat 1');
    expect(all[2].handSizeOf(1), 16);
    // Seat 1 plays one of the passed cards: the token that opens it is
    // seat 0's, which seat 1 holds.
    final play = all[1].playToken(positions[0])!;
    for (final x in all) {
      if (x == all[1]) continue;
      expect(x.acceptPlay(1, play), passed[0], reason: 'everyone opened the play');
    }
    expect(all[2].acceptPlay(1, {'position': 13, 'token': play['token']}), isNull, reason: 'a token is for its position alone');
    // Seat 2 plays one of its own.
    final own = all[2].positionOf(2, all[2].handOf(2)!.first)!;
    final play2 = all[2].playToken(own)!;
    for (final x in all) {
      if (x == all[2]) continue;
      expect(x.acceptPlay(2, play2), all[2].handOf(2)!.first);
    }
    // Seat 3 leaves. Any one seat's piece and any one juror's rebuild
    // its secret; either alone opens nothing.
    for (final x in all) {
      x.seatLeft(3);
      expect(x.awaitsSecret(3), x != all[3], reason: 'awaited everywhere but where it is known');
    }
    expect(all[0].releaseShare(3), isNotNull);
    expect(all[0].releaseShare(2), isNull, reason: 'seat 2 is still here');
    expect(juror.releaseShare(3), isNotNull);
    final fromSeat = all[0].releaseShare(3)!;
    final fromJuror = juror.releaseShare(3)!;
    // A bystander with no piece of its own: a seat's piece alone opens
    // nothing, and neither does a juror's; the two together do.
    final watcher = make(seats, null, key: 'watcher');
    final byMessage = dealOut(seats, custodians: ['juror', 'other-juror'], extra: [watcher]);
    watcher.seatLeft(3);
    byMessage[0].seatLeft(3);
    expect(watcher.acceptRelease(byMessage[0].releaseShare(3)!), isTrue);
    expect(watcher.handOf(3), isNull, reason: 'a seat\'s piece alone opens nothing');
    // Seat 2 holds a seat piece of its own; another seat's adds nothing.
    expect(all[2].acceptRelease(fromSeat), isTrue);
    expect(all[2].handOf(3), isNull, reason: 'two seats\' pieces, no juror\'s: nothing');
    expect(all[2].acceptRelease(fromJuror), isTrue);
    expect(all[2].handOf(3), isNotNull, reason: 'with a juror\'s, the hand is open');
    expect(all[2].handOf(3), all[3].handOf(3));
    expect(all[1].acceptRelease(fromJuror), isTrue);
    expect(all[1].handOf(3), all[3].handOf(3), reason: 'its own seat piece and the juror\'s');
    expect(all[2].acceptRelease({'about': 3, 'holder': 'stranger', 'share': base64Encode(Uint8List(32))}), isFalse);
    expect(all[2].acceptRelease({'about': 2, 'holder': 'a', 'share': base64Encode(Uint8List(32))}), isFalse,
        reason: 'nothing is released for a seat still here');
    // Seat 3 was dealt a lead? Whatever it held, everyone now sees it.
    expect(all[0].acceptRelease(fromJuror), isTrue);
    expect(all[0].acceptRelease(fromSeat), isTrue);
    expect(juror.acceptRelease(fromSeat), isTrue);
    expect(juror.handOf(3), all[3].handOf(3), reason: 'the juror too, once a seat released');
    // The bot in seat 3 plays: no message, the position is spent.
    final botCard = all[0].handOf(3)!.first;
    final botPos = all[0].positionOf(3, botCard)!;
    for (final x in all) {
      expect(x.playOpen(3, botPos), isTrue);
    }
    expect(all[0].handSizeOf(3), 12);
    // The audit: every secret, every card; the survivors vouch for
    // seat 3's, which they rebuilt.
    final verifier = make(seats, null, verifier: true);
    for (final s in [0, 1, 2]) {
      final m = all[s].myAudit()!;
      expect((m['known'] as Map).keys, ['3']);
      broadcast(all, s, (x) => x.acceptAudit(m));
      expect(verifier.acceptAudit(m), isFalse, reason: 'a verifier that saw no keys has nothing to check against');
    }
    for (final s in [0, 1, 2]) {
      expect(all[s].phase, DealPhase.audited);
      expect(all[s].fullDeal, isNotNull);
      expect(all[s].fullDeal, all[0].fullDeal);
    }
    expect(juror.fullDeal, all[0].fullDeal);
    expect(all[0].acceptAudit({'seat': 1, 'secret': base64Encode(Uint8List(32))}), isFalse,
        reason: 'a wrong secret is refused, for a seat already known too');
    expect(all[0].acceptAudit(all[1].myAudit()!), isTrue, reason: 'the true one again is fine');
  });

  test('a verifier that saw every message ends with the whole deal, and refuses what does not verify', () {
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const HumanDealSeat('c'), const BotDealSeat()];
    final verifier = make(seats, null, verifier: true);
    final all = dealOut(seats, custodians: ['juror'], extra: [verifier]);
    expect(verifier.handOf(3), isNotNull, reason: 'the bot\'s hand is public');
    expect(verifier.handOf(0), isNull);
    // A pass in the clear, to the bot.
    final positions = [for (var p = 26; p < 29; p++) p];
    final toBot = all[2].passMessage(3, positions)!;
    expect(toBot['tokens'], isNotNull, reason: 'in the clear to a bot');
    broadcast(all, 2, (x) => x.acceptPass(toBot));
    all[2].acceptPass(toBot);
    expect(verifier.handOf(3)!.length, 16, reason: 'everyone opened what the bot was passed');
    // Tampered messages are refused.
    final bad = Map<String, Object?>.from(toBot)..['positions'] = [26, 27, 28, 29];
    expect(verifier.acceptPass(bad), isFalse);
    expect(verifier.acceptDeclaration({'seat': 0, 'position': 1, 'token': base64Encode(Uint8List(tokenBytes))}), isTrue,
        reason: 'already declared: the second word is ignored');
    // The audit reaches the verifier, and only true secrets count.
    for (var s = 0; s < 3; s++) {
      final m = all[s].myAudit()!;
      final forged = Map<String, Object?>.from(m)..['secret'] = base64Encode(Uint8List(32)..[0] = 9);
      expect(verifier.acceptAudit(forged), isFalse);
      broadcast(all, s, (x) => x.acceptAudit(m));
    }
    expect(verifier.fullDeal, all[0].fullDeal);
    expect(verifier.phase, DealPhase.audited);
  });

  test('a seat that leaves before its keys is a bot from there, and one that leaves mid-deal is rebuilt mid-deal', () {
    final seats = [for (final k in ['a', 'b', 'c', 'd']) HumanDealSeat(k)];
    final juror = make(seats, null, key: 'juror');
    final all = [for (var s = 0; s < 4; s++) make(seats, s, custodians: ['juror']), juror];
    // Seats 0 and 1 send keys; seat 3 leaves before its keys, and is
    // out of the conversation from there: its own session, which knew
    // a secret nobody else will, is no longer anyone's peer.
    for (final h in [0, 1]) {
      broadcast(all, h, (x) => x.acceptKeys(all[h].myKeys()!));
    }
    all.removeAt(3);
    for (final x in all) {
      x.seatLeft(3);
      expect(x.awaitsSecret(3), isFalse, reason: 'a bot now, with a bot\'s secret');
      expect(x.hasKeys(3), isTrue);
    }
    broadcast(all, 2, (x) => x.acceptKeys(all[2].myKeys()!));
    for (final x in all) {
      expect(x.phase, DealPhase.shuffles);
    }
    // Seat 0 shuffles; then seat 1 leaves before its shuffle: its
    // secret must be rebuilt before the deal can go on.
    final s0 = all[0].myShuffle()!;
    broadcast(all, 0, (x) => x.acceptShuffle(s0));
    all.removeAt(1);
    for (final x in all) {
      x.seatLeft(1);
      expect(x.nextShuffler, 1);
      expect(x.awaitsSecret(1), isTrue);
    }
    final rel = [all[1].releaseShare(1)!, juror.releaseShare(1)!]; // all[1] is seat 2 now
    for (final x in all) {
      for (final r in rel) {
        x.acceptRelease(r);
      }
      expect(x.awaitsSecret(1), isFalse);
      expect(x.nextShuffler, 2, reason: 'seat 1\'s shuffle was computed by all, seat 2 is next');
    }
    final seat2 = all[1];
    final s2 = seat2.myShuffle()!;
    broadcast(all, 1, (x) => x.acceptShuffle(s2));
    for (final x in all) {
      expect(x.deck, isNotNull, reason: 'seat 3, a bot, shuffled by all');
      expect(x.phase, DealPhase.tokens);
    }
    for (final i in [0, 1]) {
      final m = all[i].myTokens()!;
      broadcast(all, i, (x) => x.acceptTokens(m));
    }
    for (final i in [0, 1]) {
      final m = all[i].myDeclaration()!;
      broadcast(all, i, (x) => x.acceptDeclaration(m));
    }
    for (final x in all) {
      expect(x.phase, DealPhase.dealt);
      expect(x.handOf(1), isNotNull, reason: 'seat 1\'s hand is open, as a bot\'s');
      expect(x.handOf(3), isNotNull);
      expect(x.leader, all[0].leader);
    }
    expect(all[0].handOf(2), isNull);
    expect(seat2.handOf(0), isNull);
    expect(juror.handOf(0), isNull);
  });

  test('with no jury to escrow to, every other person\'s piece is needed', () {
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const HumanDealSeat('c'), const BotDealSeat()];
    final all = dealOut(seats);
    for (final x in all) {
      x.seatLeft(0);
    }
    final r1 = all[1].releaseShare(0)!;
    final r2 = all[2].releaseShare(0)!;
    expect(all[3].acceptRelease(r1), isTrue);
    expect(all[3].handOf(0), isNull);
    expect(all[3].acceptRelease(r2), isTrue);
    expect(all[3].handOf(0), isNotNull);
    expect(all[3].handOf(0), all[0].handOf(0));
  });

  test('the same keys message twice, and a person\'s keys are one message however often asked', () {
    final seats = [const HumanDealSeat('a'), const HumanDealSeat('b'), const BotDealSeat(), const BotDealSeat()];
    final a = make(seats, 0);
    expect(a.myKeys(), same(a.myKeys()));
    final b = make(seats, 1);
    expect(b.acceptKeys(a.myKeys()!), isTrue);
    expect(b.acceptKeys(a.myKeys()!), isTrue);
    final forged = Map<String, Object?>.from(a.myKeys()!)..['pk'] = base64Encode(Uint8List(pointBytes));
    expect(make(seats, 1).acceptKeys(forged), isFalse);
  });
}
