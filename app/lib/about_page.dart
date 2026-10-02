/// What this is, and which build of it is running.
library;

import 'package:flutter/material.dart';

import 'build_info.dart';
import 'l10n/l10n.dart';
import 'subscribe_page.dart' show legalPage, openLink;
import 'theme.dart';

/// Where the code is, and its licence.
final projectSource = Uri.parse('https://github.com/bfulton/open-hearts');
final projectLicense = Uri.parse('https://github.com/bfulton/open-hearts/blob/main/LICENSE');

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(context.l10n.about, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 60),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.favorite, size: 40, color: Palette.mark),
                const SizedBox(height: 14),
                const Text('Open Hearts', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Palette.mark)),
                const SizedBox(height: 8),
                Text(
                  context.l10n.tagline,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, height: 1.45, color: Palette.chromeDim),
                ),
                const SizedBox(height: 30),
                _Line(label: context.l10n.build, value: buildTag),
                const SizedBox(height: 8),
                _Line(label: context.l10n.published, value: buildDate),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    _Link(context.l10n.sourceCode, projectSource),
                    _Link(context.l10n.licenseName, projectLicense),
                    _Link(context.l10n.privacyPolicy, legalPage('privacy')),
                    _Link(context.l10n.termsOfUse, legalPage('terms')),
                  ],
                ),
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

class _Link extends StatelessWidget {
  const _Link(this.label, this.url);

  final String label;
  final Uri url;

  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => openLink(url), child: Text(label));
}
