/// What this is, and which build of it is running.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'build_info.dart';
import 'l10n/l10n.dart';
import 'subscribe_page.dart' show legalPage, openLink;
import 'theme.dart';

/// Where the code is, and its licence.
final projectSource = Uri.parse('https://github.com/bfulton/open-hearts');
final projectLicense = Uri.parse('https://github.com/bfulton/open-hearts/blob/main/LICENSE');

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.languages = kIsWeb});

  /// Whether the page offers a choice of language: on the web, where a
  /// browser's language is all there is to go on. A phone has its own
  /// setting for each app's language, and the app follows that.
  final bool languages;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: pageBar(context.l10n.about),
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
                if (languages) ...[
                  const SizedBox(height: 8),
                  const _LanguagePick(),
                ],
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    _Link(context.l10n.sourceCode, projectSource),
                    _Link(context.l10n.licenseName, projectLicense),
                    _Link(context.l10n.privacyShort, legalPage('privacy')),
                    _Link(context.l10n.termsShort, legalPage('terms')),
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

/// The language the app is drawn in: the browser's, or one chosen
/// here, kept for next time and taken up at once (l10n/l10n.dart).
class _LanguagePick extends StatelessWidget {
  const _LanguagePick();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A wrap, so a long name in a narrow window goes under the label
    // rather than off the side.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        Text(l10n.language, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
        DropdownButton<String?>(
          value: appLanguage.value?.languageCode,
          isDense: true,
          underline: const SizedBox(),
          dropdownColor: Felt.mid,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.chrome),
          items: [
            DropdownMenuItem(value: null, child: Text(l10n.deviceLanguage)),
            for (final MapEntry(key: code, value: name) in languageNames.entries)
              DropdownMenuItem(value: code, child: Text(name)),
          ],
          onChanged: (code) => choose(code == null ? null : Locale(code)),
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
