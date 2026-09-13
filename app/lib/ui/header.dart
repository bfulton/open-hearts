/// The line along the top of the table: the menu on the left, where the
/// game stands in the middle, and on the right a heart — whole until
/// hearts are broken, broken after.
library;

import 'package:flutter/material.dart';

import 'package:engine/engine.dart';

import '../theme.dart';

/// One entry on the table's menu.
class MenuAction {
  const MenuAction(this.label, {required this.icon, required this.onSelected});

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

class TableHeader extends StatelessWidget {
  const TableHeader({super.key, required this.game, required this.menu});

  final HeartsGame game;
  final List<MenuAction> menu;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final broken = game.heartsBroken;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.07))),
      ),
      child: Row(
        children: [
          _MenuButton(menu: menu),
          Expanded(
            child: Center(
              child: Text(
                'Hand ${game.handNumber + 1}  ·  ${game.passDirection.label}  ·  to $gameOverScore',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim, letterSpacing: 0.3),
              ),
            ),
          ),
          // Said in words for a screen reader, and for anything else that
          // reads the table through the accessibility tree.
          Semantics(
            label: broken ? 'Hearts are broken' : 'Hearts not broken',
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
/// under the button.
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.menu});

  final List<MenuAction> menu;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final picked = await showMenu<MenuAction>(
      context: context,
      position: position,
      color: Felt.mid,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      items: [
        for (final action in menu)
          PopupMenuItem<MenuAction>(
            value: action,
            child: Row(
              children: [
                Icon(action.icon, size: 18, color: Palette.chromeDim),
                const SizedBox(width: 12),
                Text(action.label, style: const TextStyle(fontSize: 14, color: Palette.chrome)),
              ],
            ),
          ),
      ],
    );
    picked?.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: 'Menu',
        onTap: () => _open(context),
        child: InkWell(
          onTap: () => _open(context),
          child: const ExcludeSemantics(
            child: SizedBox(
              width: 48,
              height: TableHeader.height,
              child: Icon(Icons.menu, size: 22, color: Palette.chromeDim),
            ),
          ),
        ),
      ),
    );
  }
}
