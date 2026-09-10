/// Counts the bot as a boolean circuit.
///
/// docs/04-live-play.md runs the bot inside a multi-party computation
/// over a secret-shared hand. What that costs is AND gates, so this
/// prints them: for one play, for one pass, and for the whole of a
/// bot-held seat's hand. The test proves the circuit agrees with the
/// bot; this only prices it.
///
///     cd packages/engine && dart run tool/circuit_count.dart
library;

// A measurement's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:engine/engine.dart';

void main() {
  int? fixedPlay, fixedPass, fixedLegal, fixedPositions;
  var fixedPlayPublic = 0;
  final folded = <int>[];
  var plays = 0, passes = 0;

  for (var seed = 0; seed < 20; seed++) {
    final game = HeartsGame(seed: seed);
    final bot = Bot(random: Random(seed));
    final played = <Card>{};
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          for (var s = 0; s < seatCount; s++) {
            final hand = game.handOf(s);
            final c = Circuit();
            final ob = ObliviousBot(c);
            ob.choosePass(ob.secretHand(hand));
            fixedPass = _same(fixedPass, c.ands);
            passes++;
            game.setPass(s, bot.choosePass(hand));
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
          for (final fold in [false, true]) {
            final c = Circuit(foldPublic: fold);
            final ob = ObliviousBot(c);
            final hand = ob.secretHand(view.hand);
            final p = PublicPlay(c, view);
            if (!fold) {
              final lc = Circuit();
              final lb = ObliviousBot(lc);
              lb.legal(lb.secretHand(view.hand), PublicPlay(lc, view));
              fixedLegal = _same(fixedLegal, lc.ands);
            }
            ob.chooseCard(hand, p);
            if (fold) {
              folded.add(c.ands);
            } else {
              fixedPlay = _same(fixedPlay, c.ands);
              fixedPlayPublic = c.publicInputs;
              final pc = Circuit();
              final pb = ObliviousBot(pc);
              final gone = played.where((x) => !view.hand.contains(x)).toList();
              final positions = [...view.hand, ...gone.take(13 - view.hand.length)];
              pb.chooseCardAt(
                [
                  for (final card in positions)
                    [for (var k = 0; k < 6; k++) pc.secret((card.index >> k) & 1 == 1)],
                ],
                [for (final card in positions) pc.public(view.hand.contains(card))],
                PublicPlay(pc, view),
              );
              fixedPositions = _same(fixedPositions, pc.ands);
            }
          }
          plays++;
          final card = bot.chooseCard(view, game.legalPlaysFor(seat));
          game.play(seat, card);
          played.add(card);
        case Phase.handOver:
          game.nextHand();
          played.clear();
        case Phase.gameOver:
          break;
      }
    }
  }

  folded.sort();
  final mean = folded.reduce((a, b) => a + b) / folded.length;
  print('AND gates, circuit built before the table state is known');
  print('  one play (policy + legality) : $fixedPlay   ($fixedLegal of them for legality)');
  print('  one play, hand as 13 dealt positions in, position out : $fixedPositions');
  print('  one pass                     : $fixedPass');
  print('  secret inputs 52, public inputs $fixedPlayPublic');
  print('');
  print('AND gates, circuit built after the table state is known');
  print('  one play: min ${folded.first}  median ${folded[folded.length ~/ 2]}  mean ${mean.toStringAsFixed(0)}  max ${folded.last}');
  print('');
  print('measured over $plays plays and $passes passes');
  print('');
  final handPlays = 13 * fixedPositions!;
  print('a bot-held seat for one hand: pass + 13 plays over positions = ${fixedPass! + handPlays} ANDs');
}

int _same(int? seen, int now) {
  if (seen != null && seen != now) {
    throw StateError('circuit shape changed: $seen then $now');
  }
  return now;
}
