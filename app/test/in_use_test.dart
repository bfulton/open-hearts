/// One device at a time (docs/explanation/service.md; net/in_use.dart): the
/// device in use holds an activation the service signed, and the one
/// before steps back, says so over everything, and can take the account
/// back — asked first when the other is in a game.
///
/// The service is a stand-in (household_test.dart). Which device the
/// service says is in use, and that the relay holds every socket to it,
/// is proved where those live: `node --test service/functions service/do`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/net/duty.dart';
import 'package:open_hearts/net/in_use.dart';
import 'package:open_hearts/net/relays.dart' show ourRelay;
import 'package:open_hearts/ui/in_use_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'home_page_test.dart' show licenceThisDevice;
import 'household_test.dart' show Stand, standUp;

const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const _account = '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a';

/// An activation the stand-in service would have signed for [key].
Map<String, Object?> activationFor(PublicKey key, {int epoch = 1, String account = _account}) {
  final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final unsigned = Activation(account: account, key: key, epoch: epoch, until: until, signature: '');
  return Activation(
    account: account,
    key: key,
    epoch: epoch,
    until: until,
    signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest),
  ).toJson();
}

/// What the device asked the service, as the stand-in heard it.
List<String> asked(Stand stand) => [for (final s in stand.seen) if (s.startsWith('/api/activate')) s];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
    InUse.current = InUse();
  });
  tearDown(() {
    Entitlement.current = Entitlement();
    InUse.current = InUse();
  });

  test('taking the account up: the activation the service signed for this device, shown to a relay that asks', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    expect(await InUse.current.open(me), Use.here);
    expect(InUse.current.activation!.epoch, 1);
    expect(asked(stand).single, contains('"want":"open"'));
    // Shown for this device's own key, and for nobody else's.
    final shown = InUse.current.credentials(me.publicKey)!;
    expect(shown.single.first, 'activation');
    expect(Activation.parse(shown.single.last)!.key, me.publicKey);
    expect(InUse.current.credentials('cd' * 32), isNull);
  });

  test('the licence this device holds goes with its asking, which names the account', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    expect(await InUse.current.open(me), Use.here);
    expect(asked(stand).single, isNot(contains('"licence"')), reason: 'none held, none shown');
    await licenceThisDevice();
    await InUse.current.renew();
    final renewed = asked(stand).last;
    final body = jsonDecode(renewed.substring(renewed.indexOf(' ') + 1)) as Map;
    expect(body['licence'], Entitlement.current.licence!.toJson());
  });

  test('an activation the service did not sign, or for another device, is no activation', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'activation': activationFor('cd' * 32)});
    expect(await InUse.current.open(me), Use.unasked);
    final forged = activationFor(me.publicKey)..['epoch'] = 9;
    stand.says('activate', {'activation': forged});
    expect(await InUse.current.open(me), Use.unasked);
    expect(InUse.current.credentials(me.publicKey), isNull);
  });

  test('brought into another account, the device takes that one up', () async {
    final stand = standUp();
    final me = await Identity.signer();
    // In use under the account it had of its own...
    stand.says('activate', {'activation': activationFor(me.publicKey, account: '0b' * 16)});
    expect(await InUse.current.open(me), Use.here);
    // ...then licensed into another: it asks again, for that one.
    stand.says('activate', {'activation': activationFor(me.publicKey, epoch: 2)});
    await licenceThisDevice();
    InUse.current.licenceChanged();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(asked(stand), hasLength(2));
    expect(InUse.current.activation!.account, _account);
    // The same account again asks nothing.
    InUse.current.licenceChanged();
    expect(asked(stand), hasLength(2));
    InUse.current.reset();
  });

  test('superseded: by the service, by the relay, or by the other device\'s presence, and it steps back', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    await InUse.current.open(me);
    // Renewed on the clock: the other device has taken it since.
    stand.says('activate', {'error': 'superseded: another device of this account is in use', 'superseded': true}, status: 409);
    await InUse.current.renew();
    expect(InUse.current.standing, Use.elsewhere);
    expect(InUse.current.credentials(me.publicKey), isNull, reason: 'nothing to show a relay any more');

    // Taken back, and turned away by a relay.
    stand.says('activate', {'activation': activationFor(me.publicKey, epoch: 3)});
    expect(await InUse.current.open(me), Use.here);
    InUse.current.turnedAway('restricted: not a backup juror');
    expect(InUse.current.standing, Use.here, reason: 'only a superseding is a stepping back');
    InUse.current.turnedAway('superseded: another device of this account is in use');
    expect(InUse.current.standing, Use.elsewhere);
  });

  test('deleted from another of its devices, as a relay says: the licence off this one, and nothing to show a relay', () async {
    final stand = standUp();
    final me = await Identity.signer();
    Entitlement.current.addListener(InUse.current.licenceChanged);
    await licenceThisDevice();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    expect(await InUse.current.open(me), Use.here);

    InUse.current.turnedAway('deleted: this account was deleted');
    await pumpEventQueue();
    expect(InUse.current.standing, Use.unasked, reason: 'a device of no account, not one in use elsewhere');
    expect(InUse.current.credentials(me.publicKey), isNull);
    expect(Entitlement.current.live, isFalse);
    expect(Entitlement.current.inAnAccount, isFalse, reason: 'nothing left here to delete');
    expect(Entitlement.current.suspended, isFalse);
  });

  test('suspended, as a relay says: live play shut here, the duty with it, and the licence; let back, open again', () async {
    final stand = standUp();
    final me = await Identity.signer();
    // As the app wires them (main.dart).
    Entitlement.current.addListener(InUse.current.licenceChanged);
    await licenceThisDevice();
    expect(Entitlement.current.live, isTrue);
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    expect(await InUse.current.open(me), Use.here);
    final duty = Duty.on([Uri.parse(ourRelay)], me);
    addTearDown(duty.close);

    InUse.current.turnedAway('suspended: this account is suspended from live play');
    await pumpEventQueue();
    expect(InUse.current.standing, Use.suspended);
    expect(InUse.current.shut, isTrue);
    expect(InUse.current.elsewhere, isFalse, reason: 'not "in use on another device"');
    expect(Duty.current, isNull, reason: 'no juror, and online to nobody');
    expect(InUse.current.credentials(me.publicKey), isNull, reason: 'nothing to show a relay any more');
    expect(Entitlement.current.suspended, isTrue);
    expect(Entitlement.current.live, isFalse);

    // Neither the service refusing it nor another device's word makes
    // it anything else.
    stand.says('activate', {'error': 'no subscription'}, status: 402);
    expect(await InUse.current.open(me), Use.suspended);
    InUse.current.stepBack();
    expect(InUse.current.standing, Use.suspended);

    // Let back: the next licence opens live play as before.
    await licenceThisDevice();
    expect(Entitlement.current.suspended, isFalse);
    expect(InUse.current.standing, Use.unasked);
    expect(InUse.current.shut, isFalse);
    Entitlement.current.removeListener(InUse.current.licenceChanged);
  });

  test('the account at a table on another device: asked first, and taken only on the person\'s word', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'error': 'in a game on another device', 'seated': true}, status: 409);
    expect(await InUse.current.open(me), Use.playingElsewhere);
    expect(InUse.current.elsewhere, isTrue, reason: 'live play is not open here meanwhile');
    stand.says('activate', {'activation': activationFor(me.publicKey, epoch: 2), 'took': true});
    expect(await InUse.current.open(me, take: true), Use.here);
    expect(asked(stand).last, contains('"want":"take"'));
  });

  test('sitting down and getting up are said to the service', () async {
    final stand = standUp();
    final me = await Identity.signer();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    await InUse.current.open(me);
    const table = '0123456789abcdef0123456789abcdef';
    InUse.current.seatedAt(table);
    await Future<void>.delayed(Duration.zero);
    expect(asked(stand).last, contains('"want":"renew","seated":"$table"'));
    InUse.current.seatedAt(null);
    await Future<void>.delayed(Duration.zero);
    expect(asked(stand).last, contains('"seated":null'));
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const InUseScreen(child: Scaffold(body: Text('the app'))),
    ));
    await tester.pump();
  }

  testWidgets('the device that stepped back says so over everything, and takes the account back', (tester) async {
    final stand = standUp();
    await licenceThisDevice();
    final me = await Identity.signer();
    await pumpScreen(tester);
    expect(find.text('Open Hearts is now open on another device'), findsNothing);

    InUse.current.stepBack();
    await tester.pump();
    expect(find.text('Open Hearts is now open on another device'), findsOneWidget);
    expect(find.text('Use it here'), findsOneWidget);

    stand.says('activate', {'activation': activationFor(me.publicKey, epoch: 2)});
    await tester.tap(find.text('Use it here'));
    await tester.pumpAndSettle();
    expect(InUse.current.standing, Use.here);
    expect(find.text('Open Hearts is now open on another device'), findsNothing);
    expect(find.text('the app'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The renewal on the clock, stopped before the test's clock is.
    InUse.current.reset();
  });

  test('suspended, as the service says when the device asks to be the one in use: the same', () async {
    final stand = standUp();
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('activate', {'activation': activationFor(me.publicKey)});
    expect(await InUse.current.open(me), Use.here);
    stand.says('activate', {'error': 'suspended: this account is suspended from live play', 'suspended': true}, status: 403);
    await InUse.current.renew();
    await pumpEventQueue();
    expect(InUse.current.standing, Use.suspended);
    expect(InUse.current.activation, isNull);
    expect(Entitlement.current.suspended, isTrue);
    expect(Entitlement.current.live, isFalse);
    // A refusal that does not say so is not a suspension.
    InUse.current = InUse();
    stand.says('activate', {'error': 'no'}, status: 403);
    expect(await InUse.current.open(me), Use.unasked);
  });

  testWidgets('a suspended device is not told it is open on another device, nor offered to take it back', (tester) async {
    await licenceThisDevice();
    await pumpScreen(tester);
    InUse.current.turnedAway('suspended: this account is suspended from live play');
    await tester.pumpAndSettle();
    expect(find.text('Open Hearts is now open on another device'), findsNothing);
    expect(find.text('Use it here'), findsNothing);
    expect(find.text('the app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a game on the other device is asked about before it is lost, and Not now leaves it be', (tester) async {
    final stand = standUp();
    await licenceThisDevice();
    final me = await Identity.signer();
    stand.says('activate', {'error': 'in a game on another device', 'seated': true}, status: 409);
    await InUse.current.open(me);
    await pumpScreen(tester);
    expect(find.text("You're in a game on another device"), findsOneWidget);
    expect(find.text('Continue here? That game will be lost.'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text("You're in a game on another device"), findsNothing);
    expect(InUse.current.standing, Use.elsewhere, reason: 'the game goes on over there');
    expect(asked(stand).length, 1, reason: 'and nothing more was asked');

    // Asked again, and this time continued here.
    await InUse.current.open(me);
    await tester.pump();
    stand.says('activate', {'activation': activationFor(me.publicKey, epoch: 2), 'took': true});
    await tester.tap(find.text('Continue here'));
    await tester.pumpAndSettle();
    expect(asked(stand).last, contains('"want":"take"'));
    expect(InUse.current.standing, Use.here);
    expect(tester.takeException(), isNull);
    InUse.current.reset();
  });
}
