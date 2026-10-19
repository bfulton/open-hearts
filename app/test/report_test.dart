// A report of another player (lib/report.dart): what it sends, in the
// shape the service reads (reportOf, service/functions/alerts.mjs), and
// what the player is told of how it went.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/report.dart';
import 'package:open_hearts/theme.dart';
import 'package:table/table.dart' show sha256Hex;

void main() {
  test('a report sends who, what, and only what it has', () {
    expect(const Report(about: 'b0b0', what: ReportWhat.name).toJson(), {'about': 'b0b0', 'what': 'name'});
    expect(
      const Report(about: 'b0b0', what: ReportWhat.other, table: 'ef', name: 'Bao', picture: 'ab', note: 'rude').toJson(),
      {'about': 'b0b0', 'what': 'other', 'table': 'ef', 'name': 'Bao', 'picture': 'ab', 'note': 'rude'},
    );
  });

  test('a picture is named by the SHA-256 of its bytes, as the service names it', () {
    final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 7]);
    expect(pictureDigest(jpeg), sha256Hex(jpeg));
    expect(pictureDigest(jpeg), hasLength(64));
  });

  testWidgets('one report too many is said so', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showReport(context, about: 'b0b0', name: 'Bao', send: (_) async => ReportSent.tooMany),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(find.text("That's as many reports as you can send today."), findsOneWidget);
  });
}
