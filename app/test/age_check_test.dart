/// What a phone's store says of the player's age, and what live play
/// makes of it (net/age_check.dart, age_gate.dart). The store is asked
/// through the age_range_signals plugin, whose channel stands in here
/// for Apple's and Google's answers as the plugin's own native halves
/// put them.
library;

import 'package:age_range_signals/age_range_signals.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/age_gate.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/net/age_check.dart';
import 'package:open_hearts/net/age_check_io.dart';
import 'package:open_hearts/theme.dart';

const _channel = MethodChannel('age_range_signals');

/// The store's side of the channel: [access] to the request to share,
/// and [check] to the check itself, or [fails] for every call. What was
/// asked, and with what, is kept in [asked].
class _Store {
  _Store({this.access = 'shared', this.check, this.fails}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _answer);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
  }

  final String access;
  final Map<String, Object?>? check;
  final String? fails;
  final asked = <MethodCall>[];

  Future<Object?> _answer(MethodCall call) async {
    asked.add(call);
    if (fails != null) throw PlatformException(code: fails!, message: 'no');
    return switch (call.method) {
      'initialize' => null,
      'requestAgeSignalsAccess' => access,
      'checkAgeSignals' => check,
      _ => throw MissingPluginException(),
    };
  }

  List<String> get methods => [for (final c in asked) c.method];
}

/// An answer to the check, shaped as the plugin's native halves shape it.
Map<String, Object?> _range(String status, {int? lower, int? upper}) => {
      'status': status,
      'ageLower': lower,
      'ageUpper': upper,
      'source': null,
      'installId': null,
      'activeParentalControls': null,
      'ageRangeSource': null,
      'significantChangeStatus': null,
      'significantChangeApprovalDate': null,
    };

/// A store that says [verdict], stood behind the app until the test
/// ends.
class StoreSays implements StoreAge {
  StoreSays(this.verdict) {
    StoreAge.current = this;
    addTearDown(() => StoreAge.current = null);
  }

  AgeVerdict verdict;
  var asked = 0;

