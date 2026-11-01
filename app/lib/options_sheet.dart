/// Choosing the next game: how far it plays, and whether it counts.
/// Opened from the live area of the front door and kept on the device
/// (game_options.dart), since it is the same choice every time until
/// the player changes it.
library;

import 'package:flutter/material.dart';

import 'game_options.dart';
import 'l10n/l10n.dart';
import 'theme.dart';

/// Opens the options over [context]; resolves to the options as the
/// player left them, whether they closed the sheet with Done, by
/// swiping it away or by tapping outside it, or to null if they changed
/// nothing.
Future<GameOptions?> showGameOptions(BuildContext context, {required GameOptions current}) async {
  var latest = current;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Felt.mid,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _OptionsSheet(current: current, onChanged: (options) => latest = options),
  );
  return latest == current ? null : latest;
}

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.current, required this.onChanged});

  final GameOptions current;

  /// Told of every pick, as it is made.
  final ValueChanged<GameOptions> onChanged;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late GameOptions _options = widget.current;

  void _pick(GameOptions options) {
    setState(() => _options = options);
    widget.onChanged(options);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(l10n.gameOptions, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.chrome)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(foregroundColor: Palette.gold),
                  child: Text(l10n.done, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SectionHeading(l10n.gameEndsAt),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final target in GameOptions.targets)
                  _Pick(
                    label: l10n.targetPoints(target),
                    selected: _options.target == target,
                    onTap: () => _pick(_options.copyWith(target: target)),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SectionHeading(l10n.ratedMovesRatings),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Pick(label: l10n.rated, selected: _options.rated, onTap: () => _pick(_options.copyWith(rated: true))),
                _Pick(label: l10n.unrated, selected: !_options.rated, onTap: () => _pick(_options.copyWith(rated: false))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One of a pair: a pill, filled in gold when it is the choice.
class _Pick extends StatelessWidget {
  const _Pick({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
            decoration: BoxDecoration(
              color: selected ? Palette.gold : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? Palette.gold : Colors.white.withValues(alpha: 0.25)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: selected ? Felt.dark : Palette.chrome,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
