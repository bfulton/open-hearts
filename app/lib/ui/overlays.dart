/// The two moments the game stops for: the end of a hand and the end of
/// the game.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';
import 'package:table/table.dart' show Rating;

import '../avatar.dart';
import '../l10n/l10n.dart';
import '../theme.dart';
import 'player_icon.dart';

class HandOverSheet extends StatelessWidget {
  const HandOverSheet({
    super.key,
    required this.handNumber,
    required this.scores,
    required this.totals,
    required this.moonShooter,
    required this.names,
    required this.onNext,
    this.seeds,
    this.avatars,
    this.mySeat = humanSeat,
    this.action,
  });

  /// Takes the numbers rather than the game: at a live table the game
  /// has already moved on to the next deal by the time this shows.
  factory HandOverSheet.of(HeartsGame game, {required List<String> names, List<String>? seeds, List<Avatar>? avatars, required VoidCallback onNext}) =>
      HandOverSheet(
        handNumber: game.handNumber,
        scores: game.handScores,
        totals: game.totals,
        moonShooter: game.moonShooter,
        names: names,
        seeds: seeds,
        avatars: avatars,
        onNext: onNext,
      );

  final int handNumber;
  final List<int> scores;
  final List<int> totals;
  final int? moonShooter;
  final List<String> names;

  /// What each seat's icon is coloured from, seat order; the names
  /// when null.
  final List<String>? seeds;

  /// How each seat chose to look, seat order; nothing when null.
  final List<Avatar>? avatars;
  final VoidCallback onNext;
  final int mySeat;

  /// The button's label, Next hand when null: at a live table the next
  /// hand is already under way, so it only dismisses.
  final String? action;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shooter = moonShooter;
    return _Sheet(
      title: shooter == null
          ? l10n.handNumber(handNumber + 1)
          : shooter == mySeat
              ? l10n.youShotTheMoon
              : l10n.shotTheMoon(names[shooter]),
      tone: shooter == null || shooter == mySeat ? Palette.chrome : Palette.danger,
      subtitle: shooter == null ? null : l10n.shotTheMoonDetail,
      rows: [
        for (var seat = 0; seat < seatCount; seat++)
          (
            name: names[seat],
            seed: (seeds ?? names)[seat],
            avatar: avatars?[seat],
            delta: scores[seat],
            total: totals[seat],
            you: seat == mySeat,
          ),
      ],
      action: action ?? l10n.nextHand,
      onAction: onNext,
    );
  }
}

/// What a rated game did to the player's rating: where it stood before
/// the result and where it stands with the result in it.
typedef RatingChange = ({Rating before, Rating after});

class GameOverSheet extends StatelessWidget {
  const GameOverSheet({
    super.key,
    required this.game,
    required this.names,
    required this.onNewGame,
    this.onCopyRecord,
    this.seeds,
    this.avatars,
    this.rating,
    this.mySeat = humanSeat,
    this.action,
  });

  final HeartsGame game;
  final List<String> names;

  /// What each seat's icon is coloured from, seat order; the names
  /// when null.
  final List<String>? seeds;

  /// How each seat chose to look, seat order; nothing when null.
  final List<Avatar>? avatars;
  final VoidCallback onNewGame;

  /// What the game moved this player's rating by, at a rated table.
  /// Null where there is nothing to say: a game against bots, an
  /// unrated table, or a new rating this device does not know yet —
  /// which is worth less than silence.
  final RatingChange? rating;

  final int mySeat;

  /// The button's label, New game when null.
  final String? action;

  /// Puts the game's record on the clipboard: a line that replays the
  /// whole game, for looking at a hand afterwards.
  final VoidCallback? onCopyRecord;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final won = game.winners;
    final youWon = won.contains(mySeat);
    final title = youWon
        ? (won.length > 1 ? l10n.aShareOfIt : l10n.youWin)
        : won.length > 1
            ? l10n.namesTie(l10n.together(won.map((s) => names[s])))
            : l10n.nameWins(names[won.first]);

    return _Sheet(
      title: title,
      tone: youWon ? Palette.chrome : Palette.danger,
      subtitle: l10n.lowestScoreAfter(game.handNumber + 1),
      rows: [
        for (var seat = 0; seat < seatCount; seat++)
          (
            name: names[seat],
            seed: (seeds ?? names)[seat],
            avatar: avatars?[seat],
            delta: game.handScores[seat],
            total: game.totals[seat],
            you: seat == mySeat,
          ),
      ],
      note: rating == null ? null : _RatingLine(change: rating!),
      action: action ?? l10n.newGame,
      onAction: onNewGame,
      secondary: onCopyRecord == null ? null : l10n.copyRecord,
      onSecondary: onCopyRecord,
    );
  }
}

typedef _Row = ({String name, String seed, Avatar? avatar, int delta, int total, bool you});

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.tone,
    required this.rows,
    required this.action,
    required this.onAction,
    this.subtitle,
    this.note,
    this.secondary,
    this.onSecondary,
  });

  final String title;
  final String? subtitle;

  /// What the sheet is *about*, which is never an action: white for a
  /// hand that ended or a game you won, red for one that went against
  /// you. The one gold thing on it is the button (theme.dart).
  final Color tone;
  final List<_Row> rows;

  /// A line under the score, where the sheet has something to say
  /// about it.
  final Widget? note;

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
              border: Border.all(color: tone.withValues(alpha: 0.45)),
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
                    color: tone,
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
                if (note != null) ...[
                  const SizedBox(height: 12),
                  note!,
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onAction,
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.gold,
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

/// What the game did to your rating: where it was and where it is now,
/// and the move itself beside it. A rating too new to be worth much
/// carries the question mark it carries everywhere else.
class _RatingLine extends StatelessWidget {
  const _RatingLine({required this.change});

  final RatingChange change;

  static String _shown(Rating r) => '${r.shown}${r.provisional ? '?' : ''}';

  @override
  Widget build(BuildContext context) {
    final moved = change.after.shown - change.before.shown;
    // Rounding can swallow a small move, and "+0" would read as a
    // number rather than as nothing happening.
    if (moved == 0) {
      return Text(context.l10n.ratingNow(_shown(change.after)),
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim));
    }
    // A wrap rather than a row: the move drops under the numbers on a
    // narrow screen instead of running off the side of the sheet.
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        Text(
          context.l10n.ratingMoved(_shown(change.before), _shown(change.after)),
          style: const TextStyle(fontSize: 13, color: Palette.chromeDim, fontFeatures: [FontFeature.tabularFigures()]),
        ),
        Text(
          moved > 0 ? '+$moved' : '$moved',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
            // What a game did to a rating is a number, not a button.
            color: moved > 0 ? Palette.chrome : Palette.danger,
          ),
        ),
      ],
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.row});

  final _Row row;

  @override
  Widget build(BuildContext context) {
    // One line for a screen reader, the numbers said as what they are:
    // drawn, they are two columns a sighted reader takes in at a glance.
    return Semantics(
      label: context.l10n.sheetRow(row.name, row.delta, row.total),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              PlayerIcon(name: row.name, seed: row.seed, avatar: row.avatar, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  row.name,
                  style: TextStyle(
                    fontSize: 14.5,
                    // Your own row is the weight, not the colour: which
                    // row is yours is a fact about the sheet.
                    fontWeight: row.you ? FontWeight.w700 : FontWeight.w500,
                    color: Palette.chrome,
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
        ),
      ),
    );
  }
}