  @override
  Future<AgeVerdict> ask() async {
    asked++;
    return verdict;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what live play makes of an answer', () {
    AgeVerdict of(String status, {int? lower, int? upper}) => verdictOf(AgeSignalsResult.fromMap(_range(status, lower: lower, upper: upper)));

    test('a range wholly under 13 is too young, on either store', () {
      // Apple's below the one gate, which the plugin starts at 0; Play's
      // youngest band.
      expect(of('supervised', lower: 0, upper: 12), AgeVerdict.tooYoung);
      expect(of('unknown', upper: 12), AgeVerdict.tooYoung, reason: 'by the range, whatever the plugin calls it');
    });

    test('a range from 13 up is open, and so is one that reaches 13 from below', () {
      expect(of('verified', lower: 13), AgeVerdict.open);
      expect(of('supervised', lower: 13, upper: 15), AgeVerdict.open, reason: "Play's younger teens");
      expect(of('verified', lower: 18), AgeVerdict.open);
      // A region's own lines, which replace the app's, need not fall on 13.
      expect(of('supervised', lower: 0, upper: 13), AgeVerdict.open);
    });

    test("a parent's approval waited on or declined in Google Play closes it, whatever the age", () {
      expect(of('supervisedApprovalPending', lower: 13, upper: 15), AgeVerdict.awaitingParent);
      expect(of('supervisedApprovalDenied', lower: 16, upper: 17), AgeVerdict.parentDeclined);
      expect(of('supervisedApprovalPending', lower: 0, upper: 12), AgeVerdict.awaitingParent, reason: 'the parent is the one to see to it');
    });

    test('nothing said is open: declined to share, or no range at all', () {
      expect(of('declined'), AgeVerdict.open);
      expect(of('unknown'), AgeVerdict.open);
    });
  });

  group('asking the store', () {
    test("asks only for the one line, once, and the store's range decides", () async {
      final store = _Store(check: _range('supervised', lower: 0, upper: 12));
      final age = PhoneAge();
      expect(await age.ask(), AgeVerdict.tooYoung);
      expect(store.methods, ['initialize', 'requestAgeSignalsAccess', 'checkAgeSignals']);
      expect((store.asked.first.arguments as Map)['ageGates'], [13], reason: 'no more of an age than the app goes by');
      expect((store.asked.first.arguments as Map)['useMockData'], isFalse);
      expect(await age.ask(), AgeVerdict.tooYoung);
      expect(store.methods, ['initialize', 'requestAgeSignalsAccess', 'checkAgeSignals', 'requestAgeSignalsAccess', 'checkAgeSignals'],
          reason: 'asked again each time, and set up once');
    });

    test('13 and over is open', () async {
      _Store(check: _range('verified', lower: 13));
      expect(await PhoneAge().ask(), AgeVerdict.open);
    });

    test('a player who does not share is not asked for a range, and the terms decide', () async {
      final store = _Store(access: 'notShared');
      expect(await PhoneAge().ask(), AgeVerdict.open);
      expect(store.methods, isNot(contains('checkAgeSignals')));
    });

    test("Google Play's asking for the age to be confirmed first closes it until it is", () async {
      final store = _Store(access: 'verificationRequired');
      expect(await PhoneAge().ask(), AgeVerdict.unconfirmed);
      expect(store.methods, isNot(contains('checkAgeSignals')));
    });

    test("a parent's approval in Google Play, waited on or declined", () async {
      _Store(check: _range('supervisedApprovalPending', lower: 13, upper: 15));
      expect(await PhoneAge().ask(), AgeVerdict.awaitingParent);
      _Store(check: _range('supervisedApprovalDenied', lower: 13, upper: 15));
      expect(await PhoneAge().ask(), AgeVerdict.parentDeclined);
    });

    test('a store that cannot say, or does not answer, leaves it to the terms', () async {
      for (final code in ['UNSUPPORTED_PLATFORM', 'API_NOT_AVAILABLE', 'PLAY_SERVICES_ERROR', 'NETWORK_ERROR', 'USER_CANCELLED']) {
        _Store(fails: code);
        expect(await PhoneAge().ask(), AgeVerdict.open, reason: code);
      }
    });

    test('set up again after a setting-up that failed', () async {
      _Store(fails: 'API_ERROR');
      final age = PhoneAge();
      expect(await age.ask(), AgeVerdict.open);
      final store = _Store(check: _range('supervised', lower: 0, upper: 12));
      expect(await age.ask(), AgeVerdict.tooYoung);
      expect(store.methods.first, 'initialize');
    });

    test('asked twice at once, the store is asked once', () async {
      final store = _Store(check: _range('verified', lower: 13));
      final age = PhoneAge();
      final both = await Future.wait([age.ask(), age.ask()]);
      expect(both, [AgeVerdict.open, AgeVerdict.open]);
      expect(store.methods.where((m) => m == 'checkAgeSignals'), hasLength(1));
    });

    test('with no store to ask, as on the web, live play is open', () async {
      expect(StoreAge.current, isNull, reason: 'none here, off a phone');
      expect(await askStoreAge(), AgeVerdict.open);
    });
  });

  group('told why', () {
    Future<void> pumpGate(WidgetTester tester, AgeVerdict verdict, void Function(bool) answered) async {
      StoreSays(verdict);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(onPressed: () async => answered(await storeLetsPlayLive(context)), child: const Text('Go live')),
        ),
      ));
      await tester.tap(find.text('Go live'));
      await tester.pumpAndSettle();
    }

    for (final (platform, says) in [(TargetPlatform.iOS, 'Your Apple Account says'), (TargetPlatform.android, 'Google Play says')]) {
      testWidgets('too young, on ${platform.name}: by whose word, and that playing alone is open', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        bool? lets;
        await pumpGate(tester, AgeVerdict.tooYoung, (v) => lets = v);
        expect(find.text('Live play is for 13 and older'), findsOneWidget);
        expect(find.text("$says you're under 13. Playing alone is open to everyone, as much as you like."), findsOneWidget);
        expect(lets, isNull, reason: 'not answered until the player has read it');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(lets, isFalse);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    for (final (verdict, title, line) in [
      (AgeVerdict.awaitingParent, 'Waiting for a parent', 'Live play opens once they do.'),
      (AgeVerdict.parentDeclined, 'Not approved', 'so live play is closed'),
      (AgeVerdict.unconfirmed, 'Confirm your age', 'in the Play Store app'),
    ]) {
      testWidgets('${verdict.name}: said, and closed', (tester) async {
        bool? lets;
        await pumpGate(tester, verdict, (v) => lets = v);
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining(line), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(lets, isFalse);
      });
    }

    testWidgets('open: nothing said, and on', (tester) async {
      bool? lets;
      await pumpGate(tester, AgeVerdict.open, (v) => lets = v);
      expect(find.byType(AlertDialog), findsNothing);
      expect(lets, isTrue);
    });
  });
}
