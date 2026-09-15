/// The shape of the front door, and of the two screens that stand in
/// for it: waiting to be seated, and a room that is filling.
///
/// At the door the heart and the app's name are the top of a column
/// with everything else under them. The other two have one thing to
/// say and say it in the middle of the screen, with no name over it —
/// by then you know what you are looking at — and the heart up out of
/// the way.
///
/// The heart is handed in rather than built here so that the same one
/// carries across the change: were it built in each shape, the fold it
/// is part way through would start over every time the screen changed
/// (ui/folding_heart.dart).
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class Doorway extends StatelessWidget {
  const Doorway({super.key, required this.heart, required this.title, required this.child});

  /// The folding heart: one instance, whichever shape it is in.
  final Widget heart;

  /// Whether the app's name is under the heart — the front door only.
  final bool title;

  /// What this state of the door has to say.
  final Widget child;

  /// Wide enough for a phone, and no wider on anything else.
  static const maxWidth = 380.0;

  @override
  Widget build(BuildContext context) {
    if (title) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: _column([
            // Centred, so that a column stretched to its widest does
            // not stretch the heart with it.
            Center(child: heart),
            const SizedBox(height: 12),
            const Text('Open Hearts',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Palette.gold)),
            const SizedBox(height: 18),
            child,
          ]),
        ),
      );
    }
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

  static Widget _column(List<Widget> children) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
}
