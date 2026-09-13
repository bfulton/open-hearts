/// The player's hand: an overlapping fan sized to whatever width it gets.
///
/// Thirteen cards do not fit side by side on a phone, so they overlap and
/// each card offers a sliver to tap. Two things make the sliver usable:
/// suits are separated by a visible gap, and whatever cannot be played
/// right now is dimmed, so the bright ones read as "these". Nothing
/// moves until the player moves it: the cards picked for a pass lift,
/// and a card being dragged follows the finger.
///
/// A card is played by a tap, or by dragging it up towards the table:
/// past a third of its height it rings gold to say a release will play
/// it, and short of that it drops back. On a full hand a tap lands on
/// a sliver and can land on the neighbour; a drag shows which card is
/// coming before it is committed.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart' as engine;
import 'card_view.dart';

/// Extra space between two suits in the fan. Grouping is most of what
/// makes a 13-card row scannable.
const _suitGap = 11.0;

/// How high a card rises when it is picked for the pass.
const _lift = 13.0;

class HandFan extends StatefulWidget {
  const HandFan({
    super.key,
    required this.hand,
    required this.onTap,
    this.playable = const {},
    this.selected = const {},
    this.dimUnplayable = false,
    this.forced,
    this.justReceived = const {},
    this.spread = 0.64,
  });

  /// Sorted; the fan draws it in the order given.
  final List<engine.Card> hand;

  /// A card the player has committed to: tapped, or dragged up and let
  /// go. The same thing either way.
  final ValueChanged<engine.Card> onTap;

  /// Cards that can be played (or picked) right now.
  final Set<engine.Card> playable;

  /// Cards chosen for the pass.
  final Set<engine.Card> selected;

  /// Grey everything outside [playable]. False while nothing is being
  /// asked of the player, so the hand does not flash grey between turns.
  final bool dimUnplayable;

  /// The single card the rules leave — ringed, because being forced is
  /// worth seeing rather than discovering.
  final engine.Card? forced;

  /// Cards that arrived in the pass. Dotted for the first trick, so the
  /// three new cards are findable in a hand you have already read once.
  final Set<engine.Card> justReceived;

  /// How much of each card the fan shows at most, as a fraction of its
  /// width: the step between neighbours never exceeds this. A landscape
  /// hand has the width to show more of every card.
  final double spread;

  /// How far up a card has to be dragged, as a fraction of its height,
  /// for letting go to play it.
  static const dragToPlay = 0.33;

  @override
  State<HandFan> createState() => _HandFanState();
}

class _HandFanState extends State<HandFan> {
  /// The card under the finger, and how far it has come from its place.
  engine.Card? _dragging;
  double _dragDy = 0;

  @override
  void didUpdateWidget(HandFan old) {
    super.didUpdateWidget(old);
    if (_dragging != null && !widget.hand.contains(_dragging)) {
      _dragging = null;
      _dragDy = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hand = widget.hand;
    if (hand.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final n = hand.length;
        final gaps = _suitGaps(hand);
        final available = constraints.maxWidth - gaps * _suitGap;

        // Cards are as large as the row allows, capped so a short hand
        // does not turn into playing-card billboards.
        var width = constraints.maxHeight > 0
            ? (constraints.maxHeight - _lift - 6) * cardAspect
            : 62.0;
        width = width.clamp(40.0, 76.0);
        // Then shrunk if even at full overlap the row would spill.
        final maxStep = width * widget.spread;
        var step = n > 1 ? (available - width) / (n - 1) : 0.0;
        if (step > maxStep) step = maxStep;
        if (step < width * 0.22) {
          // Too tight even overlapped: give the cards back some width by
          // shrinking them instead of letting the row overflow.
          final fitted = n > 1
              ? available / (1 + (n - 1) * 0.30)
              : available;
          width = fitted.clamp(30.0, width);
          step = width * 0.30;
        }

        final cardHeight = cardHeightFor(width);
        final height = cardHeight + _lift;
        final rowWidth = width + step * (n - 1) + gaps * _suitGap;
        final left0 = ((constraints.maxWidth - rowWidth) / 2).clamp(0.0, 1e6);
        final threshold = math.max(28.0, cardHeight * HandFan.dragToPlay);

        var x = left0;
        final children = <Widget>[];
        Widget? dragged;
        for (var i = 0; i < n; i++) {
          final card = hand[i];
          if (i > 0 && card.suit != hand[i - 1].suit) x += _suitGap;
          final isSelected = widget.selected.contains(card);
          final isPlayable = widget.playable.contains(card);
          final dragging = _dragging == card;
          final dy = dragging ? _dragDy : 0.0;
          final beyond = dragging && _pastThreshold(dy, isSelected, threshold);
          final child = Positioned(
            // Keyed, so the card under the finger can be drawn last —
            // over its neighbours — without losing its place or state.
            key: ValueKey(card),
            left: x,
            bottom: 0,
            child: AnimatedContainer(
              // Under the finger the card follows it; let go, it settles
              // back or up over a few frames.
              duration: dragging ? Duration.zero : const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, (isSelected ? -_lift : 0) + dy, 0),
              // One semantics node per card — its name, and the tap —
              // so a screen reader, and the end-to-end suite, can play
              // it by name.
              child: MergeSemantics(
                child: Semantics(
                  button: true,
                  label: card.spoken,
                  selected: isSelected,
                  enabled: !widget.dimUnplayable || isPlayable,
                  onTap: () => widget.onTap(card),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onTap(card),
                    onVerticalDragStart: (_) => setState(() {
                      _dragging = card;
                      _dragDy = 0;
                    }),
                    onVerticalDragUpdate: (d) => setState(() {
                      // Up as far as the trick, roughly; down only for a
                      // picked card, far enough to unpick it.
                      _dragDy = (_dragDy + d.delta.dy).clamp(-cardHeight * 1.4, isSelected ? _lift + threshold : 0.0);
                    }),
                    onVerticalDragEnd: (_) => _release(card, isSelected, threshold),
                    onVerticalDragCancel: _settle,
                    child: ExcludeSemantics(
                      child: CardView(
                        card: card,
                        width: width,
                        dimmed: widget.dimUnplayable && !isPlayable,
                        selected: isSelected,
                        highlighted: card == widget.forced || (beyond && (isPlayable || !widget.dimUnplayable)),
                        marked: widget.justReceived.contains(card),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          if (dragging) {
            dragged = child;
          } else {
            children.add(child);
          }
          x += step;
        }
        if (dragged != null) children.add(dragged);

        return SizedBox(
          height: height,
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }

  /// Far enough up to play, or — for a card picked for the pass — far
  /// enough back down to unpick.
  static bool _pastThreshold(double dy, bool isSelected, double threshold) =>
      dy <= -threshold || (isSelected && dy >= threshold);

  void _release(engine.Card card, bool isSelected, double threshold) {
    final dy = _dragDy;
    _settle();
    if (_pastThreshold(dy, isSelected, threshold)) widget.onTap(card);
  }

  void _settle() => setState(() {
        _dragging = null;
        _dragDy = 0;
      });

  /// Number of suit boundaries in a sorted hand.
  static int _suitGaps(List<engine.Card> hand) {
    var n = 0;
    for (var i = 1; i < hand.length; i++) {
      if (hand[i].suit != hand[i - 1].suit) n++;
    }
    return n;
  }
}
