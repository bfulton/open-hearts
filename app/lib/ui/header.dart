/// The line along the top of the table: the menu on the left, where the
/// game stands in the middle, and on the right a heart — whole until
/// hearts are broken, broken after.
///
/// The menu itself is the front door's too (home_page.dart): one
/// control for the things that are not the game, wherever the app is.
library;

import 'package:engine/engine.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// One entry on the table's menu.
class MenuAction {
  const MenuAction(this.label, {required this.icon, required this.onSelected, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  /// Drawn red: an action that ends something, like leaving a table.
  final bool danger;
}

class TableHeader extends StatelessWidget {
  const TableHeader({super.key, required this.game, required this.menu});

  final HeartsGame game;
  final List<MenuAction> menu;

  /// The line's height, and the least of it: where the reader's type
  /// is large enough to take the line onto two, the header grows to
  /// hold them and the felt below gives up the room.
  static const height = 40.0;

  static const _style = TextStyle(fontSize: 11.5, color: Palette.chromeDim, letterSpacing: 0.3);

  @override
  Widget build(BuildContext context) {
    final broken = game.heartsBroken;
    return Container(
      constraints: const BoxConstraints(minHeight: height),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.07))),
      ),
      child: Row(
        children: [
          MenuButton(menu: menu),
          Expanded(
            child: Center(
              // Where the game stands is read, so it keeps the reader's
              // size: on two lines where one will not hold it, and where
              // even two will not — the largest type on a narrow phone —
              // without the score the game is played to, which is the
              // same all game, so that what changes from hand to hand is
              // all there.
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: LayoutBuilder(
                  builder: (context, room) {
                    final l10n = context.l10n;
                    final pass = l10n.pass(game.passDirection);
                    final full = l10n.handHeader(game.handNumber + 1, pass, game.target);
                    final fits = !(TextPainter(
                      text: TextSpan(text: full, style: DefaultTextStyle.of(context).style.merge(_style)),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                      maxLines: 2,
                    )..layout(maxWidth: room.maxWidth))
                        .didExceedMaxLines;
                    return Text(
                      fits ? full : l10n.handHeaderShort(game.handNumber + 1, pass),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _style,
                    );
                  },
                ),
              ),
            ),
          ),
          // Said in words for a screen reader, and for anything else that
          // reads the table through the accessibility tree.
          Semantics(
            label: broken ? context.l10n.heartsBroken : context.l10n.heartsNotBroken,
            child: ExcludeSemantics(
              child: SizedBox(
                width: 48,
                height: height,
                child: Icon(
                  broken ? Icons.heart_broken : Icons.favorite,
                  size: 20,
                  color: broken ? Palette.danger : Palette.red.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The menu: one semantics node, "Menu", a tap opening the entries
/// below the button, and a tap on it again shutting them.
class MenuButton extends StatelessWidget {
  const MenuButton({super.key, required this.menu, this.height = TableHeader.height});

  final List<MenuAction> menu;

  /// How tall the button is, so it fills the line it sits on — the
  /// table's, or the front door's.
  final double height;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    // Down from the button's foot rather than over it: the button stays
    // in sight, and a tap on it again shuts the menu (the tap lands on
    // the menu's barrier, which is what a tap anywhere off it does).
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(button.size.bottomLeft(Offset.zero), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    // The entries act on their own tap rather than on what showMenu
    // hands back, because what it hands back arrives only once the
    // menu has finished closing — a third of a second of a screen that
    // has been told what to do and is not doing it yet.
    await showMenu<void>(
      context: context,
      position: position,
      color: Felt.mid,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      items: [
        for (final action in menu)
          PopupMenuItem<void>(
            onTap: action.onSelected,
            child: Row(
              children: [
                Icon(action.icon, size: 18, color: action.danger ? Palette.danger : Palette.chromeDim),
                const SizedBox(width: 12),
                // A label longer than the menu is wide — a long one in a
                // long language — goes onto a second line rather than off
                // the side.
                Flexible(child: Text(action.label, style: TextStyle(fontSize: 14, color: action.danger ? Palette.danger : Palette.chrome))),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: context.l10n.menu,
        onTap: () => _open(context),
        child: InkWell(
          onTap: () => _open(context),
          child: ExcludeSemantics(
            child: SizedBox(
              width: 48,
              height: height,
              child: const Icon(Icons.menu, size: 22, color: Palette.chromeDim),
            ),
          ),
        ),
      ),
    );
  }
}
