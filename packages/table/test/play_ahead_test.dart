/// A bot seat's card said before its turn, on the card before it heard
/// and not yet settled (client.dart, _playAhead).
///
/// Alone with three bots the jury holds, every bot card waited on the
/// person: a turn settles on the witness of most of the people at the
/// table, so the next bot's juror could not play until the person's
/// device had seen the card before it and said so. Three bots, three
/// round trips through the person's line between one of their cards
/// and the next. A bot's card is worked out the same by whoever works it
/// out, so the next seat's juror works its own out on the card before
/// it as soon as it hears it, and says it for the turn after.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

import 'sealed.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  /// One person a satellite's distance from the relay, three hundred
  /// milliseconds each way, and the jurors a few from one another.
  SimTable farFromTheJury(int seed, {int target = 1}) {
    final t = SimTable(humans: 1, seed: seed, crypto: crypto, target: target, lastResort: true);
    final key = t.people[0].client.signer.publicKey;
    t.net
      ..minLatencyMs = 10
      ..maxLatencyMs = 20
      ..steer = (from, to, message) => from == key || to == key ? 300 : null;
    return t;
  }

  test('the bots\' cards between one of the person\'s and the next take one round trip of the person\'s, not three', () {
    // Seed 9 has a bot whose card turns on what has been played in the
    // hand, the cards before it in the trick included.
    for (final seed in [4, 5, 6, 9]) {
      final t = farFromTheJury(seed);
      final ada = t.people[0].client;
      final key = ada.signer.publicKey;
      // From each card the person says to the next time it is their
      // turn: the bots between, the sweep, and nothing of their own.
      final said = <int>[];
      final turns = <int>[];
      var mine = false;
      // And each card said ahead said once: a juror hears every card,
      // and every one could set it saying its own again.
      final lines = <String>[];
      for (final j in t.jurors) {
        j.log = lines.add;
      }
      t.net.onSend = (from, message) {
        if (from == key && message['kind'] == 'play') said.add(t.clock.nowMs);
      };
      ada.changes.listen((_) {
        final now = ada.game.phase == Phase.playing && ada.game.currentSeat == ada.mySeat;
        if (now && !mine) turns.add(t.clock.nowMs);
        mine = now;
      });
      t.start();
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 30 * 60 * 1000), isTrue,
          reason: 'seed $seed played out:\n${ada.describe()}');
      final waits = [
        for (final s in said)
          if (turns.where((o) => o > s).firstOrNull case final o?) o - s,
      ]..sort();
      // Six hundred milliseconds is the person's round trip. Each bot
      // card waiting on it put the median at 1.3 to 1.9 seconds.
      expect(waits[waits.length ~/ 2], lessThan(1000), reason: 'seed $seed: waits $waits');
      expect([for (final j in t.jurors) j.client?.playedAhead ?? 0].fold(0, (a, b) => a + b), greaterThan(10),
          reason: 'seed $seed: cards said ahead of their turns');
      final ahead = [
        for (final l in lines)
          if (RegExp(r' (\w{4})/\S* played (\S+) for seat').firstMatch(l) case final m?) '${m.group(1)} ${m.group(2)}',
      ];
      expect(ahead, isNotEmpty);
      expect(ahead.toSet().length, ahead.length, reason: 'seed $seed: none said ahead twice');
      agree(t);
      t.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The other half: it changes nothing anybody decides. A juror that
  // says two cards for its seat — the only way the card before one
  // said ahead can settle as another — has the next juror's card made
  // on the one the table did not take. That card is not the bot's for
  // the hand that was played, and when the hand is opened every bot
  // card is checked against the bot (record.dart): so it names the
  // cards it was made on, no side takes it where the table came to
  // others, and the next juror makes its card again.
  test('a juror that says one card to the next juror and another to the table costs the card said ahead on it, and nothing else', () {
    for (final (seed, how) in [for (final seed in [4, 5, 6]) for (final how in TwoCards.values) (seed, how)]) {
      final t = farFromTheJury(seed);
      final ada = t.people[0].client;
      final lines = <String>[];
      for (final j in t.jurors) {
        j.log = lines.add;
      }
      // At the first card of a juror's that has another juror's seat
      // after it in the same trick: that card to everyone but the next
      // juror, and another legal one, signed and sealed the same, to the
      // next juror alone — any other card, or at a lead one of another
      // suit, so the next juror follows a suit the table did not lead,
      // or one the seat may not play at all.
      String? honest, other;
      PublicKey? next;
      final steer = t.net.steer!;
      t.net.steer = (from, to, message) {
        if (message['id'] == other) return to == next ? 0 : -1;
        if (message['id'] == honest && to == next) {
          honest = null; // the first copy only: carried later, it arrives
          return -1;
        }
        return steer(from, to, message);
      };
      t.net.onSend = (from, message) {
        final body = message['body'];
        if (other != null || message['kind'] != 'play' || body is! Map || body['hand'] != 0) return;
        final liar = t.jurors.where((j) => j.signer.publicKey == from).firstOrNull?.client;
        if (liar == null) return;
        final seat = body['seat'] as int;
        // A card said at its turn, not one said ahead of it.
        if (liar.game.currentSeat != seat) return;
        final after = (seat + 1) % seatCount;
        final held = liar.botHolders(0);
        if (liar.game.trick.length >= seatCount - 1 || held[after] == null || held[after] == from) return;
        if (how == TwoCards.otherSuit && liar.game.trick.isNotEmpty) return;
        final card = Card.parse(body['card'] as String);
        final legal = liar.game.legalPlaysFor(seat);
        final instead = switch (how) {
          TwoCards.otherCard => legal.where((c) => c != card).firstOrNull,
          TwoCards.otherSuit => legal.where((c) => c.suit != card.suit).firstOrNull,
          TwoCards.notPlayable => liar.game.handOf(seat).where((c) => !legal.contains(c)).firstOrNull,
        };
        if (instead == null) return;
        final d = liar.deal!;
        final token = d.playToken(d.positionOf(seat, instead.index)!)!;
        final lie = TableEvent.sign(t.jurors.firstWhere((j) => j.signer.publicKey == from).signer,
            table: t.spec.id, kind: EventKind.play, body: {...body.cast<String, Object?>(), 'card': instead.code, ...token});
        honest = message['id'] as String;
        other = lie.id;
        next = held[after];
        t.clock.schedule(1, () => liar.transport.broadcast(lie.toJson()));
      };
      t.start();
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 30 * 60 * 1000), isTrue,
          reason: 'seed $seed played out:\n${ada.describe()}');
      expect(other, isNotNull, reason: 'seed $seed: the juror said two cards');
      final by = next!.substring(0, 4);
      final playedAhead = lines.where((l) => l.contains(' $by/') && l.contains('ahead of the turn, after')).isNotEmpty;
      final again = lines.where((l) => l.contains(' $by/') && l.contains('on cards the table did not come to')).isNotEmpty;
      if (how == TwoCards.notPlayable) {
        // Nothing to play ahead on: a card the seat may not play is not
        // one anybody works a card out after.
        expect(again, isFalse, reason: 'seed $seed');
      } else {
        expect(playedAhead, isTrue, reason: 'seed $seed: the next juror played ahead on the card it was given');
        expect(again, isTrue, reason: 'seed $seed: and played again once the table came to the other');
      }
      // One record, checking out to the end, and every juror's as far as
      // it follows the table: whichever card the next juror's turn has,
      // every side has that one.
      agreeAmong(t, [ada]);
      final record = [for (final d in ada.record) d.key];
      for (final j in t.jurors) {
        final theirs = [for (final d in j.client?.record ?? const <Decision>[]) d.key];
        expect(theirs, record.take(theirs.length), reason: 'seed $seed: juror ${j.signer.publicKey.substring(0, 4)}');
        expect(theirs.length, greaterThan(record.length - seatCount), reason: 'to the last hand\'s audit');
      }
      t.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Held for a turn not open yet, a card has been checked by nobody. The
  // seat's own juror's card it may play there is one to look past;
  // another's, or one it may not play, is not.
  for (final forged in Forged.values) {
    test('a card held for a later turn that is ${forged == Forged.notInTheHand ? 'not in its seat\'s hand' : 'said by somebody not holding its seat'} is not played ahead on', () {
      final t = farFromTheJury(4);
      final ada = t.people[0].client;
      final lines = <String>[];
      for (final j in t.jurors) {
        j.log = lines.add;
      }
      TableClient? receiver;
      String? fake, forgedCard;
      int? fakeTurn;
      final steer = t.net.steer!;
      t.net.steer = (from, to, message) {
        if (message['id'] == fake) return to == receiver?.signer.publicKey ? 0 : -1;
        // The seat's own juror's card said ahead, held back from the
        // receiver until the forged one is in front of it.
        final body = message['body'];
        if (fakeTurn != null && body is Map && body['turn'] == fakeTurn && message['kind'] == 'play' && message['id'] != fake && to == receiver?.signer.publicKey) {
          return 100;
        }
        return steer(from, to, message);
      };
      t.net.onSend = (from, message) {
        final body = message['body'];
        if (fake != null || message['kind'] != 'play' || body is! Map || body['hand'] != 0 || body.containsKey('after')) return;
        final first = t.jurors.where((j) => j.signer.publicKey == from).firstOrNull?.client;
        if (first == null) return;
        final seat = body['seat'] as int;
        if (first.game.currentSeat != seat || first.game.trick.length > 1) return;
        final held = first.botHolders(0);
        final (b, c) = ((seat + 1) % seatCount, (seat + 2) % seatCount);
        final jb = t.jurors.where((j) => j.signer.publicKey == held[b]).firstOrNull;
        final jc = t.jurors.where((j) => j.signer.publicKey == held[c]).firstOrNull;
        if (jb == null || jc == null || jb == jc) return;
        // The card after this one as the next seat's juror has it, and
        // one in its place.
        final played = Card.parse(body['card'] as String);
        final ahead = jb.client!.game.lookahead()..play(seat, played);
        final legal = ahead.legalPlaysFor(b);
        // What the next seat's bot plays, so that the forged card is
        // not the one its juror says anyway.
        final bots = Bot(persona: (t.spec.seats[b] as BotSeat).persona).chooseCard(
            BotView(
                seat: b,
                hand: ahead.handOf(b),
                trick: ahead.trick,
                played: {...jb.client!.played, played},
                heartsBroken: ahead.heartsBroken,
                isFirstTrick: ahead.isFirstTrick,
                taken: ahead.taken),
            legal);
        final card = switch (forged) {
          // A card the receiver holds itself, with the next seat's token
          // for another position: it opens nothing of the next seat's.
          Forged.notInTheHand => jc.client!.game.handOf(c).first,
          Forged.notTheHolders => legal.where((x) => x != bots).firstOrNull,
        };
        if (card == null) return;
        final d = jb.client!.deal!;
        final signer = forged == Forged.notInTheHand ? jb.signer : t.jurors.firstWhere((j) => !held.containsValue(j.signer.publicKey)).signer;
        final token = d.playToken(d.positionOf(b, (forged == Forged.notInTheHand ? bots : card).index)!)!;
        final event = TableEvent.sign(signer, table: t.spec.id, kind: EventKind.play, body: {
          'hand': 0,
          'turn': TurnId.play(0, first.game.tricksPlayed * seatCount + first.game.trick.length + 1).index,
          'seat': b,
          'card': card.code,
          ...token,
        });
        fake = event.id;
        forgedCard = card.code;
        fakeTurn = event.turn.index;
        receiver = jc.client;
        t.clock.schedule(1, () => first.transport.broadcast(event.toJson()));
      };
      // What the receiver says ahead after the forged card's turn.
      final saidAfter = <List<Object?>>[];
      final onSend = t.net.onSend!;
      t.net.onSend = (from, message) {
        onSend(from, message);
        final body = message['body'];
        if (from == receiver?.signer.publicKey && body is Map && body['turn'] == (fakeTurn ?? -2) + 1 && body['after'] is List) {
          saidAfter.add(body['after'] as List<Object?>);
        }
      };
      t.start();
      expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 30 * 60 * 1000), isTrue, reason: ada.describe());
      expect(fake, isNotNull, reason: 'the card was forged');
      // Ahead of the turn after it, the receiver may yet play — on the
      // card its seat's juror said, once the turn is open there and that
      // card checked — but never on the forged one.
      for (final after in saidAfter) {
        expect(after.last, isNot(forgedCard), reason: 'played ahead on the forged card: $after');
      }
      expect(lines.where((l) => l.contains('on cards the table did not come to')), isEmpty);
      agree(t);
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // At a table of two people, between one person's card and the other's:
  // the bots play ahead on one another's cards and on nobody else's.
  test('with two people, the bots between them play ahead on bots\' cards alone', () {
    final t = SimTable(humans: 2, seed: 5, crypto: crypto, target: 1, lastResort: true);
    final people = {for (final p in t.people) p.client.signer.publicKey};
    t.net
      ..minLatencyMs = 10
      ..maxLatencyMs = 20
      ..steer = (from, to, message) => people.contains(from) || people.contains(to) ? 300 : null;
    final ahead = <TableEvent>[];
    t.net.onSend = (from, message) {
      final body = message['body'];
      if (message['kind'] == 'play' && body is Map && body.containsKey('after')) ahead.add(TableEvent.parse(message)!);
    };
    t.start();
    final ada = t.people[0].client;
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 30 * 60 * 1000), isTrue, reason: ada.describe());
    expect(ahead, isNotEmpty, reason: 'cards said ahead');
    for (final e in ahead) {
      final after = e.body['after'] as List;
      for (var i = 0; i < after.length; i++) {
        final at = TurnId.play(0, e.turn.playIndex - after.length + i);
        final d = ada.record.lastWhere((d) => d.turn == at && !d.removal);
        expect(t.spec.seats[d.event.seat], isA<BotSeat>(), reason: '$e worked out on a person\'s card at $at');
      }
    }
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A seat given up to the escrow is played by the first of its
  // custodians as each of its turns opens. A custodian holds the seat's
  // hand by then, and could play it ahead as its juror did; it does not,
  // or each would.
  test('a seat given up to the escrow is not played ahead by its custodians', () {
    final t = farFromTheJury(4);
    final ada = t.people[0].client;
    final lines = <String>[];
    for (final j in t.jurors) {
      j.log = lines.add;
    }
    t.start();
    expect(t.clock.runUntil(() => ada.game.phase == Phase.playing, limitMs: 10 * 60 * 1000), isTrue);
    final held = ada.botHolders(0);
    final (seat, juror) = (held.keys.first, held.values.first);
    t.net.doze(juror);
    expect(t.clock.runUntil(() => t.clients.every((c) => c.done), limitMs: 30 * 60 * 1000), isTrue, reason: ada.describe());
    expect(ada.escrowedAt(0), contains(seat), reason: 'the seat went to the escrow');
    final ahead = [
      for (final l in lines)
        if (RegExp(r' (\w{4})/\S* played \S+ for seat (\d)').firstMatch(l) case final m?) (m.group(1)!, int.parse(m.group(2)!)),
    ];
    expect(ahead, isNotEmpty);
    for (final (by, at) in ahead) {
      expect(by, held[at]!.substring(0, 4), reason: 'seat $at played ahead by $by, not its juror');
    }
    agree(t);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // A hand with no pass, where nothing has to settle before the play
  // but the deal: the bots play ahead from the first trick.
  test('a hand without a pass plays ahead too', () {
    final t = farFromTheJury(4, target: gameOverScore);
    final ada = t.people[0].client;
    t.start();
    expect(t.clock.runUntil(() => ada.game.handNumber == 3 && ada.game.phase == Phase.playing, limitMs: 60 * 60 * 1000), isTrue,
        reason: 'the fourth hand, which holds: ${ada.describe()}');
    expect(PassDirection.forHand(3), PassDirection.hold);
    final before = [for (final j in t.jurors) j.client?.playedAhead ?? 0].fold(0, (a, b) => a + b);
    expect(t.clock.runUntil(() => ada.game.handNumber > 3 || ada.done, limitMs: 30 * 60 * 1000), isTrue, reason: ada.describe());
    expect([for (final j in t.jurors) j.client?.playedAhead ?? 0].fold(0, (a, b) => a + b), greaterThan(before),
        reason: 'played ahead in it');
    expect(ada.failure, isNull);
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// What the lying juror says to the next one in place of its card.
enum TwoCards { otherCard, otherSuit, notPlayable }

/// A card held for a later turn that nothing has checked yet.
enum Forged { notInTheHand, notTheHolders }
