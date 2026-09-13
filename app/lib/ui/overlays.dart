/// The two moments the game stops for: the end of a hand and the end of
/// the game.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';
import '../theme.dart';

class HandOverSheet extends StatelessWidget {
  const HandOverSheet({
    super.key,
    required this.handNumber,
    required this.scores,
    required this.totals,
    required this.moonShooter,
    required this.names,
    required this.onNext,
    this.mySeat = humanSeat,
    this.action = 'Next hand',
  });

  /// Takes the numbers rather than the game: at a live table the game
  /// has already moved on to the next deal by the time this shows.
  factory HandOverSheet.of(HeartsGame game, {required List<String> names, required VoidCallback onNext}) =>
      HandOverSheet(
        handNumber: game.handNumber,
        scores: game.handScores,
        totals: game.totals,
        moonShooter: game.moonShooter,
        names: names,
        onNext: onNext,
      );

  final int handNumber;
  final List<int> scores;
  final List<int> totals;
  final int? moonShooter;
  final List<String> names;
  final VoidCallback onNext;
  final int mySeat;

  /// The button's label: at a live table the next hand is already
  /// under way, so it only dismisses.
  final String action;

  @override
  Widget build(BuildContext context) {
    final shooter = moonShooter;
    return _Sheet(
      title: shooter == null
          ? 'Hand ${handNumber + 1}'
          : shooter == mySeat
              ? 'You shot the moon'
              : '${names[shooter]} shot the moon',
      accent: shooter == null
          ? Palette.gold
          : shooter == mySeat
              ? Palette.gold
              : Palette.danger,
      subtitle: shooter == null ? null : 'All 26 — everyone else takes them',
      rows: [
        for (var seat = 0; seat < seatCount; seat++)
          (
            name: names[seat],
            delta: scores[seat],
            total: totals[seat],
            you: seat == mySeat,
          ),
      ],
      action: action,
      onAction: onNext,
    );
  }
}

class GameOverSheet extends StatelessWidget {
  const GameOverSheet({
    super.key,
    required this.game,
    required this.names,
    required this.onNewGame,
    this.onCopyRecord,
    this.mySeat = humanSeat,
    this.action = 'New game',
  });

  final HeartsGame game;
  final List<String> names;
  final VoidCallback onNewGame;
  final int mySeat;
  final String action;

  /// Puts the game's record on the clipboard: a line that replays the
  /// whole game, for looking at a hand afterwards.
  final VoidCallback? onCopyRecord;

  @override
  Widget build(BuildContext context) {
    final won = game.winners;
    final youWon = won.contains(mySeat);
    final title = youWon
        ? (won.length > 1 ? 'A share of it' : 'You win')
        : won.length > 1
            ? '${won.map((s) => names[s]).join(' and ')} tie'
            : '${names[won.first]} wins';

    return _Sheet(
      title: title,
      accent: youWon ? Palette.gold : Palette.danger,
      subtitle: 'Lowest score after ${game.handNumber + 1} hands',
      rows: [
        for (var seat = 0; seat < seatCount; seat++)
          (
            name: names[seat],
            delta: game.handScores[seat],
            total: game.totals[seat],
            you: seat == mySeat,
          ),
      ],
      action: action,
      onAction: onNewGame,
      secondary: onCopyRecord == null ? null : 'Copy record',
      onSecondary: onCopyRecord,
    );
  }
}

typedef _Row = ({String name, int delta, int total, bool you});

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.accent,
    required this.rows,
    required this.action,
    required this.onAction,
    this.subtitle,
    this.secondary,
    this.onSecondary,
  });

  final String title;
  final String? subtitle;
  final Color accent;
  final List<_Row> rows;
  final String action;
  final VoidCallback onAction;

  /// A quieter second action under the first, when there is one.
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final ranked = List.of(rows)..sort((a, b) => a.total.compareTo(b.total));

    // The sheet comes in over a quarter of a second — the scrim
    // darkening, the card settling — rather than landing in a frame.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Container(
        color: Colors.black.withValues(alpha: 0.62 * t),
        child: Opacity(
          opacity: t,
          child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: Container(
            margin: const EdgeInsets.all(22),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            constraints: const BoxConstraints(maxWidth: 380),
            decoration: BoxDecoration(
              color: Felt.mid,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: accent.withValues(alpha: 0.45)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 34),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim)),
                ],
                const SizedBox(height: 16),
                for (final row in ranked) _ScoreRow(row: row),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onAction,
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Felt.dark,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(action,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
                if (secondary != null) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: onSecondary,
                    style: TextButton.styleFrom(foregroundColor: Palette.chromeDim),
                    child: Text(secondary!, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.row});

  final _Row row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.name,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: row.you ? FontWeight.w700 : FontWeight.w500,
                color: row.you ? Palette.gold : Palette.chrome,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              row.delta == 0 ? '—' : '+${row.delta}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: row.delta == 0 ? Palette.chromeDim : Palette.danger,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${row.total}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                color: Palette.chrome,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
