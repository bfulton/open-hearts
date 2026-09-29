/// Writes the bot's policy out as a netlist, so something else can
/// garble it.
///
/// docs/04-live-play.md runs a bot-held seat's decision inside a
/// two-party computation: the thirteen cards at that seat's positions
/// go in secret-shared between the two computing parties, the policy
/// runs over the shares, and what comes out is which position to open.
/// [ObliviousBot] is that policy as gates; this hands the gates over.
///
///     cd packages/engine
///     dart run tool/circuit_dump.dart [seed] [decision] > circuit.txt
///
/// The circuit is built with the table state folded in, because by the
/// time the decision is made both parties know it — which is also the
/// smaller circuit (tool/circuit_count.dart).
///
/// The format is lines, and nothing that needs a parser:
///
///     wires N          how many wires, 0 and 1 being the constants
///     gates G          how many gate lines follow the header
///     ands A           how many of them are AND gates, which are what cost
///     inputs K w...    the input wires, in the order they are fed
///     owners BITS      0 the garbler feeds it, 1 the evaluator
///     outputs K w...   the wires the answer comes out on
///     a BITS           one party's share of the input, for a test
///     b BITS           the other's
///     expect BITS      what the bot chooses, for the same test
///     X a b o          o = a xor b
///     A a b o          o = a and b
///     N a a o          o = not a
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:engine/engine.dart';

void main(List<String> args) {
  final seed = args.isNotEmpty ? int.parse(args[0]) : 1;
  final decision = args.length > 1 ? int.parse(args[1]) : 20;

  final game = HeartsGame(seed: seed);
  final bot = Bot();
  final played = <Card>{};
  var seen = 0;

  while (game.phase != Phase.gameOver) {
    switch (game.phase) {
      case Phase.passing:
        for (var s = 0; s < seatCount; s++) {
          game.setPass(s, bot.choosePass(game.handOf(s)));
        }
        played.clear();
      case Phase.playing:
        if (game.pendingTrick != null) {
          game.collectTrick();
          break;
        }
        final seat = game.currentSeat!;
        final view = BotView(
          seat: seat,
          hand: game.handOf(seat),
          trick: game.trick,
          played: played,
          heartsBroken: game.heartsBroken,
          isFirstTrick: game.isFirstTrick,
          taken: game.taken,
        );
        if (seen++ == decision) {
          _dump(view, played, seed, bot.chooseCard(view, game.legalPlaysFor(seat)));
          return;
        }
        final card = bot.chooseCard(view, game.legalPlaysFor(seat));
        game.play(seat, card);
        played.add(card);
      case Phase.handOver:
        game.nextHand();
        played.clear();
      case Phase.gameOver:
        break;
      case Phase.dealing:
        throw StateError('a seeded game deals itself');
    }
  }
  throw StateError('the game ended before decision $decision');
}

void _dump(BotView view, Set<Card> played, int seed, Card expected) {
  // The thirteen positions this seat was dealt, in the order they were
  // dealt: what is still in hand, then what has been opened already.
  final gone = played.where((x) => !view.hand.contains(x)).toList();
  final positions = [...view.hand, ...gone.take(13 - view.hand.length)];
  final held = [for (final card in positions) view.hand.contains(card)];

  // One party's share is random; the other's is the card xor it, so
  // neither share alone is anything.
  final random = Random(seed * 7919 + 13);
  final aShare = <bool>[];
  final bShare = <bool>[];
  for (final card in positions) {
    for (var k = 0; k < 6; k++) {
      final bit = (card.index >> k) & 1 == 1;
      final mask = random.nextBool();
      aShare.add(mask);
      bShare.add(bit ^ mask);
    }
  }

  final c = Circuit(foldPublic: true, record: true);
  final ob = ObliviousBot(c);
  var at = 0;
  final cards = [
    for (var k = 0; k < 13; k++)
      [
        for (var j = 0; j < 6; j++)
          () {
            final a = c.secret(aShare[at]);
            final b = c.secret(bShare[at]);
            at++;
            // Free: the shares meet inside the circuit and the cards
            // themselves are never anywhere, on either side.
            return c.xor(a, b);
          }(),
      ],
  ];
  final out = ob.chooseCardAt(cards, [for (final h in held) c.public(h)], PublicPlay(c, view));

  print('# the bot choosing a card at seat ${view.seat}, game seed $seed');
  print('wires ${c.wires}');
  print('gates ${c.gates.length ~/ 4}');
  print('ands ${c.ands}');
  print('inputs ${c.inputs.length} ${c.inputs.join(' ')}');
  // The two shares of a bit are two inputs, one from each party, and
  // they meet only inside the circuit.
  print('owners ${[for (var i = 0; i < c.inputs.length; i++) i.isOdd ? 1 : 0].join()}');
  print('outputs ${out.heldAt.length} ${out.heldAt.map((b) => b.wire).join(' ')}');
  print('a ${aShare.map((b) => b ? 1 : 0).join()}');
  print('b ${bShare.map((b) => b ? 1 : 0).join()}');
  print('expect ${out.heldAt.map((b) => b.value ? 1 : 0).join()}');
  // What the circuit says, against what the bot itself does: the
  // fixture cannot drift from the bot without this failing.
  final chosen = [for (var k = 0; k < 13; k++) if (out.heldAt[k].value) positions[k]];
  if (chosen.length != 1 || chosen.single != expected) {
    throw StateError('the circuit chose $chosen where the bot chose $expected');
  }
  const names = ['X', 'A', 'N'];
  for (var i = 0; i < c.gates.length; i += 4) {
    print('${names[c.gates[i]]} ${c.gates[i + 1]} ${c.gates[i + 2]} ${c.gates[i + 3]}');
  }
}
