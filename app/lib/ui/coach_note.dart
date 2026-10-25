/// What the table says while a hand is taught (tutorial.dart): a note
/// in the room the felt gives it (ui/table_layout.dart, note), and Next
/// where the table waits on it.
///
/// Made like the score sheet (ui/overlays.dart), smaller: the felt's
/// own green, a light edge, and the one gold thing the button. A
/// screen reader says each note as it comes, as the sheet's title is
/// said: the note is a live region.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class CoachNote extends StatelessWidget {
  const CoachNote({super.key, required this.text, this.next, this.onNext});

  final String text;

  /// The button's label, where the table waits for the note to be read;
  /// none where it waits on the player's cards instead.
  final String? next;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: EdgeInsets.fromLTRB(16, 12, 16, next == null ? 12 : 4),
        decoration: BoxDecoration(
          color: Felt.mid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Palette.chrome.withValues(alpha: 0.3)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 22)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // All of it, at ordinary type on any screen; at the larger
            // type, where that would be more than the note's share of
            // the table (ui/table_layout.dart), it scrolls, with Next
            // still under it.
            Flexible(
              child: SingleChildScrollView(child: Text(text, style: const TextStyle(fontSize: 14.5, height: 1.35, color: Palette.chrome))),
            ),
            if (next != null)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: onNext,
                  style: TextButton.styleFrom(foregroundColor: Palette.gold),
                  child: Text(next!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
