/// Signing in with Apple or Google, so a subscription follows the
/// person (docs/explanation/service.md): the nonce a token carries, what is sent
/// to `attest` and `supersede`, and what the Subscription page does with
/// each answer.
///
/// The providers and the service are stand-ins here. What the service
/// does with a token — its signature, its audience, the nonce, moving a
/// subscription — is proved where it lives, in
/// `node --test service/functions`, local mode's `local:` sign-ins
/// included; the nonce is pinned on both sides so they cannot drift.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/provider_tokens.dart';
import 'package:open_hearts/net/sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'home_page_test.dart' show licenceThisDevice;
import 'household_test.dart' show Stand, signedFor, standUp;
import 'routes.dart';

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// A provider of this test's own, which answers every ask with [answer].
class FakeTokens implements ProviderTokens {
  FakeTokens(this.offered);

  @override
  final List<Provider> offered;

  Asked answer = (token: 'local:ada', failed: false);
  final asked = <String>[];

  @override
  Future<Asked> ask(Provider provider, String nonce) async {
    asked.add('${provider.name} $nonce');
    return answer;
  }

  @override
  Widget? ownButton(Provider provider, String nonce, void Function(Asked asked) onAsked) => null;

  @override
  void prepare(List<Provider> providers) {}
}

FakeTokens offering(List<Provider> offered) {
  final fake = FakeTokens(offered);
  final was = providerTokens;
  providerTokens = fake;
  addTearDown(() => providerTokens = was);
  return fake;
}

/// What was sent to [handler], as the service read it.
Map<String, Object?> sentTo(Stand stand, String handler) =>
    jsonDecode(stand.seen.lastWhere((s) => s.startsWith('/api/$handler ')).substring('/api/$handler '.length)) as Map<String, Object?>;

