/// Looks for self-destructive plays in bot-versus-bot games.
///
///     cd packages/engine && dart run tool/blunders.dart            # 300 tables
///     dart run --define=TABLES=1000 --define=SHOW=12 tool/blunders.dart
///
/// A blunder here is a play that took points it did not have to, judged
/// with hindsight: following suit, the bot won a trick that ended with
/// points in it while holding a legal card that would have lost it;
/// leading, it led a card that won its own trick with points while it
/// held a lower lead. Hindsight is unfair — a duck can be right and
/// still lose — so the counts are a place to look, not a verdict, and
/// SHOW prints whole tricks to look at.
library;

// A tool's entire output is its printing.
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:engine/engine.dart';

void main() {
  final tables = int.parse(const String.fromEnvironment('OH_TABLES', defaultValue: '300'));
  final show = int.parse(const String.fromEnvironment('OH_SHOW', defaultValue: '6'));
  final counts = <String, Map<String, int>>{};
  final examples = <String>[];
  final rng = Random(7);
  var plays = 0;
  for (var t = 0; t < tables; t++) {
    final draw = List.of(Persona.roster)..shuffle(rng);
    final table = draw.take(seatCount).toList();
    final bots = [for (final p in table) Bot(persona: p)];
    final game = HeartsGame(seed: 1000 + t);
    final played = <Card>{};
    // What each seat could have played instead, per play of the trick.
    final trickChoices = <({int seat, Card card, List<Card> legal, int lead})>[];
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, bots[s].choosePass(game.handOf(s)));
          }
          played.clear();
        case Phase.playing:
          if (game.pendingTrick != null) {
            final trick = game.pendingTrick!.plays;
            final winner = trickWinner(trick);
            final points = pointsIn(trick.map((p) => p.card));
            if (points > 0) {
              final choice = trickChoices.firstWhere((c) => c.seat == winner);
              final name = table[winner].name;
              final led = trick.first.card.suit;
              final winning = trick.firstWhere((p) => p.seat == winner).card;
              String? kind;
              if (trick.first.seat == winner) {
                // Led it and won it: was there a lower lead?
                final lower = choice.legal.where((c) => c.rank.value < winning.rank.value && c.suit != Suit.hearts);
                if (lower.isNotEmpty) kind = 'led high into points';
              } else if (winning.suit == led) {
                // Followed and won: was there a card that loses to what was on the table then?
                final high = trick.take(choice.lead).where((p) => p.card.suit == led).map((p) => p.card.rank.value).reduce(max);
                final ducks = choice.legal.where((c) => c.suit == led && c.rank.value < high);
                if (ducks.isNotEmpty) kind = 'won with a duck in hand';
                // Or a card that would have lost given everything that followed.
                final finalHigh = trick.where((p) => p.card.suit == led && p.seat != winner).map((p) => p.card.rank.value).fold(0, max);
                final hindsight = choice.legal.where((c) => c.suit == led && c.rank.value < finalHigh);
                if (kind == null && hindsight.isNotEmpty) kind = 'won; a lower card would have lost (hindsight)';
              }
              if (kind != null) {
                counts.putIfAbsent(name, () => {})[kind] = (counts[name]![kind] ?? 0) + 1;
                if (examples.length < show) {
                  final moon = bots[winner].shooting(
                      BotView(
                        seat: winner,
                        hand: [...game.handOf(winner), winning],
                        trick: const [],
                        played: played,
                        heartsBroken: game.heartsBroken,
                        isFirstTrick: false,
                        taken: game.taken,
                      ),
                      [winning],
                      following: false);
                  examples.add('table ${1000 + t} hand ${game.handNumber + 1} trick ${game.tricksPlayed + 1}: '
                      '$name ($kind${moon ? ', shooting' : ''}) took $points\n'
                      '    ${trick.map((p) => '${table[p.seat].name}:${p.card}').join('  ')}\n'
                      '    legal for $name then: ${choice.legal.join(' ')}   taken so far ${game.taken}');
                }
              }
            }
            trickChoices.clear();
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final legal = game.legalPlaysFor(seat);
          final view = BotView(
            seat: seat,
            hand: game.handOf(seat),
            trick: game.trick,
            played: played,
            heartsBroken: game.heartsBroken,
            isFirstTrick: game.isFirstTrick,
            taken: game.taken,
          );
          final card = bots[seat].chooseCard(view, legal);
          trickChoices.add((seat: seat, card: card, legal: legal, lead: game.trick.length));
          game.play(seat, card);
          played.add(card);
          plays++;
        case Phase.handOver:
          game.nextHand();
          played.clear();
        case Phase.gameOver:
          break;
        case Phase.dealing:
          throw StateError('a seeded game deals itself');
      }
    }
  }
  print('$tables tables, $plays plays\n');
  final kinds = {for (final m in counts.values) ...m.keys}.toList()..sort();
  print('${''.padRight(10)}${kinds.map((k) => k.padLeft(44)).join()}');
  for (final p in Persona.roster) {
    final m = counts[p.name] ?? const {};
    print('${p.name.padRight(10)}${kinds.map((k) => '${m[k] ?? 0}'.padLeft(44)).join()}');
  }
  print('');
  for (final e in examples) {
    print(e);
  }
}
