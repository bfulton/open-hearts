/// Quick reactions at a live table (packages/table, reactions.dart): the
/// bubble beside a seat's badge, the button beside the player's own, and
/// the picker it opens. A fixed few — 👍 Nice, 😂 Ha, 😮 Wow, 😬 Ouch,
/// 🙏 Sorry, 👋 Good game — and no words of anybody's own, so there is
/// nothing on the felt anyone has to answer for.
///
/// Where each bubble goes is the felt's business (ui/table_view.dart):
/// beside the badge, in room nothing else is drawn in, and never over a
/// card. A bubble draws itself into whatever room it is given.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:table/table.dart' show Reaction;

import '../l10n/l10n.dart';
import '../reaction_mute.dart';
import '../theme.dart';

/// What [reaction] is called in this screen's language: "Nice".
String reactionWord(AppLocalizations l10n, Reaction reaction) => l10n.reaction(reaction.code);

/// A reaction for a moment beside a seat: the emoji and its word, on a
/// bubble whose tail points at the badge it belongs to. Drawn as large
/// as the reader's type makes it where it has the room, and smaller
/// where it has not; on one line where the room is wide, the word under
/// the emoji where it is tall.
///
/// Said to a screen reader as it appears — "Bonnie: Nice" — politely,
/// after whatever it is saying: a reaction is news, never a turn.
class ReactionBubble extends StatefulWidget {
  const ReactionBubble({super.key, required this.reaction, required this.name, this.tail = AxisDirection.down});

  final Reaction reaction;

  /// Whose it is, as a sentence says it.
  final String name;

  /// Which way the tail points: towards the badge.
  final AxisDirection tail;

  static const _padding = EdgeInsets.symmetric(horizontal: 9, vertical: 4);
  static const _emoji = TextStyle(fontSize: 17, height: 1.15);
  static const _word = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Felt.dark, height: 1.15);

  /// How far the tail stands out from the bubble.
  static const tailSize = 5.0;

  @override
  State<ReactionBubble> createState() => _ReactionBubbleState();
}

