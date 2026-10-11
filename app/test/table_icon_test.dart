// Your seat at a table wears your own icon: with nothing chosen, the
// initials of the name on your profile, on your colour — the same icon
// the front door shows — though the seat is labelled You.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/player_icon.dart';

void main() {
  testWidgets("a solo table: You, wearing your profile's initials", (tester) async {
    SharedPreferences.setMockInitialValues({'flutter.identity_name': 'Dee Fulton'});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const Scaffold(body: Text('the door'))));
    unawaited(tester.state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => const TablePage(seed: 11, paced: false))));
    await tester.pumpAndSettle();
    final icons = tester.widgetList<PlayerIcon>(find.byType(PlayerIcon)).toList();
    final mine = icons.where((i) => i.name == 'Dee Fulton').toList();
    expect(mine, isNotEmpty, reason: 'your seat takes its initials from your profile');
    for (final icon in mine) {
      expect(PlayerIcon.initialsOf(icon.name), 'DF');
      expect(icon.seed, isNot('you'), reason: 'your colour is your own, as on the front door');
    }
    expect(icons.where((i) => i.name == 'You'), isEmpty, reason: 'no icon says Y');
    expect(find.text('You'), findsWidgets, reason: 'the seat is still labelled You');
  });

  testWidgets('with no name on the profile, the seat is as it was', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const Scaffold(body: Text('the door'))));
    unawaited(tester.state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => const TablePage(seed: 11, paced: false))));
    await tester.pumpAndSettle();
    expect(tester.widgetList<PlayerIcon>(find.byType(PlayerIcon)).where((i) => i.name == 'You'), isNotEmpty);
  });
}