Future<void> openPage(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(390, 1400)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(routed('/subscription'));
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
  });
  tearDown(() => Entitlement.current = Entitlement());

  test('the nonce is the hash of this device\'s key, as the service checks it', () {
    // The same figure is pinned in worker.test.mjs.
    expect(signInNonce('ab' * 32), '584421408c2fc1b0fffb975b25e2ba2dd1b547b6760dfa23e0985ff7bf1789f2');
    expect(signInNonce('cd' * 32), isNot(signInNonce('ab' * 32)));
  });

  test('a provider is offered only where its identifier was named, and only where it signs in', () {
    for (final platform in TargetPlatform.values) {
      for (final web in [true, false]) {
        expect(providersFor(web: web, platform: platform, google: '', apple: ''), isEmpty, reason: 'a build that names nobody');
      }
    }
    const google = 'x.apps.googleusercontent.com';
    const apple = 'game.openhearts.web';
    expect(providersFor(web: true, platform: TargetPlatform.android, google: google, apple: apple), [Provider.apple, Provider.google]);
    expect(providersFor(web: false, platform: TargetPlatform.iOS, google: google, apple: apple), [Provider.apple]);
    expect(providersFor(web: false, platform: TargetPlatform.android, google: google, apple: apple), [Provider.google]);
    expect(providersFor(web: false, platform: TargetPlatform.macOS, google: google, apple: apple), isEmpty);
    expect(providersFor(web: true, platform: TargetPlatform.iOS, google: google, apple: ''), [Provider.google]);
    // And this build, which names neither.
    expect(providerTokens.offered, isEmpty);
  });

  test('attest is asked signed by the key, with the provider and its token, and brings back this device\'s licence', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    stand.says('attest', {'attested': '2026-10-06', 'licence': signedFor(me.publicKey)});
    final said = await attestWith(me, Provider.apple, 'local:ada', service: _service);
    expect(said.refusal, isNull);
    expect(said.answer!.provider, Provider.apple);
    expect(said.answer!.licence!.key, me.publicKey);
    final asked = sentTo(stand, 'attest');
    expect([asked['key'], asked['provider'], asked['token']], [me.publicKey, 'apple', 'local:ada']);
    expect(schnorrVerifier(me.publicKey, requestDigest('attest', me.publicKey, asked['at'] as int), asked['sig'] as String), isTrue,
        reason: 'the service binds only a key that asked to be bound');

    // Somebody else's licence, correctly signed, is not this device's.
    stand.says('attest', {'attested': '2026-10-06', 'licence': signedFor(SchnorrSigner.generate().publicKey)});
    expect((await attestWith(me, Provider.apple, 'local:ada', service: _service)).answer!.licence, isNull);
  });

  test('supersede: this device comes into the account the sign-in is linked to', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    final account = '0a' * 16;
    stand.says('supersede', {'account': account, 'at': '2026-10-06', 'licence': signedFor(me.publicKey)});
    final said = await supersedeWith(me, Provider.google, 'local:ada', service: _service);
    expect(said.answer!.account, account);
    expect(said.answer!.licence!.holdsFor(me.publicKey, service: _service), isTrue);
    final asked = sentTo(stand, 'supersede');
    expect(schnorrVerifier(me.publicKey, requestDigest('supersede', me.publicKey, asked['at'] as int), asked['sig'] as String), isTrue,
        reason: 'signed for supersede, so an attest cannot be spent as one');
  });

  test('a refused sign-in says why, in words', () async {
    final stand = standUp();
    final me = FakeSigner('one');
    for (final (handler, status, said, shown) in [
      ('attest', 401, 'that sign-in does not check out', 'That sign-in did not check out. Try again.'),
      ('attest', 409, 'that sign-in is linked to another account', 'That sign-in is linked to another account.'),
      ('attest', 409, 'this account is linked to another sign-in', 'This account is already linked to another sign-in.'),
      ('supersede', 404, 'that sign-in is not linked to an account', 'No account is linked to that sign-in yet.'),
      ('attest', 503, 'service not configured: OH_ID_HMAC', 'Signing in is not open yet.'),
      ('attest', 401, "this device's clock is out by more than five minutes", "This device's clock is out. Set it right and try again."),
    ]) {
      stand.says(handler, {'error': said}, status: status);
      final refused = handler == 'attest' ? await attestWith(me, Provider.google, 't') : await supersedeWith(me, Provider.google, 't');
      expect(refused.answer, isNull);
      expect(refused.refusal?.say(), shown);
    }
    stand.reachable = false;
    expect((await attestWith(me, Provider.google, 't')).refusal?.say(), 'Could not reach the service. Try again in a moment.');
  });

  testWidgets('a build that names no provider shows no sign-in, subscribed or not', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    await Entitlement.current.load(me.publicKey);
    await openPage(tester);
    expect(find.textContaining('Sign in'), findsNothing);
    expect(find.text('Your account'), findsNothing);

    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await tester.pumpWidget(const SizedBox());
    await openPage(tester);
    expect(find.text('This device'), findsOneWidget);
    expect(find.textContaining('Sign in'), findsNothing);
    expect(find.text('Your account'), findsNothing);
  });

  testWidgets("the page shows the account's sign-in as the service has it, not as this device last noted it", (tester) async {
    final stand = standUp();
    offering([Provider.apple, Provider.google]);
    final me = await Identity.signer();
    await Entitlement.current.load(me.publicKey);
    await licenceThisDevice();
    // Noted here once, and since taken away (Apple, the person no longer
    // using Sign in with Apple for the app).
    await rememberSignIn(Provider.apple);
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
      'signIn': null,
    });
    await openPage(tester);
    expect(find.textContaining('Signed in with Apple.'), findsNothing);
    expect(find.text('Sign in with Apple'), findsOneWidget, reason: 'it can be linked again');
    expect(await signedInWith(), isNull, reason: 'the note is the account\'s now');

    // Linked on another of the account's devices: this one shows it.
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
      'signIn': 'google',
    });
    await tester.pumpWidget(const SizedBox());
    await openPage(tester);
    expect(find.textContaining('Signed in with Google.'), findsOneWidget);
    expect(await signedInWith(), Provider.google);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not subscribed: signing in brings this device into the account the sign-in is linked to', (tester) async {
    final stand = standUp();
    final tokens = offering([Provider.apple, Provider.google]);
    final me = await Identity.signer();
    await Entitlement.current.load(me.publicKey);
    await openPage(tester);
    expect(find.text('Sign in with Apple'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);

    stand.says('supersede', {'account': '0a' * 16, 'at': '2026-10-06', 'licence': signedFor(me.publicKey)});
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-10-06'},
      ],
      'most': 5,
    });
    await press(tester, 'Sign in with Apple');
    expect(tokens.asked, ['apple ${signInNonce(me.publicKey)}'], reason: 'the token is asked for this device\'s key');
    expect(sentTo(stand, 'supersede')['token'], 'local:ada');
    expect(Entitlement.current.live, isTrue);
    expect(find.text('Live play is open on this device.'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget, reason: 'the page is a subscriber\'s now');
    expect(find.textContaining('Signed in with Apple.'), findsOneWidget);
    expect(await signedInWith(), Provider.apple);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not subscribed, and a sign-in linked to no account: nothing to come into, and said so', (tester) async {
    final stand = standUp();
    offering([Provider.google]);
    final me = await Identity.signer();
    await Entitlement.current.load(me.publicKey);
    await openPage(tester);
    expect(find.text('Sign in with Apple'), findsNothing);

    stand.says('supersede', {'error': 'that sign-in is not linked to an account'}, status: 404);
    await press(tester, 'Sign in with Google');
    expect(stand.seen.map((s) => s.split(' ').first), ['/api/supersede'], reason: 'there is no account here to link it to');
    expect(find.text('Signed in. No account is linked to that sign-in yet: subscribe, then sign in from the subscription page.'),
        findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget, reason: 'nothing was linked, so it can be done again');
    expect(await signedInWith(), isNull);
    expect(Entitlement.current.live, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscribed: signing in links the sign-in to the account, and a sign-in linked elsewhere is used here only when asked', (tester) async {
    final stand = standUp();
    offering([Provider.google]);
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await openPage(tester);
    expect(find.text('Your account'), findsOneWidget);

    stand.says('attest', {'error': 'that sign-in is linked to another account'}, status: 409);
    await press(tester, 'Sign in with Google');
    expect(find.textContaining('That sign-in is linked to another Open Hearts account.'), findsOneWidget);
    expect(stand.seen.where((s) => s.startsWith('/api/supersede')), isEmpty, reason: 'nothing moved yet');

    stand.says('supersede', {'account': '0a' * 16, 'at': '2026-10-06', 'licence': signedFor(me.publicKey)});
    await press(tester, 'Use that account here');
    expect(sentTo(stand, 'supersede')['provider'], 'google');
    expect(find.textContaining('Signed in with Google.'), findsOneWidget);
    expect(find.text('Use that account here'), findsNothing);
    expect(Entitlement.current.live, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refusal is said on the page, a provider that failed is said to have, and backing out says nothing', (tester) async {
    final stand = standUp();
    final tokens = offering([Provider.apple]);
    final me = await Identity.signer();
    await licenceThisDevice();
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-09-01'},
      ],
      'most': 5,
    });
    await openPage(tester);

    stand.says('attest', {'error': 'that sign-in does not check out'}, status: 401);
    await press(tester, 'Sign in with Apple');
    expect(find.text('That sign-in did not check out. Try again.'), findsOneWidget);

    tokens.answer = failedToAsk;
    await press(tester, 'Sign in with Apple');
    expect(find.text('Signing in did not finish. Try again in a moment.'), findsOneWidget);

    tokens.answer = backedOut;
    final asked = stand.seen.length;
    await press(tester, 'Sign in with Apple');
    expect(stand.seen.length, asked, reason: 'nobody signed in, so nothing is sent');
    expect(find.text('Sign in with Apple'), findsOneWidget);
    expect(await signedInWith(), isNull);
    expect(tester.takeException(), isNull);
  });

  test("Apple's return address is the app's base, whatever page is open", () {
    // Registered on the Services ID: these exactly. The app is at the
    // root of play.openhearts.game; the old address, openhearts.game/play/,
    // stays registered for a build still open there.
    expect(appleReturnUrl(Uri.parse('https://play.openhearts.game/')).toString(), 'https://play.openhearts.game/');
    expect(appleReturnUrl(Uri.parse('https://play.openhearts.game/?lang=de#x')).toString(), 'https://play.openhearts.game/');
    expect(appleReturnUrl(Uri.parse('https://openhearts.game/play/')).toString(), 'https://openhearts.game/play/');
    // A preview's, which has the app at /play/.
    expect(appleReturnUrl(Uri.parse('https://dev.open-hearts.pages.dev/play/')).toString(), 'https://dev.open-hearts.pages.dev/play/');
    expect(appleReturnUrl(Uri.parse('http://localhost:8080/play/')).toString(), 'http://localhost:8080/play/');
  });
}
