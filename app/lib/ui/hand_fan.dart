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
///
/// Cards leave and arrive on their own account, and the fan carries
/// them: a played card rises towards the table, the three passed go
/// off the side of the screen the player they are passed to sits on,
/// and the three that come back fly in from the side the passer sits
/// on. The rest of the hand closes the gap rather than snapping shut.
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

/// One frame at sixty a second: what a card that has just been let go
/// has already had, by the time anything can be drawn about it.
const _aFrame = Duration(milliseconds: 16);

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
    this.passTo,
    this.receivedFrom,
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

  /// Which way off the screen a card that leaves the hand goes, while
  /// there is a pass on: the direction the seat it is passed to lies
  /// in (ui/table_view.dart). Null through the play, where a card that
  /// leaves has been played and goes up to the table instead.
  final Offset? passTo;

  /// Which way the cards in [justReceived] came in from: the direction
  /// the seat that passed them lies in. Null when nothing was passed.
  final Offset? receivedFrom;

  /// How much of each card the fan shows at most, as a fraction of its
  /// width: the step between neighbours never exceeds this. A landscape
  /// hand has the width to show more of every card.
  final double spread;

  /// The spread in each composition.
  static double spreadFor({required bool landscape}) => landscape ? 0.8 : 0.64;

  /// How wide a card in the fan is in a row [height] tall, before a
  /// narrow row shrinks it.
  static double cardWidthFor(double height) =>
      (height > 0 ? (height - _lift - 6) * cardAspect : 62.0).clamp(40.0, 76.0);

  /// How wide a whole hand's fan is in a row [height] tall with width
  /// to spare: thirteen cards at the widest step [spread] allows, and
  /// the gaps between four suits. The action line spans this, so it is
  /// as wide as the hand it is about (table_layout.dart).
  static double fullWidth(double height, double spread) {
    final width = cardWidthFor(height);
    return width + (engine.Rank.values.length - 1) * width * spread + (engine.Suit.values.length - 1) * _suitGap;
  }

  /// How far up a card has to be dragged, as a fraction of its height,
  /// for letting go to play it.
  static const dragToPlay = 0.33;

  @override
  State<HandFan> createState() => _HandFanState();
}

/// A card the fan is carrying: one that has left the hand and is still
/// on its way out, or one that has just arrived and is still on its way
/// in. [travel] is the whole journey — a card on its way out starts at
/// the fan and ends there, a card on its way in starts there and ends
/// at the fan — and [places] is where each card's left edge sat in the
/// fan, which is the end a flight has in common either way.
class _Flight {
  _Flight({required this.places, required this.from, required this.travel, required this.width, required this.out, required this.controller});

  final Map<engine.Card, double> places;

  /// Where the journey starts, off the fan's own place: nowhere,
  /// unless the card was let go mid-drag, where it is where the finger
  /// left it.
  final Offset from;
  final Offset travel;
  final double width;
  final bool out;
  final AnimationController controller;
}

class _HandFanState extends State<HandFan> with TickerProviderStateMixin {
  /// The card under the finger, and how far it has come from its place.
  engine.Card? _dragging;
  double _dragDy = 0;

  /// Where the last build put each card — its left edge — and how wide
  /// it drew them. A card that has left the hand has no place in the
  /// fan any more, so this is where its flight starts.
  final _places = <engine.Card, double>{};
  double _placeWidth = 0;

  /// What is in the air. Each drops itself when it lands.
  final _flights = <_Flight>[];

  /// The card the player dragged up and let go, and how far up it was
  /// when they did: it leaves from there rather than snapping back to
  /// its place first. Cleared by the flight that uses it.
  (engine.Card, double)? _released;

  @override
  void dispose() {
    for (final flight in _flights) {
      flight.controller.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(HandFan old) {
    super.didUpdateWidget(old);
    if (_dragging != null && !widget.hand.contains(_dragging)) {
      _dragging = null;
      _dragDy = 0;
    }
    // Whoever asked for no animation gets none: the cards are simply
    // where they now are.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return;
    final now = widget.hand.toSet();
    final before = old.hand.toSet();
    _launch(before.difference(now), out: true);
    _launch(now.difference(before).intersection(widget.justReceived), out: false);
  }

  /// Sends [cards] on their way. A play is one card and a pass is
  /// three; thirteen at once is a hand ending or a new one dealt, which
  /// is not a movement anyone follows, so it is left to happen.
  void _launch(Set<engine.Card> cards, {required bool out}) {
    if (cards.isEmpty || cards.length > engine.passSize) return;
    final size = MediaQuery.sizeOf(context);
    // A pass leaves the screen on the side its player sits on; a play
    // rises out of the hand towards the table, where the trick takes it
    // up from the same side (ui/table_view.dart).
    final side = out ? widget.passTo : widget.receivedFrom;
    if (!out && side == null) return;
    final travel = side == null
        ? Offset(0, -cardHeightFor(_placeWidth) * 1.5)
        : Offset(side.dx * size.width * 0.8, side.dy * size.height * 0.8);
    final released = _released;
    _released = null;
    final flight = _Flight(
      places: {for (final card in cards) card: _places[card] ?? 0},
      from: out && cards.length == 1 && released?.$1 == cards.first ? Offset(0, released!.$2) : Offset.zero,
      travel: travel,
      width: _placeWidth,
      out: out,
      controller: AnimationController(
        vsync: this,
        duration: Duration(milliseconds: side == null ? 240 : 420),
      ),
    );
    flight.controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // Off the list before it is disposed, so a teardown that lands in
      // the same breath does not dispose it twice.
      _flights.remove(flight);
      flight.controller.dispose();
      if (mounted) setState(() {});
    });
    // No setState: this is a widget update, and the build is next.
    _flights.add(flight);
    // A frame in, not from nothing. The tap happened during the frame
    // that is about to be drawn, and a controller's first tick is the
    // frame after that — so a flight started at zero spends its first
    // drawn frame exactly where the card already was. That frame is
    // the whole of what a hand still holding cards hides, and what the
    // last card of a hand has nothing to hide it with.
    flight.controller.forward(from: _aFrame.inMicroseconds / flight.controller.duration!.inMicroseconds);
  }

