/// Tell us what's broken (feedback_page.dart): what goes, shown before
/// it goes; where it goes, as the operator says; and on a build that
/// cannot open a page, the report on the clipboard with where to take it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/feedback_page.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/theme.dart';

void main() {
  tearDown(() => RemoteSettings.current = RemoteSettings());

  test('a report is the player\'s words, then what goes with it', () {
    expect(reportOf(said: '  The queen vanished.\n', about: {'Build': 'abc (2026-10-01)', 'Language': 'de'}),
        'The queen vanished.\n\n---\nBuild: abc (2026-10-01)\nLanguage: de');
  });

  test('GitHub and mail take the report in the address; another page takes it from the clipboard', () {
    final issue = sendingTo(projectIssues, title: 'Stuck', report: 'It froze & stopped.\n---\nBuild: dev');
    expect(issue.host, 'github.com');
    expect(issue.queryParameters, {'title': 'Stuck', 'body': 'It froze & stopped.\n---\nBuild: dev'});
    expect(carriesReport(projectIssues), isTrue);

    final mail = sendingTo(Uri.parse('mailto:help@x.example'), title: 'Stuck here', report: 'a b\nc');
    expect(mail.toString(), 'mailto:help@x.example?subject=Stuck%20here&body=a%20b%0Ac',
        reason: 'spaces as %20: a mail client shows a + as a +');
    expect(carriesReport(Uri.parse('mailto:help@x.example')), isTrue);

    final form = Uri.parse('https://forms.example/hearts');
    expect(sendingTo(form, title: 't', report: 'r'), form);
    expect(carriesReport(form), isFalse);
  });

  test('the operator may send it elsewhere: a page or mail, nothing that runs', () {
    expect(RemoteConfig.parse({'feedback': 'mailto:help@x.example'}).feedback, Uri.parse('mailto:help@x.example'));
    expect(RemoteConfig.parse({'feedback': 'https://forms.example/h'}).feedback, Uri.parse('https://forms.example/h'));
    expect(RemoteConfig.parse({'feedback': 'javascript:alert(1)'}).feedback, isNull);
    expect(RemoteConfig.parse({'feedback': 'http://plain.example'}).feedback, isNull);
    expect(RemoteConfig.parse({'feedback': 'mailto:nobody'}).feedback, isNull);
  });

  testWidgets('what goes is on the page before it goes; nothing is sent without words', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const FeedbackPage(record: 'oh1:4:a,b,c::')));
    expect(find.textContaining('Build: dev (dev)'), findsOneWidget);
    expect(find.textContaining('Language: en'), findsOneWidget);
    expect(find.textContaining('Record:'), findsNothing, reason: 'the record goes only when asked');
    expect(find.textContaining('which anyone can read'), findsOneWidget, reason: 'GitHub is public, and says so');
    final send = find.widgetWithText(FilledButton, 'Send');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'The 2 of clubs would not lead.');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(find.textContaining('Record: oh1:4:a,b,c::'), findsOneWidget);

    // No page to open off the web: the report and where to take it, on
    // the clipboard, and said.
    await tester.tap(send);
    await tester.pump();
    expect(copied, hasLength(1));
    expect(copied.single, startsWith('The 2 of clubs would not lead.\n\n---\nBuild: dev (dev)\n'));
    expect(copied.single, contains('Record: oh1:4:a,b,c::'));
    expect(copied.single, endsWith('\n\n$projectIssues'));
    expect(find.text('Copied. Paste it at $projectIssues'), findsOneWidget);
  });

  testWidgets('mail is not public, and the page does not say it is', (tester) async {
    RemoteSettings.current.adopt(RemoteConfig.parse({'feedback': 'mailto:help@x.example'}));
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const FeedbackPage()));
    expect(find.textContaining('which anyone can read'), findsNothing);
    expect(find.byType(Checkbox), findsNothing, reason: 'no record to offer away from a solo table');
  });
}
