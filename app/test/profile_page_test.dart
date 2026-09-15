/// The profile as a page: who you are at the top, and what the games
/// say under it.
///
/// The rating is the live games' alone, so a device that has played
/// none of them has none to show — and says so, rather than showing
/// the number everyone starts at as though it had been earned.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/theme.dart';
import 'package:table/table.dart';

const _phone = Size(390, 844);

Future<void> pumpProfile(WidgetTester tester, Stream<PlayerStats> stats, {String name = 'Ada'}) async {
  tester.view
    ..physicalSize = _phone
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: ProfilePage(current: (name: name, avatar: Avatar.none), seed: 'k1', stats: stats),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a rating, and both halves of the game', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(
        rating: Rating(mu: 1622, phi: 60),
        ratedGames: 9,
        live: Tally(games: 12, won: 4, points: 12 * 38, best: 19),
        alone: Tally(games: 30, won: 11, points: 30 * 41, best: 26),
        reached: true,
      )),
    );

    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('1622'), findsOneWidget);
    expect(find.textContaining('from 9 games'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Alone'), findsOneWidget);
    // played / won / average, for each half.
    expect(find.text('12'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('38'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('19'), findsOneWidget, reason: 'the best live game');
    expect(find.text('26'), findsOneWidget, reason: 'and the best alone');
  });

  testWidgets('no rated games, no rating — and it says which', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(
        rating: Rating.fresh,
        alone: Tally(games: 3, won: 1, points: 150),
        reached: true,
      )),
    );
    expect(find.text('1500'), findsNothing, reason: 'the number everyone starts at is not a rating anyone earned');
    expect(find.text('—'), findsWidgets);
    expect(find.textContaining('Play a rated live game'), findsOneWidget);
    // The games played alone still stand: three of them, one won, at 50.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
  });

  testWidgets('a provisional rating says so, and a silent relay says that instead', (tester) async {
    await pumpProfile(
      tester,
      Stream.value(const PlayerStats(rating: Rating(mu: 1480, phi: 300), ratedGames: 1, reached: true)),
    );
    expect(find.text('1480'), findsOneWidget);
    expect(find.textContaining('provisionally, from one game'), findsOneWidget);

    await pumpProfile(tester, Stream.value(const PlayerStats(alone: Tally(games: 2, won: 0, points: 80))));
    expect(find.textContaining('No relay answered'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'what the device itself knows is still known');
  });
}
