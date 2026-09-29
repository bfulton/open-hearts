/// This device's own pace: measured from its own turns, kept on it,
/// and said out loud on the profile because it decides who you sit with
/// (packages/table, pace.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/pace_store.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show Pace, Tally, TimeBank;

Future<void> pumpProfile(WidgetTester tester, PlayerStats stats) async {
  tester.view
    ..physicalSize = const Size(390, 900)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: ProfilePage(current: (name: 'Ada', avatar: Avatar.none), seed: 'k1', stats: Stream.value(stats)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing measured is nothing kept, and a game folds in', () async {
    expect((await PaceStore.load()).known, isFalse);
    // A game of cards at four seconds each: two hands' worth is enough
    // to state.
    final after = await PaceStore.fold(List.filled(26, 4000));
    expect(after.known, isTrue);
    expect(after.stated, 4);
    // And it is on the device, not in memory.
    expect((await PaceStore.load()).stated, 4);
  });

  test('a turn somebody walked away from is not a think', () async {
    // The table itself will not wait longer than a card's grace plus
    // the whole bank before anybody may be booted, so anything past
    // that was a phone in a pocket rather than a decision.
    final tooLong = TimeBank.standard.graceMs + TimeBank.standard.bankMs + 1;
    final pace = await PaceStore.fold([...List.filled(26, 3000), tooLong, tooLong]);
    expect(pace.stated, 3, reason: 'the two long ones are dropped, not averaged in');
  });

  test('a game of nothing measurable leaves the pace where it was', () async {
    await PaceStore.fold(List.filled(26, 9000));
    expect((await PaceStore.load()).stated, 9);
    // A game this device caught up on rather than played: no turn of
    // its own was seen to open, so there is nothing to measure.
    final after = await PaceStore.fold(const <int>[]);
    expect(after.stated, 9);
  });

  testWidgets('the profile says what it is going to state about you, and when it does not know', (tester) async {
    await pumpProfile(tester, const PlayerStats(reached: true));
    expect(find.textContaining('not known yet'), findsOneWidget);
    expect(find.textContaining('you will be seated with players at a similar pace'), findsOneWidget);

    await pumpProfile(
      tester,
      PlayerStats(
        reached: true,
        live: const Tally(games: 6, won: 2, points: 6 * 40, best: 18),
        pace: Pace.fresh.plus(cards: 40, seconds: 280),
      ),
    );
    expect(find.textContaining('steady pace'), findsOneWidget);
    expect(find.textContaining('7 seconds a card'), findsOneWidget);
    expect(find.textContaining('and are seated with players at a similar pace'), findsOneWidget);
  });
}
