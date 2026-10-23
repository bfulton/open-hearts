/// Live play bought in a phone's store (net/store_buying.dart).
///
/// Neither the store nor the service is real here: the store is this
/// file's own [FakeStore], standing where the plugin would, and the
/// service is household_test's stand-in. What these prove is the app's
/// half — what a purchase is recorded against, what the service is
/// shown and how it is signed, what each answer comes to on the
/// screen, and that a purchase is finished with the store only once
/// the service has taken it or has said the proof is no good.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/age_check.dart';
import 'package:open_hearts/net/buying.dart';
import 'package:open_hearts/net/household.dart' show askService;
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/store_buying.dart';
import 'package:open_hearts/subscribe_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'age_check_test.dart' show StoreSays;
import 'household_test.dart' show Stand, signedFor, standUp;

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// A store of a test's own: says what it is told to, and keeps what it
/// was asked to do.
class FakeStore implements PhoneStore {
  FakeStore({this.kind = StoreKind.apple, this.open = true, this.price = '£4.99'});

  @override
  final StoreKind kind;

  /// Whether it takes payments here: not while offline, say.
  bool open;

  /// The product's price, or null for a store with no such product.
  String? price;

  /// How many times it was asked what it sells.
  int asked = 0;

  final _purchases = StreamController<List<StorePurchase>>.broadcast();

  /// The account each sheet was opened for.
  final bought = <String>[];
  final finished = <StorePurchase>[];

  /// Whether a sheet opens when asked.
  bool sheetOpens = true;

  /// What a restore finds.
  List<StorePurchase> restoring = [];

  /// The store telling the app about purchases.
  void says(List<StorePurchase> purchases) => _purchases.add(purchases);

  @override
  Future<bool> available() async => open;

  @override
  Future<StoreProduct?> product(String id) async {
    asked++;
    return price == null || id != kind.product ? null : StoreProduct(id: id, price: price!);
  }

  @override
  Stream<List<StorePurchase>> get purchases => _purchases.stream;

  @override
  Future<bool> buy(StoreProduct product, {required String account}) async {
    bought.add(account);
    return sheetOpens;
  }

  @override
  Future<void> restore() async => _purchases.add(restoring);

  @override
  Future<void> finish(StorePurchase purchase) async => finished.add(purchase);
}

/// A purchase the store reports, for the build's product.
StorePurchase paid(String proof, {StoreStatus status = StoreStatus.purchased, bool? needsFinishing}) => StorePurchase(
      product: StoreKind.apple.product,
      status: status,
      proof: proof,
      needsFinishing: needsFinishing ?? status == StoreStatus.purchased,
    );

/// [store] as the app's shop, open for this device.
Future<StoreShop> shopWith(FakeStore store) async {
  final shop = StoreShop(store);
  StoreShop.current = shop;
  addTearDown(() => StoreShop.current = StoreShop(null));
  await shop.open(await Identity.signer());
  return shop;
}

/// The Live play page, on a phone tall enough to show all of it.
Future<void> _pumpPage(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(390, 1400)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
  await tester.pumpAndSettle();
}

