/// A subscription is a person's: a code another device arrives with,
/// five devices to a household, and any of them able to drop another
/// (docs/06-service.md).
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
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/buying.dart';
import 'package:open_hearts/net/household.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/subscribe_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/qr_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'home_page_test.dart' show licenceThisDevice;

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
  final unsigned = Licence(key: device, until: until, plan: 'year', signature: '');
  return Licence(
    key: device,
    until: until,
    plan: 'year',
    signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest),
  ).toJson();
}

void main() {
  test('the privacy policy and the terms are the site\'s, beside the app, unless the config says', () {
    expect(legalPage('privacy', base: Uri.parse('https://open-hearts.pages.dev/play/?e2e')).toString(), 'https://open-hearts.pages.dev/privacy');
    expect(legalPage('terms', base: Uri.parse('http://127.0.0.1:8123/')).toString(), 'http://127.0.0.1:8123/terms');
    expect(legalPage('terms', base: Uri()).toString(), 'https://openhearts.game/terms', reason: 'a phone build');
    RemoteSettings.current.adopt(RemoteConfig.parse({'terms': 'https://legal.example/t'}));
    addTearDown(() => RemoteSettings.current = RemoteSettings());
    expect(legalPage('terms', base: Uri.parse('https://open-hearts.pages.dev/play/')).toString(), 'https://legal.example/t');
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

    stand.says('ticket', {'error': 'five devices already'}, status: 409);
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
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
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
    await tester.pumpAndSettle();
    expect(find.text('…'), findsNothing, reason: 'nothing is still coming');
    expect(find.text('Could not reach the service. Try again in a moment.'), findsOneWidget);
    expect(find.text('Add a device'), findsOneWidget, reason: 'and the way to try again is still there');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a service that never answers is waited for ten seconds, and then said to be out of reach', (tester) async {
    standUp();
    askService = (url, body) => Completer<({int status, String body})>().future;
    await licenceThisDevice();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
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
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Builder(builder: (context) => TextButton(onPressed: () => showSubscribe(context), child: const Text('open'))),
    ));
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
}
