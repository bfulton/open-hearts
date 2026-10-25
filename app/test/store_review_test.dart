/// Asking for a review (net/store_review.dart): the store's own prompt,
/// asked for a moment after a game the player won, at most once in four
/// months, never on the web, and never for a hand's end or a game
/// somebody else won.
library;

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/store_review.dart';
import 'package:open_hearts/net/store_review_io.dart';
import 'package:open_hearts/table_model.dart' show SeatLook;
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/confetti.dart';
import 'package:open_hearts/ui/overlays.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A store that counts what it is asked.
class _Store implements StoreReview {
  int asked = 0;

  @override
  Future<void> request() async => asked++;
}

final _seats = [for (final n in ['Ada', 'Bao', 'You', 'Dee']) SeatLook(name: n)];

/// A game to 10 played out by each seat's first legal card, the first
/// seed to end it with one winner, and that winner's seat.
({engine.HeartsGame game, int won}) _finished() {
  for (var seed = 1;; seed++) {
    final game = engine.HeartsGame(seed: seed, target: 10);
    while (game.phase != engine.Phase.gameOver) {
      if (game.phase == engine.Phase.passing) {
        for (var seat = 0; seat < engine.seatCount; seat++) {
          if (!game.hasPassed(seat)) game.setPass(seat, game.handOf(seat).take(3).toList());
        }
      } else if (game.phase == engine.Phase.handOver) {
        game.nextHand();
      } else if (game.pendingTrick != null) {
        game.collectTrick();
      } else {
        final seat = game.currentSeat!;
        game.play(seat, game.legalPlaysFor(seat).first);
      }
    }
    if (game.winners.length == 1) return (game: game, won: game.winners.single);
  }
}

Future<void> _pump(WidgetTester tester, Widget sheet) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: sheet)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  final before = StoreReview.current;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = _Store();
    StoreReview.current = store;
  });
  tearDown(() => StoreReview.current = before);

  group('when to ask', () {
    test('after a win; not again for four months; then again', () async {
      final first = DateTime.utc(2026, 11, 1);
      await askForReviewAfterWin(now: first);
      expect(store.asked, 1);
      await askForReviewAfterWin(now: first.add(const Duration(days: 1)));
      await askForReviewAfterWin(now: first.add(reviewGap - const Duration(minutes: 1)));
      expect(store.asked, 1, reason: 'four months between asks, however often the player wins');
      await askForReviewAfterWin(now: first.add(reviewGap));
      expect(store.asked, 2);
      // And the four months run from the last ask, not the first.
      await askForReviewAfterWin(now: first.add(reviewGap * 2 - const Duration(days: 1)));
      expect(store.asked, 2);
    });

    test('with no store to ask, as on the web, nothing is asked and nothing kept', () async {
      StoreReview.current = null;
      await askForReviewAfterWin(now: DateTime.utc(2026, 11, 1));
      expect((await SharedPreferences.getInstance()).getInt(reviewAskedKey), isNull);
    });

    test('the time is kept before the store is asked: a store that fails is not asked again at the next win', () async {
      final failing = _FailingStore();
      StoreReview.current = failing;
      final first = DateTime.utc(2026, 11, 1);
      await expectLater(askForReviewAfterWin(now: first), throwsA(isA<StateError>()));
      await askForReviewAfterWin(now: first.add(const Duration(hours: 1)));
      expect(failing.asked, 1);
    });
  });

  group('the phone\'s store', () {
    const channel = MethodChannel('dev.britannio.in_app_review');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('is a phone\'s only: a computer has no store to ask', () {
      expect(storeReviewHere(), isNull, reason: 'these tests run on a computer');
    });

    test('is asked for its prompt, and nothing first', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      await PhoneReview().request();
      expect(calls, ['requestReview']);
    });

    test('that cannot put it up, a phone without Google Play, is let be', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'error', message: 'In-App Review API unavailable');
      });
      await PhoneReview().request();
    });
  });

  group('the sheet', () {
    testWidgets('a game you won asks once its confetti has fallen, and once', (tester) async {
      final over = _finished();
      await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: over.won, onNewGame: () {}));
      await tester.pump(confettiFalls);
      expect(store.asked, 0, reason: 'not over the confetti');
      await tester.pump(reviewAfter - confettiFalls);
      await tester.pump();
      expect(store.asked, 1);
      await tester.pump(const Duration(minutes: 1));
      expect(store.asked, 1);
    });

    testWidgets('a game somebody else won asks nothing', (tester) async {
      final over = _finished();
      await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: (over.won + 1) % engine.seatCount, onNewGame: () {}));
      await tester.pump(const Duration(minutes: 1));
      expect(store.asked, 0);
    });

    testWidgets('a player on to the next game before then is not stopped for it', (tester) async {
      final over = _finished();
      await _pump(tester, GameOverSheet(game: over.game, seats: _seats, mySeat: over.won, onNewGame: () {}));
      await tester.pump(reviewAfter - const Duration(seconds: 1));
      await _pump(tester, const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      expect(store.asked, 0);
    });

    testWidgets('a hand\'s end asks nothing, the hand a new player is taught on included', (tester) async {
      await _pump(
        tester,
        HandOverSheet(
          handNumber: 1,
          scores: const [0, 0, 11, 15],
          totals: const [0, 0, 11, 15],
          moonShooter: null,
          seats: _seats,
          onNext: () {},
          action: 'Done',
          note: 'Hearts are a point each.',
        ),
      );
      await tester.pump(const Duration(minutes: 1));
      expect(store.asked, 0);
    });
  });
}

/// A store whose prompt fails.
class _FailingStore implements StoreReview {
  int asked = 0;

  @override
  Future<void> request() async {
    asked++;
    throw StateError('the store failed');
  }
}
