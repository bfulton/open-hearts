/// What has gone: the fifty-two, with the ones already played struck
/// out (docs/explanation/screens.md).
///
/// The one thing a phone genuinely cannot show and a tablet can. It is
/// also the thing Hearts players keep in their heads and mostly get
/// wrong — whether the queen is still out, how many hearts are left,
/// whether anybody can still follow clubs — so a rail that shows it is
/// showing more of the game rather than more of the same game.
///
/// Nothing here is a secret: every card on it has been played face up
/// in front of everybody. It is a memory aid, not a peek.
library;

import 'dart:math' as math;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';
import 'pip.dart';

class Gone extends StatelessWidget {
  const Gone({super.key, required this.played, this.width = 300});

  /// Every card played this hand, as this player has seen it.
  final Set<engine.Card> played;

  final double width;

  /// The suits down the rail: the one that matters most at the top.
  static const order = [engine.Suit.spades, engine.Suit.hearts, engine.Suit.diamonds, engine.Suit.clubs];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(context.l10n.whatHasGone,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Palette.chromeDim, letterSpacing: 0.6)),
          const SizedBox(height: 10),
          for (final suit in order) ...[
            _SuitRow(suit: suit, played: played, width: width - 20),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 6),
          _Left(played: played),
        ],
      ),
    );
  }
}

class _SuitRow extends StatelessWidget {
  const _SuitRow({required this.suit, required this.played, required this.width});

  final engine.Suit suit;
  final Set<engine.Card> played;
  final double width;

  @override
  Widget build(BuildContext context) {
    // The suit's own symbol, then its thirteen ranks in a row that fits
    // whatever width the rail has. The ranks are read, so they keep the
    // reader's text size: where that makes a 10 wider than its share of
    // the row, every mark takes the room a 10 needs and the suit runs
    // on to a second row rather than break a 10 in two.
    final share = ((width - 18) / engine.Rank.values.length).clamp(11.0, 22.0);
    final each = math.max(share, _RankMark.widest(context));
    return Row(
      children: [
        // Drawn, not typed: Roboto has no suit glyphs and a text pip
        // falls through to a network font (ui/pip.dart).
        SizedBox(width: 18, child: Pip(suit: suit, size: 11, color: colorOnFelt(suit))),
        Expanded(
          child: Wrap(
            children: [
              for (final rank in engine.Rank.values)
                SizedBox(
                  width: each,
                  child: _RankMark(
                    rank: rank,
                    red: suit.isRed,
                    gone: played.contains(engine.Card.of(suit, rank)),
                    // The queen of spades is the card the hand is about.
                    heavy: suit == engine.Suit.spades && rank == engine.Rank.queen,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RankMark extends StatelessWidget {
  const _RankMark({required this.rank, required this.red, required this.gone, required this.heavy});

  final engine.Rank rank;
  final bool red;
  final bool gone;
  final bool heavy;

  /// The widest a mark is, at the reader's text size: a 10, and the
  /// heavy type, with a hair either side.
  static double widest(BuildContext context) =>
      (TextPainter(
            text: TextSpan(text: '10', style: DefaultTextStyle.of(context).style.merge(const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800))),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout())
          .width +
      2;

  @override
  Widget build(BuildContext context) {
    final colour = red ? Palette.red : Palette.chrome;
    return Text(
      rank.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: heavy ? 12.5 : 11.5,
        height: 1.2,
        // Gone is said by fading it, not by striking it through: a rail
        // read out of the corner of the eye wants the ones still out
        // there to be the ones that carry.
        color: gone ? colour.withValues(alpha: 0.22) : colour,
        fontWeight: heavy && !gone ? FontWeight.w800 : FontWeight.w500,
        decoration: gone ? TextDecoration.lineThrough : null,
        decorationColor: colour.withValues(alpha: 0.35),
      ),
    );
  }
}

/// The one line of arithmetic nobody does in their head correctly: how
/// many of the points are still out there.
class _Left extends StatelessWidget {
  const _Left({required this.played});

  final Set<engine.Card> played;

  @override
  Widget build(BuildContext context) {
    final hearts = engine.Rank.values.where((r) => !played.contains(engine.Card.of(engine.Suit.hearts, r))).length;
    final queen = !played.contains(engine.Card.of(engine.Suit.spades, engine.Rank.queen));
    return Text(
      context.l10n.stillOut(hearts, flag(queen)),
      style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
    );
  }
}
