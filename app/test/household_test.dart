/// A subscription is a person's: a code another device arrives with,
/// a few devices to an account, and any of them able to drop another
/// (docs/explanation/service.md).
///
/// The service is a stand-in here, as it is for the TURN credentials
/// (turn_test.dart): what these prove is this side — the link a code
/// travels in, what comes back, and what the screen does with a refusal.
/// The handler's own rules are proved where they live, in
/// `node --test service/functions`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/activate_page.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/buying.dart';
import 'package:open_hearts/net/household.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/subscribe_page.dart';
import 'package:open_hearts/ui/qr_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

import 'home_page_test.dart' show licenceThisDevice;
import 'routes.dart';

const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// A service of this test's own, standing where the site's would be.
/// Not on a socket: a widget test's binding answers 400 to every real
/// request, so what a test stands up has to stand where the app asks
/// rather than where it would listen.
class Stand {
  final seen = <String>[];
  final _answers = <String, ({int status, String body})>{};
  bool reachable = true;

  void says(String handler, Object? body, {int status = 200}) =>
      _answers['/api/$handler'] = (status: status, body: jsonEncode(body));

  Future<({int status, String body})> ask(Uri url, String body) async {
    if (!reachable) throw const SocketException('nobody there');
    seen.add('${url.path} $body');
    return _answers[url.path] ?? (status: 404, body: '{"error":"no such handler"}');
  }
}

Stand standUp() {
  final stand = Stand();
  final wasAt = handlerAt;
  final wasAsk = askService;
  handlerAt = (handler) => Uri.parse('https://service.test/api/$handler');
  askService = stand.ask;
  addTearDown(() {
    handlerAt = wasAt;
    askService = wasAsk;
  });
  return stand;
}

/// A licence the stand-in service would have signed.
Map<String, Object?> signedFor(PublicKey device, {int days = 30}) {
  final day = DateTime.now().toUtc().add(Duration(days: days));
  final until = DateTime.utc(day.year, day.month, day.day);
  final unsigned = Licence(key: device, account: '0a' * 16, until: until, plan: 'year', signature: '');
  return Licence(
    key: device,
    account: '0a' * 16,
    until: until,
    plan: 'year',
    signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest),
  ).toJson();
}

