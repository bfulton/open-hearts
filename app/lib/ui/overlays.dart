/// The two moments the game stops for: the end of a hand and the end of
/// the game.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';
import '../theme.dart';

class HandOverSheet extends StatelessWidget {
  const HandOverSheet({super.key, required this.game, required this.names, required this.onNext});

  final HeartsGame game;
  final List<String> names;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final shooter = game.moonShooter;
    return _Sheet(
      title: shooter == null
          ? 'Hand ${game.handNumber + 1}'
          : shooter == humanSeat
              ? 'You shot the moon'
              : '${names[shooter]} shot the moon',
      accent: shooter == null
          ? Palette.gold
          : shooter == humanSeat
              ? Palette.gold
              : Palette.danger,
      subtitle: shooter == null
          ? null
          : shooter == humanSeat
              ? 'All 26 — everyone else takes them'
              : 'All 26 — everyone else takes them',
      rows: [
        for (var seat = 0; seat < seatCount; seat++)
          (
            name: names[seat],
            delta: game.handScores[seat],
            total: game.totals[seat],
            you: seat == humanSeat,
          ),
      ],
      action: 'Next hand',
      onAction: onNext,
    );
  }
}

class GameOverSheet extends StatelessWidget {
  const GameOverSheet({super.key, required this.game, required this.names, required this.onNewGame});

  final HeartsGame game;
  final List<String> names;
  final VoidCallback onNewGame;

  @override
  Widget build(BuildContext context) {
    final won = game.winners;
    final youWon = won.contains(humanSeat);
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
            you: seat == humanSeat,
          ),
      ],
      action: 'New game',
      onAction: onNewGame,
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
  });

  final String title;
  final String? subtitle;
  final Color accent;
  final List<_Row> rows;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final ranked = List.of(rows)..sort((a, b) => a.total.compareTo(b.total));

    return Container(
      color: Colors.black.withValues(alpha: 0.62),
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
