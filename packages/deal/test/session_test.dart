/// A whole hand's deal among four sessions in one process — two people
/// and two bots, then four people — the way the table drives it:
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

  test('a departed seat\'s hand opens from its key\'s two shares, and the key is never rebuilt', () {
    final seats = [for (final k in ['a', 'b', 'c', 'd']) HumanDealSeat(k)];
    final juror = make(seats, null, key: 'juror');
    final all = dealOut(seats, custodians: ['juror', 'other-juror'], extra: [juror]);

    // Seat 3 goes. Nobody releases a piece of its secret here: the
    // people hold one share of its key and the jury the other, and
    // what crosses is each share's tokens for the positions that are
    // still shut (docs/03-fair-deal.md).
    for (final x in [...all, juror]) {
      x.seatLeft(3);
    }
    expect(all[0].awaitsSecret(3), isTrue, reason: 'one share opens nothing on its own');
    expect(juror.awaitsSecret(3), isTrue);

    final fromSeat = all[0].releaseShareTokens(3)!;
    final fromJuror = juror.releaseShareTokens(3)!;
    expect(fromSeat['share'], 0, reason: "a person holds the people's share");
    expect(fromJuror['share'], 1, reason: "a juror holds the jury's");
    expect(all[0].releaseShareTokens(2), isNull, reason: 'seat 2 is still here');
    // Thirteen positions of its own, and no more: the seat published
    // its tokens for the other seats' before it went.
    expect((fromSeat['tokens'] as Map).length, 13);
    expect((fromSeat['tokens'] as Map).keys.map((k) => int.parse(k as String) ~/ 13).toSet(), {3});

    // A person already holds half, so the juror's half finishes it.
    expect(all[1].acceptShareTokens(fromJuror), isTrue);
    expect(all[1].handOf(3), all[3].handOf(3), reason: "its own share's tokens and the juror's");
    expect(all[1].awaitsSecret(3), isFalse);
    expect(all[1].knowsSecret(3), isFalse, reason: 'and the key was never put back together');

    // A bystander holding no share of it needs both halves, and one
    // alone tells it nothing.
    final watcher = make(seats, null, key: 'watcher');
    final byMessage = dealOut(seats, custodians: ['juror', 'other-juror'], extra: [watcher]);
    final theirJuror = make(seats, null, key: 'juror');
    for (final x in [...byMessage, theirJuror]) {
      x.seatLeft(3);
    }
    expect(watcher.acceptShareTokens(byMessage[0].releaseShareTokens(3)!), isTrue);
    expect(watcher.handOf(3), isNull, reason: "one share's tokens open nothing");
    expect(watcher.awaitsSecret(3), isTrue);

    // A share's token is proved against that share's key and no other,
    // so the halves cannot be swapped or made up.
    final swapped = Map<String, Object?>.from(byMessage[0].releaseShareTokens(3)!)..['share'] = 1;
    expect(watcher.acceptShareTokens(swapped), isTrue, reason: 'taken in');
    expect(watcher.handOf(3), isNull, reason: 'but not a token of that share, so nothing is kept');
    expect(watcher.acceptShareTokens({'about': 3, 'holder': 'x', 'share': 9, 'tokens': const {}}), isFalse);
    expect(watcher.acceptShareTokens({'about': 2, 'holder': 'x', 'share': 0, 'tokens': const {}}), isFalse,
        reason: 'nothing is released for a seat still here');

    expect(watcher.handOf(3), isNull, reason: 'still shut after all that');
  });

  test('a pass sealed to a seat that then leaves opens from that seat\'s two shares', () {
    final seats = [for (final k in ['a', 'b', 'c', 'd']) HumanDealSeat(k)];
    final juror = make(seats, null, key: 'juror');
    final all = dealOut(seats, custodians: ['juror', 'other-juror'], extra: [juror]);

    // Seat 0 passes three cards to seat 1, sealed to seat 1's key.
    final positions = [0, 5, 12];
    final passed = [for (final p in positions) all[0].openedCardAt(p)!];
    final pass = all[0].passMessage(1, positions)!;
    broadcast(all, 0, (x) => x.acceptPass(pass));
    all[0].acceptPass(pass);

    // Then seat 1 goes. That seal is a ciphertext only its key opens,
    // and its key is nobody's, so the parts come from the two shares —
    // a token over the seal itself (docs/03-fair-deal.md).
    for (final x in [...all, juror]) {
      x.seatLeft(1);
    }
    expect(all[2].awaitsSecret(1), isTrue);
    expect(all[2].handOf(1), isNull);

    final fromJuror = juror.releaseShareTokens(1)!;
    expect([for (final k in (fromJuror['seals'] as Map).keys) int.parse(k as String)]..sort(), positions,
        reason: 'a part for each seal made out to the seat');
    expect(all[2].acceptShareTokens(fromJuror), isTrue);

    expect(all[2].handOf(1), isNotNull, reason: "its own share's parts and the juror's open the seal");
    expect(all[2].awaitsSecret(1), isFalse);
    expect(all[2].knowsSecret(1), isFalse, reason: 'and the key was never put back together');
    for (final c in passed) {
      expect(all[2].handOf(1), contains(c), reason: 'the passed cards are in the hand it left behind');
    }
    expect(all[2].handOf(1)!.length, 16);

    // A holder that has served itself can still serve a peer behind
    // it: the seal is not thrown away with the opening.
    final again = all[2].releaseShareTokens(1)!;
    expect((again['seals'] as Map), isNotEmpty);
  });

  test('a bot seat a juror holds escrows to the jury alone: any two jurors open it, a player and a juror cannot', () {
    // Three people and a bot seat held by the first juror. Its key is
    // drawn like a person's rather than hashed from what everyone
    // knows, so the table cannot compute its hand (docs/04-live-play.md).
    final jury = ['juror0', 'juror1', 'juror2', 'juror3'];
    final seats = [
      const HumanDealSeat('a'),
      const HumanDealSeat('b'),
      const HumanDealSeat('c'),
      BotDealSeat(key: jury.first),
    ];
    final holder = make(seats, 3, key: jury.first, custodians: jury);
    final keys = holder.myKeys()!;

    // Not a piece of it goes to anybody at the table.
    expect(keys['pieces'], isEmpty, reason: 'no player holds a piece of a bot seat');
    expect((keys['custody'] as List).length, jury.length, reason: 'one to every juror');

    // Every juror opens its own piece, and a piece on its own is
    // noise: any two of them rebuild the secret and one never does
    // (deal.dart, escrowThreshold).
    final jurors = [for (final k in jury) make(seats, null, key: k, custodians: jury)];
    for (final j in jurors) {
      expect(j.acceptKeys(keys), isTrue);
      j.seatLeft(3);
    }
    final players = [for (var s = 0; s < 3; s++) make(seats, s, custodians: jury)];
    for (final p in players) {
      expect(p.acceptKeys(keys), isTrue);
      p.seatLeft(3);
      expect(p.releaseShare(3), isNull, reason: 'a player has nothing of it to release');
    }

    // A player hears every one of them and is no wiser. Holding a
    // piece is not what it takes to rebuild a secret — hearing
    // [escrowThreshold] of them is — so a piece said in the clear
    // would be a piece the players had too. A bot seat's go sealed to
    // the custodians, and the side the hand is hidden from cannot so
    // much as take one in.
    for (final j in jurors) {
      expect(players[0].acceptRelease(j.releaseShare(3)!), isFalse, reason: 'sealed to the jury, and a player is not on it');
    }
    expect(players[0].knowsSecret(3), isFalse, reason: 'every juror released and the table learned nothing');

    // Among the jury it is any two, not two fixed halves
    // (docs/04-live-play.md). Each juror holds one piece of its own, so
    // one more opens the seat, whichever juror it comes from.
    for (var mine = 0; mine < jury.length; mine++) {
      for (var other = 0; other < jury.length; other++) {
        if (other == mine) continue;
        final side = make(seats, null, key: jury[mine], custodians: jury);
        expect(side.acceptKeys(keys), isTrue);
        side.seatLeft(3);
        expect(side.knowsSecret(3), isFalse, reason: 'juror $mine alone holds one piece, which is nothing');
        expect(side.acceptRelease(jurors[other].releaseShare(3)!), isTrue);
        expect(side.knowsSecret(3), isTrue, reason: 'jurors $mine and $other open it');
      }
    }
  });

  // Each piece is weighed by its custodian's place, and the pieces in
  // hand are summed. One that is not what its place says — a custodian
  // brought on from a redraw whose share was made at another place, or
  // one that released something else — spoils the sum. Any two that
  // agree, checked against the seat's key, are the secret.
  test('a piece that is not what its place says does not keep a bot seat shut: any two good ones open it', () {
    final jury = ['juror0', 'juror1', 'juror2', 'juror3'];
    final seats = [
      const HumanDealSeat('a'),
      const HumanDealSeat('b'),
      const HumanDealSeat('c'),
      BotDealSeat(key: jury.first),
    ];
    final keys = make(seats, 3, key: jury.first, custodians: jury).myKeys()!;
    final jurors = [for (final k in jury) make(seats, null, key: k, custodians: jury)];
    for (final j in jurors) {
      expect(j.acceptKeys(keys), isTrue);
      j.seatLeft(3);
    }
    final p = make(seats, 0, custodians: jury);
    expect(p.acceptKeys(keys), isTrue);
    p.seatLeft(3);
    final bad = {'about': 3, 'holder': jury[1], 'share': base64Encode(List.generate(32, (i) => i + 1))};
    expect(p.acceptRelease(bad), isTrue);
    expect(p.acceptRelease(jurors[2].releaseShare(3, inTheOpen: true)!), isTrue);
    expect(p.knowsSecret(3), isFalse, reason: 'one good piece and one that is not');
    expect(p.acceptRelease(jurors[3].releaseShare(3, inTheOpen: true)!), isTrue);
    expect(p.knowsSecret(3), isTrue, reason: 'two good pieces open it, whatever lies beside them');
  });

  test('a bot seat a juror holds is awaited when its keys have not been read, never guessed', () {
    // The case a juror summoned mid-hand is in: it has been told the
    // seat is given up before it has been carried the keys that say
    // whose it was. A bot seat nobody holds has a secret anyone can
    // compute, and a person who goes before keying turns into one —
    // but a seat a juror holds drew a key of its own, exactly so that
    // the table cannot work its hand out, and computing the public
    // one would open nothing.
    //
    // Guessing it is worse than knowing nothing: this side would stop
    // awaiting the escrow and would never say the piece it holds, and
    // the jurors that could have opened the seat between them would
    // wait for a release that was never coming.
    final jury = ['juror0', 'juror1', 'juror2', 'juror3'];
    final seats = [
      const HumanDealSeat('a'),
      const HumanDealSeat('b'),
      const HumanDealSeat('c'),
      BotDealSeat(key: jury.first),
    ];
    final side = make(seats, null, key: jury[1], custodians: jury);
    side.seatLeft(3);
    expect(side.knowsSecret(3), isFalse, reason: 'a held seat\'s key is drawn, so there is nothing to compute');
    expect(side.awaitsSecret(3), isTrue, reason: 'so the seat is awaited from the escrow, and this side says its piece');

    // A bot seat nobody holds is the other way about, and stays so:
    // there is no key to have drawn and the hand is everyone's.
    final open = [...seats.take(3), const BotDealSeat()];
    final other = make(open, null, key: jury[1], custodians: jury)..seatLeft(3);
    expect(other.awaitsSecret(3), isFalse, reason: 'an unheld bot seat was never anybody\'s to give up');
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

  test('a juror brought on mid-hand is given a share, and is a custodian like any other', () {
    // Four jurors hold a bot seat's secret; a fifth is brought on.
    final jury = ['juror0', 'juror1', 'juror2', 'juror3'];
    const newcomer = 'juror4';
    final seats = [
      const HumanDealSeat('a'),
      const HumanDealSeat('b'),
      const HumanDealSeat('c'),
      BotDealSeat(key: jury.first),
    ];
    final holder = make(seats, 3, key: jury.first, custodians: jury);
    final keys = holder.myKeys()!;

    final all = [for (final k in [...jury, newcomer]) make(seats, null, key: k, custodians: jury)];
    final watcher = make(seats, 0, custodians: jury);
    for (final x in [...all, watcher]) {
      expect(x.acceptKeys(keys), isTrue);
    }
    final jurors = all.sublist(0, 4);
    final fresh = all[4];
    expect(fresh.holdsPieceOf(3), isFalse, reason: 'a newcomer holds nothing yet');

    // Everyone learns the jury grew; the newcomer's index is its
    // place in the list, which only ever appends.
    for (final x in [...all, watcher]) {
      x.extendCustodians(3, [newcomer]);
    }
    const at = 5;

    // Two holders make the fifth share between them. Neither of them
    // rebuilds the secret to do it.
    final have = [1, 3];
    final parts = [for (final i in have) jurors[i - 1].topUpPart(3, at: at, have: have)!];
    for (final part in parts) {
      // A part is sealed to the newcomer: nobody else opens it.
      expect(watcher.acceptTopUpPart(part), isFalse, reason: 'a part is not for a bystander');
    }
    expect(fresh.acceptTopUpPart(parts[0]), isTrue);
    expect(fresh.holdsPieceOf(3), isFalse, reason: 'one part of two is not a share');
    expect(fresh.acceptTopUpPart(parts[1]), isTrue);
    expect(fresh.holdsPieceOf(3), isTrue, reason: 'the set is complete, so the share is made');

    // And it is a share like any other: with any one of the
    // originals it opens the seat, and on its own it does not.
    for (final other in [0, 1, 2, 3]) {
      // From a juror's seat, since a bot seat's pieces are sealed to
      // the custodians and nobody else can read one. The juror holds
      // one piece of its own, which is nothing on its own; the share
      // the newcomer was given answers beside it like any original.
      final side = make(seats, null, key: jury[other], custodians: jury);
      expect(side.acceptKeys(keys), isTrue);
      side.extendCustodians(3, [newcomer]);
      for (final x in [...all, side]) {
        x.seatLeft(3);
      }
      expect(side.knowsSecret(3), isFalse, reason: 'juror $other alone is one piece');
      expect(side.acceptRelease(fresh.releaseShare(3)!), isTrue);
      expect(side.knowsSecret(3), isTrue, reason: 'the newcomer answers beside juror $other');
    }

    // A part weighed against one set does not go with a part weighed
    // against another: the newcomer sums a set only once it has all
    // of it.
    final other = make(seats, null, key: newcomer, custodians: jury)..acceptKeys(keys);
    other.extendCustodians(3, [newcomer]);
    expect(other.acceptTopUpPart(jurors[0].topUpPart(3, at: at, have: [1, 3])!), isTrue);
    expect(other.acceptTopUpPart(jurors[1].topUpPart(3, at: at, have: [2, 4])!), isTrue);
    expect(other.holdsPieceOf(3), isFalse, reason: 'two parts, two different sets, no share');

    // And the guards: a set this side is not in, a set with the
    // newcomer in it, a set too small to be one.
    expect(jurors[0].topUpPart(3, at: at, have: [2, 3]), isNull);
    expect(jurors[0].topUpPart(3, at: at, have: [1, at]), isNull);
    expect(jurors[0].topUpPart(3, at: at, have: [1]), isNull);
    expect(jurors[0].topUpPart(3, at: 9, have: [1, 3]), isNull, reason: 'an index nobody holds');
  });
}
