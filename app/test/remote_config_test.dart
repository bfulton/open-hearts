/// What the operator can say without a build (net/remote_config.dart):
/// read and checked, kept on the device, and the front door doing what
/// it says — and nothing at all when it says nothing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/buying.dart' show priceShown;
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/relays.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show TableTiming;

import 'home_page_test.dart' show licenceThisDevice;

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// A worker that says [said], and the URLs it was asked at.
List<Uri> _serve(Object? said) {
  final asked = <Uri>[];
  fetchConfig = (url) async {
    asked.add(url);
    return said is String ? said : jsonEncode(said);
  };
  return asked;
}

Future<void> _door(WidgetTester tester, {bool live = true}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await Entitlement.current.load((await Identity.signer()).publicKey);
  if (live) await licenceThisDevice();
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: const MediaQuery(data: MediaQueryData(disableAnimations: true), child: HomePage(online: false)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final originalFetch = fetchConfig;
  final originalHandler = handlerAt;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RemoteSettings.current = RemoteSettings();
    Entitlement.current = Entitlement(service: _service);
    handlerAt = (handler) => Uri.parse('https://open-hearts.pages.dev/api/$handler');
  });
  tearDown(() {
    fetchConfig = originalFetch;
    handlerAt = originalHandler;
    RemoteSettings.current = RemoteSettings();
    Entitlement.current = Entitlement();
  });

  test('no config is the build as it was made: every door open, nothing said', () {
    for (final c in [RemoteConfig.none, RemoteConfig.parse(null), RemoteConfig.parse('x'), RemoteConfig.parse(const {})]) {
      expect(c.live, isTrue);
      expect(c.offer, isTrue);
      expect(c.relays, isNull);
      expect(c.banner, isNull);
      expect(c.updateDue('2020-01-01'), isFalse);
    }
  });

  test('every field is checked again here, and one that does not check out is the build\'s', () {
    final c = RemoteConfig.parse({
      'live': false,
      'offer': false,
      'relays': ['wss://one.openhearts.game', 'wss://two.openhearts.game/'],
      'banner': {'id': 'm1', 'level': 'warn', 'text': {'en': 'Down till noon.', 'de': 'Bis Mittag aus.'}},
      'update': {'before': '2026-10-01', 'text': {'en': 'Too old.'}},
    });
    expect(c.live, isFalse);
    expect(c.offer, isFalse);
    expect(c.relays, [Uri.parse('wss://one.openhearts.game'), Uri.parse('wss://two.openhearts.game/')]);
    expect(c.banner!.warning, isTrue);
    expect(c.banner!.text.inLanguage('de'), 'Bis Mittag aus.');
    expect(c.banner!.text.inLanguage('fr'), 'Down till noon.', reason: 'English where the operator wrote none');
    expect(c.updateText!.inLanguage('es'), 'Too old.');

    expect(RemoteConfig.parse({'live': 'false'}).live, isTrue);
    expect(RemoteConfig.parse({'relays': ['ws://plain.openhearts.game']}).relays, isNull, reason: 'never in the open');
    expect(RemoteConfig.parse({'relays': ['wss://ok.openhearts.game', 42]}).relays, isNull, reason: 'not quietly shortened');
    expect(RemoteConfig.parse({'relays': ['wss://u:p@ok.openhearts.game']}).relays, isNull);
    expect(RemoteConfig.parse({'relays': [for (var i = 0; i < 9; i++) 'wss://r$i.openhearts.game']}).relays, isNull);
    expect(RemoteConfig.parse({'banner': {'id': 'x', 'text': {'de': 'nur Deutsch'}}}).banner, isNull);
    expect(RemoteConfig.parse({'banner': {'text': {'en': 'no id'}}}).banner, isNull);
    expect(RemoteConfig.parse({'update': {'before': 'soon'}}).updateBefore, isNull);
  });

  test('the clocks of the tables this device starts: the operator\'s where all of them check out, else the standard', () {
    expect(RemoteConfig.none.table, TableTiming.standard);
    expect(RemoteConfig.parse(const {}).table, TableTiming.standard);
    final quick = RemoteConfig.parse({'table': {'graceMs': 3000, 'bankMs': 30000}}).table;
    expect(quick.bank.graceMs, 3000);
    expect(quick.bank.bankMs, 30000);
    expect(quick.botActsMs, TableTiming.standard.botActsMs, reason: 'a field not named is the standard');
    expect(RemoteConfig.parse({'table': {'graceMs': 3000, 'bankMs': 1}}).table, TableTiming.standard, reason: 'all or nothing');
    expect(RemoteConfig.parse({'table': 'fast'}).table, TableTiming.standard);
    expect(RemoteConfig.parse({'live': false, 'table': {'graceMs': 1}}).live, isFalse, reason: 'and the rest of the row stands');
  });

  test('how long this device waits: each the operator\'s where it is in bounds, the build\'s where not', () {
    expect(RemoteConfig.parse({}).waits, AppWaits.standard);
    expect(AppWaits.standard.relaySlow, const Duration(seconds: 8));
    expect(AppWaits.standard.relayGiveUp, const Duration(seconds: 40));
    expect(AppWaits.standard.configEvery, const Duration(minutes: 15));
    final w = AppWaits.parse({'licenceMs': 9000, 'householdMs': 1, 'configEveryMin': 60, 'meshAnswerMs': '30000'});
    expect(w.licence, const Duration(seconds: 9));
    expect(w.household, AppWaits.standard.household, reason: 'under its least');
    expect(w.configEvery, const Duration(hours: 1));
    expect(w.meshAnswer, AppWaits.standard.meshAnswer, reason: 'not a number');
    for (final MapEntry(key: name, value: (least, most)) in AppWaits.bounds.entries) {
      expect(AppWaits.parse({name: least}), isNot(AppWaits.standard), reason: '$name at its least');
      expect(AppWaits.parse({name: most}), isNot(AppWaits.standard), reason: '$name at its most');
      expect(AppWaits.parse({name: least - 1}), AppWaits.standard, reason: '$name under');
      expect(AppWaits.parse({name: most + 1}), AppWaits.standard, reason: '$name over');
    }
    // Saying a relay is slow comes before giving up on it, or neither is
    // the operator's.
    final upside = AppWaits.parse({'relaySlowMs': 20000, 'relayGiveUpMs': 15000});
    expect((upside.relaySlow, upside.relayGiveUp), (AppWaits.standard.relaySlow, AppWaits.standard.relayGiveUp));
  });

  testWidgets('a relay is called slow, and given up on, when the operator\'s waits say', (tester) async {
    RemoteSettings.current.adopt(RemoteConfig.parse({'waits': {'relaySlowMs': 3000, 'relayGiveUpMs': 15000}}));
    var slow = false;
    Object? ended;
    unawaited(waitForRelay(Completer<void>().future, slow: () => slow = true).catchError((Object e) => ended = e));
    await tester.pump(const Duration(milliseconds: 2990));
    expect(slow, isFalse);
    await tester.pump(const Duration(milliseconds: 20));
    expect(slow, isTrue);
    await tester.pump(const Duration(seconds: 11));
    expect(ended, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(ended, isA<TimeoutException>());
  });

  test('the price shown beside Subscribe: the operator\'s, with a new Stripe price, or the build\'s', () {
    expect(priceShown, r'$5.99');
    RemoteSettings.current.adopt(RemoteConfig.parse({'price': '€6,49'}));
    expect(priceShown, '€6,49');
    for (final bad in ['', 'free', '<b>1</b>', r'$ 5.99', 42]) {
      expect(RemoteConfig.parse({'price': bad}).price, isNull, reason: '$bad');
    }
  });

  test('please update: a build older than the day asked for, and never a local one', () {
    final c = RemoteConfig.parse({'update': {'before': '2026-10-01'}});
    expect(c.updateDue('2026-09-30'), isTrue);
    expect(c.updateDue('2026-10-01'), isFalse, reason: 'the day itself is new enough');
    expect(c.updateDue('2026-11-02'), isFalse);
    expect(c.updateDue('dev'), isFalse);
  });

  test('the service\'s config is kept, and is what the next start begins with', () async {
    final asked = _serve({'live': false, 'banner': {'id': 'b', 'text': {'en': 'Hello.'}}});
    var told = 0;
    RemoteSettings.current.addListener(() => told++);
    await RemoteSettings.current.refresh();
    expect(asked.single.toString(), 'https://open-hearts.pages.dev/api/config');
    expect(RemoteSettings.current.config.live, isFalse);
    expect(told, 1);

    final next = RemoteSettings();
    await next.load();
    expect(next.config.live, isFalse, reason: 'read off the device, nothing fetched');
    expect(next.config.banner!.id, 'b');
  });

  test('a service that cannot be had changes nothing: the device goes on with what it has', () async {
    _serve({'live': false});
    await RemoteSettings.current.refresh();
    for (final failing in <Future<String?> Function(Uri)>[
      (_) async => null,
      (_) async => 'not json',
      (_) async => '[1, 2]',
      (_) async => throw StateError('offline'),
      (_) => Completer<String?>().future,
    ]) {
      fetchConfig = failing;
      await RemoteSettings.current.refresh(timeout: const Duration(milliseconds: 20));
      expect(RemoteSettings.current.config.live, isFalse);
    }
    final kept = RemoteSettings();
    await kept.load();
    expect(kept.config.live, isFalse, reason: 'and what it kept is still the last good one');

    handlerAt = (_) => null;
    final asked = _serve({'live': true});
    await RemoteSettings.current.refresh();
    expect(asked, isEmpty, reason: 'a build with no service behind it asks nobody');
  });

  test('the relays the operator names, on a deployed build, ours only; a local one keeps its own', () {
    final named = RemoteConfig.parse({'relays': ['wss://moved.openhearts.game/{tag}']});
    expect(appRelays(base: Uri.parse('https://play.openhearts.game/'), config: named, web: true),
        [Uri.parse('wss://moved.openhearts.game/{tag}')]);
    expect(appRelays(base: Uri.parse('https://play.openhearts.game/'), config: RemoteConfig.none, web: true),
        [for (final r in deployedRelays) Uri.parse(r)]);
    expect(appRelays(base: Uri.parse('http://localhost:8080/'), config: named, web: true), [Uri.parse(localRelay)]);
    // Never anyone else's: a public relay named is no relay named.
    for (final theirs in ['wss://relay.damus.io', 'wss://openhearts.game.evil.example', 'wss://evilopenhearts.game']) {
      expect(RemoteConfig.parse({'relays': [theirs]}).relays, isNull, reason: theirs);
    }
  });

  testWidgets('paused: no way into a live game, solo as it was, and why', (tester) async {
    RemoteSettings.current.adopt(RemoteConfig.parse({
      'live': false,
      'banner': {'id': 'out', 'level': 'warn', 'text': {'en': 'The relays are down. Back by six.'}},
    }));
    await _door(tester);
    expect(find.text('Play solo'), findsOneWidget);
    expect(find.text('Play live'), findsNothing);
    expect(find.text('Play friends'), findsNothing);
    expect(find.text('Live play is paused for now. Playing alone is not.'), findsOneWidget);
    expect(find.text('The relays are down. Back by six.'), findsOneWidget);

    // And lifted while the door is open: the buttons come back.
    RemoteSettings.current.adopt(RemoteConfig.none);
    await tester.pumpAndSettle();
    expect(find.text('Play live'), findsOneWidget);
    expect(find.text('The relays are down. Back by six.'), findsNothing);
  });

  testWidgets('not offered: a device without live play is not shown its price; one with it keeps it', (tester) async {
    RemoteSettings.current.adopt(RemoteConfig.parse({'offer': false}));
    await _door(tester, live: false);
    expect(find.text('Play solo'), findsOneWidget);
    expect(find.text('Subscribe'), findsNothing);
    expect(find.textContaining(r'$5.99'), findsNothing);

    await licenceThisDevice();
    await tester.pumpAndSettle();
    expect(find.text('Play live'), findsOneWidget, reason: 'what was bought stays bought');
  });

  testWidgets('please update: said to a build older than the day asked for, and only to one', (tester) async {
    RemoteSettings.current.adopt(RemoteConfig.parse({'update': {'before': '2026-10-01'}}));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: OperatorNotes(published: '2026-09-01'))));
    expect(find.text('This version is out of date. Update the app to get the new one.'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: OperatorNotes(published: '2026-10-02'))));
    expect(find.textContaining('out of date'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: OperatorNotes())));
    expect(find.textContaining('out of date'), findsNothing, reason: 'a local build has no day to be behind');
  });
}