  /// The flight carrying [card] into the fan, if one is.
  _Flight? _arriving(engine.Card card) {
    for (final flight in _flights) {
      if (!flight.out && flight.places.containsKey(card)) return flight;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hand = widget.hand;
    // Nothing held and nothing in the air. The last card of a hand
    // leaves an empty fan behind it, and it still has to be seen going.
    if (hand.isEmpty && _flights.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final n = hand.length;
        final gaps = _suitGaps(hand);
        // An empty fan is a moment, not a layout: the cards still on
        // screen are flights, drawn where the last full fan put them.
        if (n == 0) return SizedBox(height: constraints.maxHeight, child: Stack(clipBehavior: Clip.none, children: _departing()));
        final available = constraints.maxWidth - gaps * _suitGap;

        // Cards are as large as the row allows, capped so a short hand
        // does not turn into playing-card billboards.
        var width = HandFan.cardWidthFor(constraints.maxHeight);
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
        final places = <engine.Card, double>{};
        Widget? dragged;
        for (var i = 0; i < n; i++) {
          final card = hand[i];
          if (i > 0 && card.suit != hand[i - 1].suit) x += _suitGap;
          places[card] = x;
          final isSelected = widget.selected.contains(card);
          final isPlayable = widget.playable.contains(card);
          final dragging = _dragging == card;
          final dy = dragging ? _dragDy : 0.0;
          final beyond = dragging && _pastThreshold(dy, isSelected, threshold);
          final arriving = _arriving(card);
          final child = AnimatedPositioned(
            // Keyed, so the card under the finger can be drawn last —
            // over its neighbours — without losing its place or state.
            key: ValueKey(card),
            // The hand closes over a card that has gone, and opens for
            // one that has come, rather than snapping to the new fan.
            // Under the finger there is nothing to catch up with.
            duration: dragging ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: x,
            bottom: 0,
            child: _carried(arriving, AnimatedContainer(
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
            )),
          );
          if (dragging) {
            dragged = child;
          } else {
            children.add(child);
          }
          x += step;
        }
        if (dragged != null) children.add(dragged);

        // Where this build put them, for the flight of whatever leaves
        // next: a card that has gone has no place here to start from.
        _places
          ..clear()
          ..addAll(places);
        _placeWidth = width;

        // On top of the fan, the cards that have left it: drawn where
        // they sat and carried away, so the hand is seen to give them
        // up rather than to have one fewer.
        children.addAll(_departing());

        return SizedBox(
          height: height,
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }

  /// The cards that have left the hand and are still on their way out,
  /// each drawn where the fan last put it and carried from there.
  List<Widget> _departing() => [
        for (final flight in _flights)
          if (flight.out)
            for (final gone in flight.places.entries)
              Positioned(
                left: gone.value,
                bottom: 0,
                child: AnimatedBuilder(
                  animation: flight.controller,
                  builder: (context, card) {
                    // Out at speed, not up to speed: a card leaves on
                    // the frame it is tapped, the way a thrown thing
                    // leaves the hand at its fastest. Easing in instead
                    // held it still for three frames, which is only
                    // hidden while the rest of the fan is closing over
                    // the gap — and the last card of a hand has no rest
                    // of the fan.
                    final t = Curves.easeOutCubic.transform(flight.controller.value);
                    return Transform.translate(
                      offset: Offset.lerp(flight.from, flight.travel, t)!,
                      child: Opacity(opacity: (1 - t * 1.3).clamp(0.0, 1.0), child: card),
                    );
                  },
                  child: IgnorePointer(
                    child: ExcludeSemantics(child: CardView(card: gone.key, width: flight.width)),
                  ),
                ),
              ),
      ];

  /// A card on its way into the fan, drawn short of its place by
  /// however much of the journey is left. Anything else is itself.
  Widget _carried(_Flight? flight, Widget card) {
    if (flight == null) return card;
    return AnimatedBuilder(
      animation: flight.controller,
      builder: (context, child) => Transform.translate(
        offset: flight.travel * (1 - Curves.easeOutCubic.transform(flight.controller.value)),
        child: child,
      ),
      child: card,
    );
  }

  /// Far enough up to play, or — for a card picked for the pass — far
  /// enough back down to unpick.
  static bool _pastThreshold(double dy, bool isSelected, double threshold) =>
      dy <= -threshold || (isSelected && dy >= threshold);

  void _release(engine.Card card, bool isSelected, double threshold) {
    final dy = _dragDy;
    _settle();
    if (!_pastThreshold(dy, isSelected, threshold)) return;
    // Dragged up and let go: if that plays it, its flight to the table
    // carries on from here rather than starting over.
    if (!isSelected) _released = (card, dy);
    widget.onTap(card);
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
