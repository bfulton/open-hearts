/// What this is, and which build of it is running.
library;

import 'package:flutter/material.dart';

import 'build_info.dart';
import 'theme.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: const Text('About', style: TextStyle(fontSize: 16, color: Palette.chromeDim)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 60),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.favorite, size: 40, color: Palette.gold),
                const SizedBox(height: 14),
                const Text('Open Hearts', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Palette.gold)),
                const SizedBox(height: 8),
                const Text(
                  'Hearts — free, open source, no accounts. Play alone against the house, or live: '
                  'the four of you deal the cards between you, and no server sees a hand.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, height: 1.45, color: Palette.chromeDim),
                ),
                const SizedBox(height: 30),
                _Line(label: 'Build', value: buildTag),
                const SizedBox(height: 8),
                _Line(label: 'Published', value: buildDate),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
        const SizedBox(width: 12),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
            color: Palette.chrome,
          ),
        ),
      ],
    );
  }
}
