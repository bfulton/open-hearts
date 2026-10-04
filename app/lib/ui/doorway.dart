/// The shape of the front door, and of the two screens that stand in
/// for it: waiting to be seated, and a room that is filling.
///
/// At the door the heart and the app's name are the top of a column
/// with everything else under them. The other two have one thing to
/// say and say it in the middle of the screen, with no name over it —
/// by then you know what you are looking at — and the heart up out of
/// the way.
///
/// A phone on its side has the width for two columns and not the height
/// for one, so there the door puts the heart, the name and the tagline
/// on the left and what can be pressed on the right, rather than a
/// column that scrolls.
///
/// The heart is handed in rather than built here so that the same one
/// carries across the change: were it built in each shape, the fold it
/// is part way through would start over every time the screen changed
/// (ui/folding_heart.dart).
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

class Doorway extends StatelessWidget {
  const Doorway({super.key, required this.heart, required this.title, this.tagline, required this.child});

  /// The folding heart: one instance, whichever shape it is in.
  final Widget heart;

  /// Whether the app's name is under the heart — the front door only.
  final bool title;

  /// The line under the name, at the door.
  final String? tagline;

  /// What this state of the door has to say.
  final Widget child;

  /// Wide enough for a phone, and no wider on anything else.
  static const maxWidth = 380.0;

  /// Shorter than this and wider than [sideBySideWidth], the door is
  /// two columns: below this height the column overflows a phone on its
  /// side, and a tablet, however it is turned, is taller.
  static const sideBySideHeight = 520.0;
  static const sideBySideWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    if (!title) {
      return Column(
        children: [
          const SizedBox(height: 6),
          heart,
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
                child: _column([child]),
              ),
            ),
          ),
        ],
      );
    }
    final name = [
      // Centred, so that a column stretched to its widest does not
      // stretch the heart with it.
      Center(child: heart),
      const SizedBox(height: 12),
      const Text('Open Hearts',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Palette.mark)),
      if (tagline != null) ...[
        const SizedBox(height: 18),
        Text(tagline!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: Palette.chromeDim)),
      ],
    ];
    return LayoutBuilder(builder: (context, room) {
      if (room.maxHeight < sideBySideHeight && room.maxWidth >= sideBySideWidth) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(mainAxisSize: MainAxisSize.min, children: name),
                  ),
                ),
              ),
              const SizedBox(width: 22),
              SizedBox(
                // The buttons as wide as they are anywhere, unless that
                // would leave the name no room.
                width: min(maxWidth, (room.maxWidth - 66) * 0.6),
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _column([child]),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: _column([...name, const SizedBox(height: 22), child]),
        ),
      );
    });
  }

  static Widget _column(List<Widget> children) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
}
