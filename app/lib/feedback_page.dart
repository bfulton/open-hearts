/// Tell us what's broken: the one way a player reaches us from inside
/// the app.
///
/// A sentence in the player's words, and under it everything that goes
/// with it, shown in full before it goes — the build, the platform, the
/// language, the size of the screen, and, from a solo table and only if
/// asked, the game's record, which replays every trick of it
/// (packages/engine, solo_record.dart). Nothing else about the device
/// is read, and nothing is sent until the player sends it.
///
/// Where it goes is the operator's to say (net/remote_config.dart,
/// `feedback`): a page, or an address to mail. Until they say, it is
/// the project's issues on GitHub, which anyone can read, and the page
/// says so where the button is. A build that cannot open a page — the
/// phone builds, for now — copies the report instead, and says where to.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'build_info.dart';
import 'l10n/l10n.dart';
import 'net/copy.dart';
import 'net/remote_config.dart';
import 'net/share.dart';
import 'theme.dart';

/// Where a report goes when the operator has said nothing.
final projectIssues = Uri.parse('https://github.com/bfulton/open-hearts/issues/new');

Future<void> showFeedback(BuildContext context, {String? record}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeedbackPage(record: record)));

/// A report: what the player wrote, then what goes with it. The labels
/// are English whatever the app's language — they are for whoever
/// reads the report — and the player's own words are as they wrote them.
String reportOf({required String said, required Map<String, String> about}) => [
      said.trim(),
      '',
      '---',
      for (final MapEntry(:key, :value) in about.entries) '$key: $value',
    ].join('\n');

/// The address that carries [report] to [to]: GitHub's new-issue page
/// with the report filled in, a mail with it as the body, or another
/// page as it is — the report then goes by the clipboard.
Uri sendingTo(Uri to, {required String title, required String report}) {
  if (to.scheme == 'mailto') {
    return Uri.parse('mailto:${to.path}?subject=${Uri.encodeComponent(title)}&body=${Uri.encodeComponent(report)}');
  }
  if (to.host == 'github.com' && to.path.endsWith('/issues/new')) {
    return to.replace(queryParameters: {...to.queryParameters, 'title': title, 'body': report});
  }
  return to;
}

/// Whether [to] takes the report in its address, rather than by the
/// clipboard.
bool carriesReport(Uri to) => to.scheme == 'mailto' || (to.host == 'github.com' && to.path.endsWith('/issues/new'));

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.record});

  /// The solo game's record, when the page was opened from its table.
  final String? record;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _said = TextEditingController();
  bool _withRecord = false;

  @override
  void dispose() {
    _said.dispose();
    super.dispose();
  }

  Map<String, String> _about(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return {
      'Build': '$buildTag ($buildDate)',
      'Platform': kIsWeb ? 'web on ${defaultTargetPlatform.name}' : defaultTargetPlatform.name,
      'Language': context.l10n.localeName,
      'Screen': '${size.width.round()}×${size.height.round()}',
      if (_withRecord && widget.record != null) 'Record': widget.record!,
    };
  }

  Future<void> _send() async {
    final l10n = context.l10n;
    final to = RemoteSettings.current.config.feedback ?? projectIssues;
    final said = _said.text.trim();
    final firstLine = said.split('\n').first;
    final title = firstLine.isEmpty
        ? 'Something is broken'
        : firstLine.length > 80
            ? '${firstLine.substring(0, 79)}…'
            : firstLine;
    final report = reportOf(said: said, about: _about(context));
    final opened = openBeside(sendingTo(to, title: title, report: report));
    if (opened && carriesReport(to)) return;
    // A page that does not take the report in its address, or no way
    // to open one: the report goes by the clipboard, and the player is
    // told where it is going.
    await copyText(opened ? report : '$report\n\n$to');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(opened ? l10n.feedbackCopied : l10n.feedbackCopiedTo(to.toString()), textAlign: TextAlign.center),
        duration: const Duration(seconds: 4),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final to = RemoteSettings.current.config.feedback ?? projectIssues;
    final about = _about(context);
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(l10n.tellUsWhatsBroken, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.feedbackIntro, style: const TextStyle(fontSize: 14, height: 1.45, color: Palette.chrome)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _said,
                    minLines: 4,
                    maxLines: 10,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Palette.chrome, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: l10n.feedbackHint,
                      hintStyle: const TextStyle(color: Palette.chromeDim),
                      filled: true,
                      fillColor: Colors.black.withValues(alpha: 0.18),
                      counterStyle: const TextStyle(color: Palette.chromeDim),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  if (widget.record != null)
                    CheckboxListTile(
                      value: _withRecord,
                      onChanged: (v) => setState(() => _withRecord = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: Palette.gold,
                      title: Text(l10n.feedbackWithRecord, style: const TextStyle(fontSize: 13.5, color: Palette.chrome)),
                    ),
                  const SizedBox(height: 10),
                  Text(l10n.feedbackSentWithIt,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Palette.chromeDim, letterSpacing: 0.6)),
                  const SizedBox(height: 6),
                  // Exactly what goes, in the words it goes in.
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
                    child: SelectableText(
                      [for (final MapEntry(:key, :value) in about.entries) '$key: $value'].join('\n'),
                      style: const TextStyle(fontSize: 12, height: 1.45, color: Palette.chromeDim, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _said.text.trim().isEmpty ? null : _send,
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.gold,
                      foregroundColor: Felt.dark,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(l10n.feedbackSend, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                  ),
                  if (to.host == 'github.com') ...[
                    const SizedBox(height: 8),
                    Text(l10n.feedbackIsPublic,
                        textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, height: 1.4, color: Palette.chromeDim)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