/// The request the stand-in service last had at [handler], as sent.
Map<String, Object?> lastAt(Stand stand, String handler) => jsonDecode(
    stand.seen.lastWhere((s) => s.startsWith('/api/$handler ')).substring('/api/$handler '.length)) as Map<String, Object?>;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
    await Entitlement.current.load((await Identity.signer()).publicKey);
  });
  tearDown(() => Entitlement.current = Entitlement());

  test('what a purchase is recorded against is made from the key, the same way the service makes it', () {
    // Pinned on both sides: service/ makes the same two from this key.
    final account = storeAccountFor('dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659');
    expect(account.play, 'a0d2e1ee61d4911692a59bbda8ac7b994078d916759c7eaaf166d43072748199');
    expect(account.apple, 'a0d2e1ee-61d4-4116-92a5-9bbda8ac7b99');
    // A UUID StoreKit takes: version 4, the RFC's variant.
    expect(account.apple, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(storeAccountFor(SchnorrSigner.generate().publicKey).play, isNot(account.play));
  });

  test('the store\'s own subscription page is where a store subscriber is sent to manage it', () {
    expect(StoreKind.apple.manage.toString(), 'https://apps.apple.com/account/subscriptions');
    expect(StoreKind.google.manage.toString(),
        'https://play.google.com/store/account/subscriptions?sku=openhearts_annual&package=game.openhearts');
  });

  test('the products a build names by default are the ones the config names', () {
    final config = jsonDecode(File('../config/openhearts.json').readAsStringSync()) as Map<String, dynamic>;
    expect(StoreKind.apple.product, (config['apple'] as Map)['product']);
    expect(StoreKind.google.product, (config['google'] as Map)['product']);
  });

  test('the proof is shown to the service signed over, and comes back a licence for this device', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    stand.says('store', {'licence': signedFor(me.publicKey)});
    final said = await presentProof(me, StoreKind.google, 'token-123', service: _service);
    expect(said.answer?.key, me.publicKey);
    final asked = lastAt(stand, 'store');
    expect(asked['store'], 'google');
    expect(asked['proof'], 'token-123');
    expect(asked['key'], me.publicKey);
    // The proof is what is signed for, so it cannot be carried to
    // another key.
    expect(schnorrVerifier(me.publicKey, requestDigest('store', me.publicKey, asked['at'] as int, 'token-123'), asked['sig'] as String),
        isTrue);

    // Somebody else's licence, correctly signed, is nothing here.
    stand.says('store', {'licence': signedFor(SchnorrSigner.generate().publicKey)});
    final theirs = await presentProof(me, StoreKind.google, 'token-123', service: _service);
    expect(theirs.answer, isNull);
    expect(theirs.refusal?.reason, 'licenceNotForThisDevice');
    expect(theirs.refusal?.say(), 'The service\'s answer was not a licence for this device.');
  });

  test('each of the service\'s refusals is said in the app\'s words', () async {
    final stand = standUp();
    final me = SchnorrSigner.generate();
    for (final (status, body, reason, shown) in [
      (400, {'error': 'not a store'}, 'notAStore', 'That is not a store the service knows.'),
      (400, {'error': 'no proof'}, 'noProof', 'The store gave nothing to show for the purchase.'),
      (401, {'error': 'not from the store'}, 'notFromStore', 'That purchase did not come from the store.'),
      (402, {'error': 'not paid'}, 'notPaid', 'The store says that purchase is not paid for.'),
      (409, {'error': 'this device is on another subscription: drop it there first'}, 'onAnotherSubscription',
          'This device is on another subscription. Drop it there first.'),
      (409, {'error': 'the account has all the devices it can take', 'devices': 5, 'most': 5}, 'accountFull',
          'This subscription has all the devices it can take.'),
      (502, {'error': 'the store is not answering'}, 'storeNotAnswering', 'The store is not answering. Try again in a moment.'),
      (503, {'error': 'the store is not set up yet'}, 'storeNotSetUp', 'Buying in the store is not open yet.'),
    ]) {
      stand.says('store', body, status: status);
      final said = await presentProof(me, StoreKind.apple, 'a.b.c', service: _service);
      expect(said.answer, isNull);
      expect(said.refusal?.reason, reason, reason: '$status $body');
      expect(said.refusal?.say(), shown);
    }
    stand.reachable = false;
    expect((await presentProof(me, StoreKind.apple, 'a.b.c', service: _service)).refusal?.say(),
        'Could not reach the service. Try again in a moment.');
  });

  test('a purchase is finished only once the service has taken it, or has said the proof is no good', () async {
    final stand = standUp();
    final store = FakeStore();
    final shop = await shopWith(store);

    // The store is not answering the service: left for next time.
    stand.says('store', {'error': 'the store is not answering'}, status: 502);
    store.says([paid('jws-1')]);
    await pumpEventQueue();
    expect(stand.seen, hasLength(1));
    expect(store.finished, isEmpty);
    expect(Entitlement.current.live, isFalse);
    expect(shop.refusal?.reason, 'storeNotAnswering');

    // On another subscription: may go differently once it is dropped.
    stand.says('store', {'error': 'this device is on another subscription: drop it there first'}, status: 409);
    store.says([paid('jws-1')]);
    await pumpEventQueue();
    expect(store.finished, isEmpty);

    // Not from the store, or not paid for: never going to be taken.
    stand.says('store', {'error': 'not from the store'}, status: 401);
    store.says([paid('jws-forged')]);
    await pumpEventQueue();
    expect(store.finished.map((p) => p.proof), ['jws-forged']);
    stand.says('store', {'error': 'not paid'}, status: 402);
    store.says([paid('jws-refunded')]);
    await pumpEventQueue();
    expect(store.finished.map((p) => p.proof), ['jws-forged', 'jws-refunded']);

    // Taken: the licence kept, and the purchase finished.
    final me = await Identity.signer();
    stand.says('store', {'licence': signedFor(me.publicKey)});
    store.says([paid('jws-1')]);
    await pumpEventQueue();
    expect(Entitlement.current.live, isTrue);
    expect(store.finished.map((p) => p.proof), ['jws-forged', 'jws-refunded', 'jws-1']);
    expect(shop.refusal, isNull);
    expect(shop.boughtHere, isTrue);

    // Another product's purchase is not this app's to show anybody.
    store.says([StorePurchase(product: 'something_else', status: StoreStatus.purchased, proof: 'x', needsFinishing: true)]);
    await pumpEventQueue();
    expect(stand.seen.where((s) => s.contains('"proof":"x"')), isEmpty);
  });

  testWidgets('bought in the store: the sheet opens for this device, and the page becomes a subscriber\'s', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    final store = FakeStore();
    await shopWith(store);
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-10-01'},
      ],
      'most': 5,
    });
    await _pumpPage(tester);

    // The store's price, and what the stores require said beside it.
    expect(canBuyHere, isTrue);
    expect(find.text('£4.99 a year'), findsOneWidget);
    expect(find.textContaining('£4.99 a year, charged to your Apple Account'), findsOneWidget);
    expect(find.textContaining('renews automatically every year until you cancel, at the price then in force, and Apple tells you before a new price applies'), findsOneWidget);
    expect(find.text('By subscribing, you agree to the Terms of use.'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);

    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(store.bought, [storeAccountFor(me.publicKey).apple]);

    // The service takes its time over it: nothing is finished meanwhile.
    final answer = Completer<void>();
    final held = _holdAnswers(answer.future);
    stand.says('store', {'licence': signedFor(me.publicKey)});
    store.says([paid('header.payload.sig')]);
    await tester.pump();
    await tester.pump();
    expect(held.asked, isTrue);
    expect(store.finished, isEmpty);
    expect(Entitlement.current.live, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'still being bought');

    answer.complete();
    await tester.pumpAndSettle();
    final asked = lastAt(stand, 'store');
    expect(asked['proof'], 'header.payload.sig');
    expect(asked['store'], 'apple');
    expect(Entitlement.current.live, isTrue);
    expect(store.finished.single.proof, 'header.payload.sig');

    // A subscriber's page, with the store's settings to manage it in.
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Subscribe'), findsNothing);
    expect(find.text('Cancel or change it in the App Store.'), findsOneWidget);
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a purchase the service could not take is said, and the store keeps it', (tester) async {
    final stand = standUp();
    final store = FakeStore(kind: StoreKind.google);
    await shopWith(store);
    await _pumpPage(tester);
    expect(find.textContaining('charged to your Google account'), findsOneWidget);

    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(store.bought, [storeAccountFor((await Identity.signer()).publicKey).play]);
    stand.says('store', {'error': 'the store is not answering'}, status: 502);
    store.says([StorePurchase(product: StoreKind.google.product, status: StoreStatus.purchased, proof: 'token', needsFinishing: true)]);
    await tester.pumpAndSettle();
    expect(find.text('The store is not answering. Try again in a moment.'), findsOneWidget);
    expect(store.finished, isEmpty);
    expect(Entitlement.current.live, isFalse);
    expect(find.text('Subscribe'), findsOneWidget, reason: 'and the way to try again is there');
  });

  testWidgets('a purchase that falls over here is said, and the store keeps it for next time', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    Entitlement.current = _AdoptFails(service: _service);
    await Entitlement.current.load(me.publicKey);
    final store = FakeStore();
    await shopWith(store);
    await _pumpPage(tester);

    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    stand.says('store', {'licence': signedFor(me.publicKey)});
    store.says([paid('header.payload.sig')]);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the spinner stops');
    expect(find.text('The store did not finish the purchase. Try again in a moment.'), findsOneWidget);
    expect(find.text('Subscribe'), findsOneWidget, reason: 'and the way to try again is there');
    expect(store.finished, isEmpty, reason: 'the store keeps the purchase, to be shown again');
    expect(tester.takeException(), isNull);
  });

  testWidgets("the store's sheet opens only where the store lets the player play live, which is all it sells", (tester) async {
    standUp();
    final store = FakeStore();
    await shopWith(store);
    final age = StoreSays(AgeVerdict.tooYoung);
    await _pumpPage(tester);
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(find.text('Live play is for 13 and older'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(store.bought, isEmpty, reason: 'nothing sold that cannot be played');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Subscribe'), findsOneWidget);

    age.verdict = AgeVerdict.open;
    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(store.bought, hasLength(1));
    expect(age.asked, 2);
  });

  testWidgets('a sheet that does not open, or is closed, leaves the page as it was', (tester) async {
    standUp();
    final store = FakeStore()..sheetOpens = false;
    await shopWith(store);
    await _pumpPage(tester);
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(find.text('The store did not finish the purchase. Try again in a moment.'), findsOneWidget);

    store.sheetOpens = true;
    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('The store did not finish the purchase. Try again in a moment.'), findsNothing);
    store.says([paid('', status: StoreStatus.cancelled)]);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Subscribe'), findsOneWidget);
  });

  testWidgets('a purchase waiting for approval is said to be, and only shown to the service once it is paid',
      (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    final store = FakeStore();
    await shopWith(store);
    await _pumpPage(tester);
    await tester.tap(find.text('Subscribe'));
    await tester.pump();

    store.says([paid('', status: StoreStatus.pending)]);
    await tester.pumpAndSettle();
    expect(find.text('The store is waiting to approve the payment. Live play opens here as soon as it does.'), findsOneWidget);
    expect(stand.seen, isEmpty);
    expect(store.finished, isEmpty);
    expect(Entitlement.current.live, isFalse);

    // Approved, perhaps long after: it comes in as any purchase does.
    stand.says('store', {'licence': signedFor(me.publicKey)});
    stand.says('devices', {'devices': <Object>[], 'most': 5});
    store.says([paid('approved.jws.sig')]);
    await tester.pumpAndSettle();
    expect(Entitlement.current.live, isTrue);
    expect(store.finished.single.proof, 'approved.jws.sig');
    expect(find.textContaining('waiting to approve'), findsNothing);
  });

  testWidgets('restore brings back what this store account has, and says when it has nothing', (tester) async {
    final stand = standUp();
    final me = await Identity.signer();
    final store = FakeStore();
    await shopWith(store);
    await _pumpPage(tester);

    await tester.tap(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    expect(find.text('No subscription to restore was found in this store account.'), findsOneWidget);
    expect(stand.seen, isEmpty);

    // Already finished with on the phone it was bought on, so nothing
    // to finish here: it is shown to the service, and bound to this one.
    store.restoring = [paid('restored.jws.sig', status: StoreStatus.restored)];
    stand.says('store', {'licence': signedFor(me.publicKey)});
    stand.says('devices', {
      'devices': [
        {'key': me.publicKey, 'bound_at': '2026-10-01'},
      ],
      'most': 5,
    });
    await tester.tap(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    expect(lastAt(stand, 'store')['proof'], 'restored.jws.sig');
    expect(Entitlement.current.live, isTrue);
    expect(store.finished, isEmpty);
    expect(find.text('This device'), findsOneWidget);
    expect(find.textContaining('No subscription to restore'), findsNothing);
  });

  testWidgets('a suspended account is told so where live play would be sold, and sold nothing', (tester) async {
    standUp();
    await shopWith(FakeStore());
    await Entitlement.current.suspend();
    await _pumpPage(tester);
    expect(find.text('Suspended from live play'), findsOneWidget);
    expect(find.textContaining('This account is suspended from live play under the terms of use.'), findsOneWidget);
    expect(find.textContaining('help@openhearts.game'), findsOneWidget);
    expect(find.text('Subscribe'), findsNothing);
    expect(find.text('Restore purchases'), findsNothing);
    expect(find.textContaining('Have a code?'), findsNothing);
    expect(find.text('Terms of use'), findsOneWidget, reason: 'what the suspension is under, a tap away');
  });

  testWidgets("a phone whose store has not said what it sells shows no price and no web, and asks the store again", (tester) async {
    standUp();
    final offline = FakeStore(open: false);
    final shop = await shopWith(offline);
    expect(canBuyHere, isFalse);
    expect(offline.asked, 0, reason: 'not available: not asked for the product');
    await _pumpPage(tester);
    expect(find.textContaining(r'$5.99'), findsNothing, reason: 'no price until the store says its own');
    expect(find.textContaining('a year'), findsNothing);
    expect(find.textContaining('web'), findsNothing);
    expect(find.text("The App Store hasn't said what live play costs yet. Check that you're online, then tap Subscribe to ask it again."), findsOneWidget);
    expect(find.text('Restore purchases'), findsNothing);
    expect(find.textContaining('By subscribing'), findsNothing, reason: 'nothing is bought here');

    // Back online: Subscribe asks again, and the store's own sheet opens
    // at the store's price.
    offline.open = true;
    await tester.tap(find.text('Subscribe'));
    // The sheet's spinner turns until the store says: pumped, not settled.
    await tester.pump();
    await tester.pump();
    expect(shop.ready, isTrue);
    expect(offline.bought, hasLength(1), reason: 'the sheet opened once the store said');
    expect(find.text('£4.99 a year'), findsOneWidget);
    expect(find.textContaining("hasn't said"), findsNothing);
    // Once it has said, it is not asked again.
    final asked = offline.asked;
    await tester.pumpWidget(const SizedBox());
    // The sheet still up, its spinner turning: pumped, not settled.
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SubscribePage()));
    await tester.pump();
    expect(offline.asked, asked);
    expect(shop.ready, isTrue);

    // A store without the product, as Google Play: asked again when the
    // page opens, and said as itself.
    await tester.pumpWidget(const SizedBox());
    final productless = FakeStore(kind: StoreKind.google, price: null);
    await shopWith(productless);
    expect(productless.asked, 1);
    await _pumpPage(tester);
    expect(productless.asked, 2, reason: 'the page asks again');
    expect(find.text("Google Play hasn't said what live play costs yet. Check that you're online, then tap Subscribe to ask it again."), findsOneWidget);
    // Then the product comes: opening the page is enough.
    productless.price = '4,99 €';
    await tester.pumpWidget(const SizedBox());
    await _pumpPage(tester);
    expect(find.text('4,99 € a year'), findsOneWidget);
    expect(productless.bought, isEmpty, reason: 'opening the page buys nothing');
  });

  testWidgets('with no store, a build that cannot leave for Stripe sells nothing, and the web goes to Stripe', (tester) async {
    final stand = standUp();
    StoreShop.current = StoreShop(null);
    addTearDown(() => StoreShop.current = StoreShop(null));
    expect(canBuyHere, isFalse);
    expect(priceShown, r'$5.99');
    await _pumpPage(tester);
    expect(find.text(r'$5.99 a year'), findsOneWidget);
    expect(find.text('Restore purchases'), findsNothing);
    expect(find.textContaining('renews automatically'), findsNothing);
    expect(find.textContaining('By subscribing'), findsNothing, reason: 'nothing is bought here');
    expect(find.text('Buying is not open on this device yet.'), findsOneWidget);

    // And the web goes to Stripe, not to a store: here, first to a
    // checkout handler the stand-in service has no answer for.
    final wasCan = canLeaveForStripe;
    final wasLeave = leaveFor;
    final sentTo = <String>[];
    canLeaveForStripe = true;
    leaveFor = sentTo.add;
    addTearDown(() {
      canLeaveForStripe = wasCan;
      leaveFor = wasLeave;
    });
    await tester.pumpWidget(const SizedBox());
    await _pumpPage(tester);
    // What California's automatic renewal law asks for beside the
    // button: the price, the period, that it renews and at what price,
    // and how to cancel.
    expect(
      find.text(
        r"$5.99 a year plus any tax, sold by Link, Stripe's affiliate, on Stripe's page. It renews automatically every year until you cancel, at the price then in force: we email you at least 7 days before a new price would apply. Cancel whenever you like under Manage subscription, and live play lasts to the end of the year you paid for.",
      ),
      findsOneWidget,
    );
    expect(find.text('By subscribing, you agree to the Terms of use.'), findsOneWidget);
    expect(find.text('Restore purchases'), findsNothing);
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(find.text('The shop is not open yet.'), findsOneWidget);
    expect(sentTo, isEmpty);
    // Asked in the app's language, which Stripe's page and the terms it
    // links are then in.
    expect(lastAt(stand, 'checkout')['lang'], 'en');

    // A checkout on Stripe's own host is gone to. (The page spins on
    // until the browser has gone, so it never settles.)
    stand.says('checkout', {'url': 'https://checkout.stripe.com/c/pay/cs_test_1'});
    await tester.pumpWidget(const SizedBox());
    await _pumpPage(tester);
    await tester.tap(find.text('Subscribe'));
    await tester.pump(const Duration(seconds: 1));
    expect(sentTo, ['https://checkout.stripe.com/c/pay/cs_test_1']);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Holds the stand-in service's answers until [until], and says
/// whether it was asked meanwhile.
_Held _holdAnswers(Future<void> until) {
  final held = _Held();
  final through = askService;
  askService = (url, body) async {
    held.asked = true;
    await until;
    return through(url, body);
  };
  return held;
}

class _Held {
  bool asked = false;
}

/// An entitlement whose licence cannot be kept: the device's storage
/// refusing the write, say.
class _AdoptFails extends Entitlement {
  _AdoptFails({super.service});

  @override
  Future<bool> adopt(Licence licence) async => throw StateError('storage refused the licence');
}