class _ReactionBubbleState extends State<ReactionBubble> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(View.of(context), _said, Directionality.of(context), assertiveness: Assertiveness.polite);
    });
  }

  String get _said => context.l10n.reactionSaid(widget.name, reactionWord(context.l10n, widget.reaction));

  @override
  Widget build(BuildContext context) {
    final word = reactionWord(context.l10n, widget.reaction);
    final tail = widget.tail;
    // The tail's room, on the side it points to.
    final out = EdgeInsets.only(
      left: tail == AxisDirection.left ? ReactionBubble.tailSize : 0,
      right: tail == AxisDirection.right ? ReactionBubble.tailSize : 0,
      top: tail == AxisDirection.up ? ReactionBubble.tailSize : 0,
      bottom: tail == AxisDirection.down ? ReactionBubble.tailSize : 0,
    );
    return Semantics(
      container: true,
      label: _said,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, room) {
            final scaler = MediaQuery.textScalerOf(context);
            Size laid(String text, TextStyle style) => (TextPainter(
                  text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
                  textDirection: Directionality.of(context),
                  textScaler: scaler,
                  maxLines: 1,
                )..layout())
                .size;
            final emoji = laid(widget.reaction.emoji, ReactionBubble._emoji);
            final said = laid(word, ReactionBubble._word);
            final pad = ReactionBubble._padding.add(out);
            final wide = Size(emoji.width + 4 + said.width + pad.horizontal, (emoji.height > said.height ? emoji.height : said.height) + pad.vertical);
            final tall = Size((emoji.width > said.width ? emoji.width : said.width) + pad.horizontal, emoji.height + said.height + pad.vertical);
            // One line unless the room is too narrow for it and the word
            // under the emoji is drawn the bigger of the two.
            double fits(Size s) => [room.maxWidth / s.width, room.maxHeight / s.height, 1.0].reduce((a, b) => a < b ? a : b);
            final stacked = fits(tall) > fits(wide) * 1.15;
            final face = Text(widget.reaction.emoji, style: ReactionBubble._emoji, maxLines: 1, softWrap: false);
            final words = Text(word, style: ReactionBubble._word, maxLines: 1, softWrap: false);
            return FittedBox(
              fit: BoxFit.scaleDown,
              child: CustomPaint(
                painter: _Bubble(tail),
                child: Padding(
                  padding: pad,
                  child: stacked
                      ? Column(mainAxisSize: MainAxisSize.min, children: [face, words])
                      : Row(mainAxisSize: MainAxisSize.min, children: [face, const SizedBox(width: 4), words]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The bubble's shape: a rounded card, the colour of a card's face, and
/// a short tail out of the middle of one side.
class _Bubble extends CustomPainter {
  _Bubble(this.tail);

  final AxisDirection tail;

  @override
  void paint(Canvas canvas, Size size) {
    const t = ReactionBubble.tailSize;
    final body = Rect.fromLTRB(
      tail == AxisDirection.left ? t : 0,
      tail == AxisDirection.up ? t : 0,
      size.width - (tail == AxisDirection.right ? t : 0),
      size.height - (tail == AxisDirection.down ? t : 0),
    );
    final c = body.center;
    final path = Path()..addRRect(RRect.fromRectAndRadius(body, const Radius.circular(11)));
    final tip = switch (tail) {
      AxisDirection.left => [Offset(body.left, c.dy - t), Offset(0, c.dy), Offset(body.left, c.dy + t)],
      AxisDirection.right => [Offset(body.right, c.dy - t), Offset(size.width, c.dy), Offset(body.right, c.dy + t)],
      AxisDirection.up => [Offset(c.dx - t, body.top), Offset(c.dx, 0), Offset(c.dx + t, body.top)],
      AxisDirection.down => [Offset(c.dx - t, body.bottom), Offset(c.dx, size.height), Offset(c.dx + t, body.bottom)],
    };
    path.addPolygon(tip, true);
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = Palette.cardFace);
  }

  @override
  bool shouldRepaint(_Bubble old) => old.tail != tail;
}

/// The speech bubble beside the player's own badge that opens the
/// reactions: quiet, the felt's own colour, and as big as a thumb can
/// find in the room it has.
class ReactionButton extends StatelessWidget {
  const ReactionButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  /// Its size where there is room: a thumb's.
  static const size = 40.0;

  @override
  Widget build(BuildContext context) {
    // Said as what it does, and pressed from a screen reader as by a
    // thumb.
    return Semantics(
      button: true,
      label: context.l10n.react,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Tooltip(
          message: context.l10n.react,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox.square(
              dimension: size,
              child: Material(
                color: Colors.black.withValues(alpha: 0.24),
                shape: CircleBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.10))),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPressed,
                  child: const Icon(Icons.chat_bubble_outline_rounded, size: 19, color: Palette.chrome),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The reactions to send, and the switch that hides everyone else's:
/// a small sheet over the table, gone with a pick. The pick, or null.
Future<Reaction?> pickReaction(BuildContext context) => showModalBottomSheet<Reaction>(
      context: context,
      backgroundColor: Felt.mid,
      // As tall as the six and the switch are at the reader's text size,
      // and no taller: at twice the type on a small phone that is most
      // of the screen, and it scrolls past that.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => const SafeArea(child: ReactionPicker()),
    );

/// The six, each a button with its emoji over its word, and under them
/// the switch for the others' reactions on this device.
class ReactionPicker extends StatelessWidget {
  const ReactionPicker({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in Reaction.values)
                // Said by its word: the emoji's own name is a screen
                // reader's, and not the reaction's.
                Semantics(
                  button: true,
                  label: reactionWord(l10n, r),
                  onTap: () => Navigator.of(context).pop(r),
                  child: ExcludeSemantics(
                    child: OutlinedButton(
                      key: ValueKey('react ${r.code}'),
                      onPressed: () => Navigator.of(context).pop(r),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Palette.chrome,
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        minimumSize: const Size(88, 56),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // A picture, the size of one whatever the
                          // type: the word under it is what grows.
                          Text(r.emoji, style: const TextStyle(fontSize: 24), textScaler: TextScaler.noScaling),
                          const SizedBox(height: 2),
                          Text(reactionWord(l10n, r), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ReactionMuteSwitch(),
        ],
      ),
    );
  }
}

/// Hides everyone else's reactions on this device, or shows them again
/// (reaction_mute.dart): under the picker, and under a game watched.
class ReactionMuteSwitch extends StatelessWidget {
  ReactionMuteSwitch({super.key, ReactionMute? mute}) : mute = mute ?? ReactionMute.current;

  final ReactionMute mute;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: mute,
      builder: (context, muted, _) => SwitchListTile(
        value: muted,
        onChanged: mute.set,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(context.l10n.hideReactions, style: const TextStyle(fontSize: 13.5, color: Palette.chrome)),
        activeThumbColor: Felt.dark,
        activeTrackColor: Palette.gold,
        inactiveThumbColor: Palette.chromeDim,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
      ),
    );
  }
}