void main() {
  test('the privacy policy and the terms are the site\'s, beside the app, whatever the config says', () {
    expect(legalPage('privacy', base: Uri.parse('https://open-hearts.pages.dev/play/?e2e')).toString(), 'https://open-hearts.pages.dev/privacy');
    expect(legalPage('terms', base: Uri.parse('http://127.0.0.1:8123/')).toString(), 'http://127.0.0.1:8123/terms');
    expect(legalPage('terms', base: Uri()).toString(), 'https://openhearts.game/terms', reason: 'a phone build');
    // The app at its own host: the site is the host without play.
    expect(legalPage('privacy', base: Uri.parse('https://play.openhearts.game/subscription')).toString(), 'https://openhearts.game/privacy');
    expect(legalPage('terms', base: Uri.parse('http://play.openhearts.localhost:8123/')).toString(), 'http://openhearts.localhost:8123/terms');
    // Published there and nowhere else (site/ledger.mjs): no row points
    // them at another document.
    RemoteSettings.current.adopt(RemoteConfig.parse({'terms': 'https://legal.example/t'}));
    addTearDown(() => RemoteSettings.current = RemoteSettings());
    expect(legalPage('terms', base: Uri.parse('https://open-hearts.pages.dev/play/')).toString(), 'https://open-hearts.pages.dev/terms');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
  });
  tearDown(() => Entitlement.current = Entitlement());

  test('the link a code travels in is this app\'s own address, and nothing of this session', () {
    final from = Uri.parse('https://open-hearts.pages.dev/play/?room=KP4T9MXR&bought=1');
    expect(claimLink('0a1b2c', from), 'https://open-hearts.pages.dev/play/?claim=0a1b2c');
    // A driven build stays driven across the hop, as a room link does.
    final rig = Uri.parse('http://127.0.0.1:8123/?e2e=1&roomWait=45');
    expect(claimLink('0a1b2c', rig), 'http://127.0.0.1:8123/?e2e=1&roomWait=45&claim=0a1b2c');
  });

  test('a code in the address is read, and nonsense in it is not', () {
    expect(claimInAddress(Uri.parse('https://x/play/?claim=0a1b2c')), '0a1b2c');
    expect(claimInAddress(Uri.parse('https://x/play/')), isNull);
    expect(claimInAddress(Uri.parse('https://x/play/?claim=../../etc')), isNull);
    expect(claimInAddress(Uri.parse('https://x/play/?claim=')), isNull);
  });

  test('a code comes back, and a refusal comes back in its own words', () async {
    final stand = standUp();
    final me = FakeSigner('one');
    stand.says('ticket', {'ticket': 'ab12', 'expires_at': '2026-09-16T12:00:00Z', 'devices': 1, 'most': 5});
    final made = await askForCode(me);
    expect(made.answer!.code, 'ab12');
    expect(made.refusal, isNull);
    final [path, body] = stand.seen.single.split(' ');
    expect(path, '/api/ticket');
    // Signed by the key it names: anybody can read a key off a relay,
    // and a code is made against what that key paid for.
    final asked = jsonDecode(body) as Map<String, Object?>;
    expect(asked['key'], me.publicKey);
    expect(asked['sig'], me.sign(requestDigest('ticket', me.publicKey, asked['at'] as int)));

    stand.says('ticket', {'error': 'the account has all the devices it can take'}, status: 409);
    final refused = await askForCode(me);
    expect(refused.answer, isNull);
    expect(refused.refusal?.say(), 'This subscription has all the devices it can take.');
  });

  test('a claim brings back a licence, and only one this device can hold', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    stand.says('claim', {'licence': signedFor(me.publicKey)});
    final claimed = await claimCode(me, 'ab12', service: _service);
    expect(claimed.answer, isNotNull);
    expect(claimed.answer!.key, me.publicKey);
    expect(stand.seen.single, contains('"ticket":"ab12"'));

    // Somebody else's licence, correctly signed, is nothing here.
    stand.says('claim', {'licence': signedFor(SchnorrSigner.generate().publicKey)});
    final theirs = await claimCode(me, 'ab12', service: _service);
    expect(theirs.answer, isNull);
    expect(theirs.refusal?.say(), 'That code is not for this device.');
  });

  test('a claim that was refused says why: used, run out, or never a code', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    for (final (status, said, shown) in [
      (409, 'that code has been used', 'That code has been used.'),
      (410, 'that code has run out', 'That code has run out.'),
      (404, 'no such code', 'No such code.'),
    ]) {
      stand.says('claim', {'error': said}, status: status);
      final refused = await claimCode(me, 'ab12', service: _service);
      expect(refused.answer, isNull);
      expect(refused.refusal?.say(), shown);
    }
  });

  testWidgets('a web subscriber manages it in Stripe\'s portal, and one bought in a store is told where', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    final wasCan = canLeaveForStripe;
    final wasLeave = leaveFor;
    final sentTo = <String>[];
    canLeaveForStripe = true;
    leaveFor = sentTo.add;
    addTearDown(() {
      canLeaveForStripe = wasCan;
      leaveFor = wasLeave;
    });
    tester.view
      ..physicalSize = const Size(390, 1200)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();

    // A portal on Stripe's own host: gone to, with this device's signed ask.
    stand.says('manage', {'url': 'https://billing.stripe.com/p/session/test_1'});
    await tester.ensureVisible(find.text('Manage subscription'));
    await tester.tap(find.text('Manage subscription'));
    await tester.pumpAndSettle();
    expect(sentTo, ['https://billing.stripe.com/p/session/test_1']);
    final asked = jsonDecode(stand.seen.lastWhere((s) => s.startsWith('/api/manage ')).substring('/api/manage '.length)) as Map;
    expect(asked['key'], me.publicKey);
    expect(asked['sig'], isA<String>());
    expect(asked['back'], isA<String>());

    // An answer that would send it anywhere else sends it nowhere. (A
    // fresh page: the one that went is spinning, as a page left should.)
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();
    stand.says('manage', {'url': 'https://billing.stripe.com.evil.example/p'});
    await tester.ensureVisible(find.text('Manage subscription'));
    await tester.tap(find.text('Manage subscription'));
    await tester.pumpAndSettle();
    expect(sentTo, hasLength(1));
    expect(find.text('The shop is not open yet.'), findsOneWidget);

    // Bought in a store: managed there.
    stand.says('manage', {'error': 'not a web subscription'}, status: 409);
    await tester.tap(find.text('Manage subscription'));
    await tester.pumpAndSettle();
    expect(find.text('This subscription is managed where it was bought.'), findsOneWidget);
    expect(sentTo, hasLength(1));
  });

  testWidgets('no Manage button where this build cannot go to Stripe', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Manage subscription'), findsNothing);
  });

  test('a service that is not there is said to be, rather than nothing happening', () async {
    final stand = standUp();
    stand.reachable = false;
    final said = await askForCode(FakeSigner('one'));
    expect(said.refusal?.say(), 'Could not reach the service. Try again in a moment.');
  });

  testWidgets('the page lists the devices, shows a code to scan, and drops one', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    final other = SchnorrSigner.generate().publicKey;
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
        {'key': other, 'bound_at': '2026-09-10'},
      ],
      'most': 5,
    });
    tester.view
      ..physicalSize = const Size(390, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();

    expect(find.text('This device'), findsOneWidget);
    expect(find.text(other.substring(0, 6)), findsOneWidget);
    expect(find.text('2 of 5'), findsOneWidget);
    expect(find.text('Subscribe'), findsNothing, reason: 'nothing to buy twice');

    // A code, and a QR carrying the link it travels in.
    stand.says('ticket', {'ticket': 'ab12cd34', 'expires_at': '2026-09-16T12:00:00Z', 'devices': 2, 'most': 5});
    await tester.tap(find.text('Add a device'));
    await tester.pumpAndSettle();
    expect(find.byType(QrView), findsOneWidget);
    expect(tester.widget<QrView>(find.byType(QrView)).data, contains('claim=ab12cd34'));
    expect(find.textContaining('good for ten minutes'), findsOneWidget);

    // Dropping the other one asks for it by key, and the list redraws.
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    expect(stand.seen.last, contains('"drop":"$other"'));
    final dropping = jsonDecode(stand.seen.last.split(' ').last) as Map<String, Object?>;
    expect(schnorrVerifier(me.publicKey, requestDigest('devices', me.publicKey, dropping['at'] as int, other), dropping['sig'] as String),
        isTrue,
        reason: 'the device dropped is part of what is signed');
    expect(find.text('1 of 5'), findsOneWidget);
    expect(find.text(other.substring(0, 6)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a list the service cannot give is said to be missing, not left coming for ever', (tester) async {
    final stand = standUp();
    stand.reachable = false;
    await licenceThisDevice();
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();
    expect(find.text('…'), findsNothing, reason: 'nothing is still coming');
    expect(find.text('Could not reach the service. Try again in a moment.'), findsOneWidget);
    expect(find.text('Add a device'), findsOneWidget, reason: 'and the way to try again is still there');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a list that did not reach the service is asked for again by itself, waiting longer each time', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    var asked = 0;
    askService = (url, body) {
      if (url.path == '/api/devices') asked++;
      return stand.ask(url, body);
    };
    stand.reachable = false;
    await tester.pumpWidget(routed('/subscription'));
    await tester.pump();
    await tester.pump();
    expect(asked, 1);
    expect(find.text('Could not reach the service. Try again in a moment.'), findsOneWidget);

    // Two seconds, then four: the waits double.
    await tester.pump(const Duration(milliseconds: 1900));
    expect(asked, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(asked, 2);
    await tester.pump(const Duration(milliseconds: 3800));
    expect(asked, 2, reason: 'the second wait is twice the first');
    await tester.pump(const Duration(milliseconds: 300));
    expect(asked, 3);

    // Back in the foreground: asked at once, not at the end of the wait.
    stand.reachable = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(asked, 4);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Could not reach the service. Try again in a moment.'), findsNothing);

    // Listed: nothing more is asked.
    await tester.pump(const Duration(minutes: 5));
    expect(asked, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a list the service refused in its own words is not asked for again', (tester) async {
    final stand = standUp();
    await licenceThisDevice();
    stand.says('devices', {'error': 'not a device on this subscription'}, status: 403);
    var asked = 0;
    askService = (url, body) {
      if (url.path == '/api/devices') asked++;
      return stand.ask(url, body);
    };
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    await tester.pump(const Duration(minutes: 5));
    expect(asked, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a service that never answers is waited for ten seconds, and then said to be out of reach', (tester) async {
    standUp();
    askService = (url, body) => Completer<({int status, String body})>().future;
    await licenceThisDevice();
    await tester.pumpWidget(routed('/subscription'));
    await tester.pump();
    await tester.pump();
    expect(find.text('…'), findsOneWidget, reason: 'asked, and not answered yet');
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('…'), findsNothing);
    expect(find.text('Could not reach the service. Try again in a moment.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropping this very device shuts live play on it and leaves the page', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await tester.pumpWidget(routed('/', home: Builder(builder: (context) => TextButton(onPressed: () => showSubscribe(context), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(Entitlement.current.live, isTrue);

    stand.says('devices', {'devices': <Object>[], 'most': 5});
    await tester.tap(find.text('Drop this one'));
    await tester.pumpAndSettle();
    expect(Entitlement.current.live, isFalse, reason: 'a device that dropped itself is not licensed');
    expect(find.text('open'), findsOneWidget, reason: 'and the page it did it from is gone');
    expect(tester.takeException(), isNull);
  });
  test('a code is read the way a person types, pastes or scans it', () {
    // Off another device's screen: the link it travels in, or the code
    // itself, as shown in fours or run together, in either case.
    const ticket = '0a1b2c3d4e5f60718293a4b5c6d7e8f9';
    expect(codeIn('https://play.openhearts.game/?claim=$ticket'), ticket);
    expect(codeIn(ticket), ticket);
    expect(codeIn(' 0A1B 2C3D 4E5F 6071 8293 A4B5 C6D7 E8F9 '), ticket);
    // A backup code, from the email.
    expect(codeIn('abcd-efgh-jkmn-pqrs'), 'ABCD-EFGH-JKMN-PQRS');
    expect(codeIn('ABCDEFGHJKMNPQRS'), 'ABCD-EFGH-JKMN-PQRS');
    expect(codeIn('oil0 0000 0000 0000'), '0110-0000-0000-0000', reason: 'O, I and L are the digits they look like');
    for (final nonsense in ['', 'hello', 'ABCD-EFGH-JKMN-PQRU', 'https://elsewhere.example/', '0a1b2c', 'x' * 3000]) {
      expect(codeIn(nonsense), isNull, reason: nonsense);
    }
  });

  testWidgets('Activate: a backup code typed brings this device on, signed as typed by the service\'s reading', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await Entitlement.current.load(me.publicKey);
    stand.says('claim', {'error': 'no such code'}, status: 404);
    await tester.pumpWidget(routed('/', home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showActivate(context), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Scan a code'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nonsense');
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    expect(find.text('Not a code.'), findsOneWidget, reason: 'nonsense is not sent');
    expect(stand.seen, isEmpty);

    await tester.enterText(find.byType(TextField), 'zzzz zzzz zzzz zzzz');
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    expect(find.text('No such code.'), findsOneWidget);

    stand.says('claim', {'licence': signedFor(me.publicKey)});
    await tester.enterText(find.byType(TextField), 'abcd-efgh-jkmn-pqrs');
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    final asked = jsonDecode(stand.seen.last.split(' ').last) as Map<String, Object?>;
    expect(asked['ticket'], 'ABCD-EFGH-JKMN-PQRS');
    expect(schnorrVerifier(me.publicKey, requestDigest('claim', me.publicKey, asked['at'] as int, 'ABCD-EFGH-JKMN-PQRS'), asked['sig'] as String),
        isTrue,
        reason: 'the code is part of what is signed');
    expect(Entitlement.current.live, isTrue);
    expect(find.text('open'), findsOneWidget, reason: 'and the page is done');
    expect(find.text('Live play is open on this device.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page shows a screen\'s code to type, and the backup codes, replaces them, and emails them', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    tester.view
      ..physicalSize = const Size(390, 1400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(routed('/subscription'));
    await tester.pumpAndSettle();

    stand.says('ticket', {'ticket': '0a1b2c3d4e5f60718293a4b5c6d7e8f9', 'expires_at': '2026-09-16T12:00:00Z', 'devices': 1, 'most': 5});
    await tester.tap(find.text('Add a device'));
    await tester.pumpAndSettle();
    expect(find.text('0a1b 2c3d 4e5f 6071 8293 a4b5 c6d7 e8f9'), findsOneWidget, reason: 'the same code, to type');

    // Not on the screen until asked for.
    expect(find.text('Backup codes'), findsOneWidget);
    expect(find.text('AAAA-AAAA-AAAA-AAAA'), findsNothing);
    stand.says('backups', {
      'codes': [
        {'code': 'AAAA-AAAA-AAAA-AAAA', 'used': true},
        for (final c in ['BBBB', 'CCCC', 'DDDD', 'EEEE']) {'code': '$c-$c-$c-$c', 'used': false},
      ],
      'made_at': '2026-10-02T00:00:00Z',
    });
    await tester.ensureVisible(find.text('Show backup codes'));
    await tester.tap(find.text('Show backup codes'));
    await tester.pumpAndSettle();
    expect(find.text('AAAA-AAAA-AAAA-AAAA'), findsOneWidget);
    expect(find.text('used'), findsOneWidget);
    expect(find.text('EEEE-EEEE-EEEE-EEEE'), findsOneWidget);

    // Replaced, after asking; signed as a replacement.
    stand.says('backups', {
      'codes': [for (final c in ['FFFF', 'GGGG', 'HHHH', 'JJJJ', 'KKKK']) {'code': '$c-$c-$c-$c', 'used': false}],
      'made_at': '2026-10-02T01:00:00Z',
    });
    await tester.ensureVisible(find.text('Replace codes'));
    await tester.tap(find.text('Replace codes'));
    await tester.pumpAndSettle();
    expect(find.text('Replace the backup codes?'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    final asked = jsonDecode(stand.seen.last.split(' ').last) as Map<String, Object?>;
    expect(asked['rotate'], isTrue);
    expect(schnorrVerifier(me.publicKey, requestDigest('backups', me.publicKey, asked['at'] as int, 'rotate'), asked['sig'] as String), isTrue);
    expect(find.text('AAAA-AAAA-AAAA-AAAA'), findsNothing);
    expect(find.text('KKKK-KKKK-KKKK-KKKK'), findsOneWidget);
    expect(find.text('New codes made.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Emailed when asked, signed as such; and said when it could not be.
    final fresh = {
      'codes': [for (final c in ['FFFF', 'GGGG', 'HHHH', 'JJJJ', 'KKKK']) {'code': '$c-$c-$c-$c', 'used': false}],
      'made_at': '2026-10-02T01:00:00Z',
    };
    stand.says('backups', {...fresh, 'emailed': true});
    await tester.ensureVisible(find.text('Email'));
    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();
    final sent = jsonDecode(stand.seen.last.split(' ').last) as Map<String, Object?>;
    expect(sent['send'], isTrue);
    expect(sent.containsKey('rotate'), isFalse);
    expect(schnorrVerifier(me.publicKey, requestDigest('backups', me.publicKey, sent['at'] as int, 'send'), sent['sig'] as String), isTrue);
    expect(find.text('Sent to the email you subscribed with.'), findsOneWidget);
    expect(find.text('KKKK-KKKK-KKKK-KKKK'), findsOneWidget, reason: 'the same codes, still shown');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    stand.says('backups', {...fresh, 'emailed': false, 'unsent': 'no address'});
    await tester.tap(find.text('Email'));
    await tester.pumpAndSettle();
    expect(find.text('This subscription has no email to send them to.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
