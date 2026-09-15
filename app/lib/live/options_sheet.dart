/// Choosing the next game: how far it plays, and whether it counts.
/// Opened from the live area of the front door and kept on the device
/// (game_options.dart), since it is the same choice every time until
/// the player changes it.
library;

import 'package:flutter/material.dart';

import '../game_options.dart';
import '../theme.dart';

/// Opens the options over [context]; resolves to what was chosen, or
/// null if the sheet was dismissed without a change.
Future<GameOptions?> showGameOptions(BuildContext context, {required GameOptions current}) {
  return showModalBottomSheet<GameOptions>(
    context: context,
    backgroundColor: Felt.mid,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _OptionsSheet(current: current),
  );
}

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.current});

  final GameOptions current;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late GameOptions _options = widget.current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Game options', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.chrome)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_options),
                  style: TextButton.styleFrom(foregroundColor: Palette.gold),
                  child: const Text('Done', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _Heading('The game ends when someone reaches'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final target in GameOptions.targets)
                  _Pick(
                    label: '$target points',
                    selected: _options.target == target,
                    onTap: () => setState(() => _options = _options.copyWith(target: target)),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            const _Heading('Rated games move your rating, and the bots\''),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Pick(label: 'Rated', selected: _options.rated, onTap: () => setState(() => _options = _options.copyWith(rated: true))),
                _Pick(label: 'Unrated', selected: !_options.rated, onTap: () => setState(() => _options = _options.copyWith(rated: false))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim, letterSpacing: 0.3));
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
