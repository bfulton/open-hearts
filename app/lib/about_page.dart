/// What this is, and which build of it is running.
library;

import 'package:flutter/material.dart';

import 'build_info.dart';
import 'ui/touch_probe.dart';
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
                // Five taps on the build switch the touch probe on or off
                // (ui/touch_probe.dart): a way to see where a tap lands on
                // a device that cannot be watched from here.
                _Taps(times: 5, onTaps: () => touchProbeOn.value = !touchProbeOn.value, child: _Line(label: context.l10n.build, value: buildTag)),
                const SizedBox(height: 8),
                _Line(label: context.l10n.published, value: buildDate),
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

class _Link extends StatelessWidget {
  const _Link(this.label, this.url);

  final String label;
  final Uri url;

  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => openLink(url), child: Text(label));
}

/// Calls [onTaps] at the [times]th tap in a row, each within a second of
/// the last.
class _Taps extends StatefulWidget {
  const _Taps({required this.times, required this.onTaps, required this.child});

  final int times;
  final VoidCallback onTaps;
  final Widget child;

  @override
  State<_Taps> createState() => _TapsState();
}

class _TapsState extends State<_Taps> {
  int _count = 0;
  DateTime _last = DateTime(0);

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () {
          final now = DateTime.now();
          _count = now.difference(_last) < const Duration(seconds: 1) ? _count + 1 : 1;
          _last = now;
          if (_count >= widget.times) {
            _count = 0;
            widget.onTaps();
          }
        },
        child: widget.child,
      );
}
