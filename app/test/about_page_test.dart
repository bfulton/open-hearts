/// The About page's choice of language, on the web: the app redrawn in
/// it at once, and kept for next time under the name the site keeps it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_hearts/about_page.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/theme.dart';

/// The page in an app drawn in [appLanguage], as main.dart draws it.
Widget _app({bool languages = true}) => ValueListenableBuilder<Locale?>(
      valueListenable: appLanguage,
      builder: (_, language, _) => MaterialApp(
        theme: buildTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: language,
        home: AboutPage(languages: languages),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLanguage.value = null;
  });

  testWidgets('a language chosen is taken up at once, kept, and given back to the device', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Same as this device'), findsOneWidget);

    await tester.tap(find.text('Same as this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();
    expect(find.text('Über'), findsWidgets, reason: 'the page is German now');
    expect(find.text('Sprache'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString(chosenLanguageKey), 'de',
        reason: 'kept where the site keeps its own choice');

    await tester.tap(find.text('Deutsch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wie auf diesem Gerät').last);
    await tester.pumpAndSettle();
    expect(appLanguage.value, isNull);
    expect((await SharedPreferences.getInstance()).getString(chosenLanguageKey), isNull);
    expect(find.text('About'), findsWidgets, reason: 'back to the device\'s own, English here');
  });

  testWidgets('off the web there is no choice here: the phone has its own setting', (tester) async {
    await tester.pumpWidget(_app(languages: false));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsNothing);
  });
}
