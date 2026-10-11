/// Buying live play in a phone's own store (docs/explanation/service.md).
///
/// The store takes the money and keeps the subscription; the service
/// is shown what the store handed back — the App Store's signed
/// transaction, or Google Play's purchase token — and answers with a
/// licence for this device, the same one a web checkout or a household
/// code brings. Nobody is asked to make an account here either.
///
/// What the store records the purchase against is a name made from
/// this device's key ([storeAccountFor]), so the store's own
/// notifications, which reach the service with nothing of the app in
/// them, still say which device paid.
///
/// A purchase is finished with the store only once the service has
/// taken it, or has said the store's proof is no good: a purchase the
/// store thinks delivered and the service never heard of is money
/// taken for nothing, and one left open is one the store hands back
/// next time — at the next start, or at Restore.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import '../entitlement.dart';
import 'household.dart';
import 'licence.dart';
import 'remote_config.dart' show waits;
import 'report_error.dart';
import 'store_buying_io.dart' if (dart.library.js_interop) 'store_buying_web.dart' as platform;

/// Which store, as the service is told it.
enum StoreKind {
  apple,
  google;

  /// The product bought there. Named at build time from
  /// config/openhearts.json (build_phone.sh), since the product is made
  /// in the store's console and not here; the default is the same name.
  String get product => switch (this) {
        apple => const String.fromEnvironment('OH_APPLE_PRODUCT', defaultValue: 'openhearts_annual'),
        google => const String.fromEnvironment('OH_PLAY_PRODUCT', defaultValue: 'openhearts_annual'),
      };

  /// The store's own page for a subscriber's subscriptions, which is
  /// where one bought there is cancelled: the app cannot, and neither
  /// can the service.
  Uri get manage => switch (this) {
        apple => Uri.parse('https://apps.apple.com/account/subscriptions'),
        google => Uri.https('play.google.com', '/store/account/subscriptions', {'sku': product, 'package': playPackage}),
      };
}

/// The app's id in Google Play, which its subscriptions page wants
/// alongside the product's.
const playPackage = String.fromEnvironment('OH_PLAY_PACKAGE', defaultValue: 'game.openhearts');

/// What a purchase is recorded against in each store, made from the
/// device's key: Google Play's obfuscated account id, and the App
/// Store's app account token, which has to be a UUID. Hashed, with a
/// tag of its own, so neither store is given the key itself and
/// neither name can be read as anything else's. The service makes the
/// same two from a key and finds the device a notification is about.
({String play, String apple}) storeAccountFor(PublicKey key) {
  final h = sha256Hex(utf8.encode('oh-store/1\n${key.toLowerCase()}'));
  // A version-4, RFC 4122 UUID from the first sixteen bytes: the
  // version and variant bits are set, the rest is the hash.
  final b = [for (var i = 0; i < 32; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
  return (play: h, apple: uuid);
}

/// What the store says it sells, as far as this page needs it.
class StoreProduct {
  const StoreProduct({required this.id, required this.price, this.native});

  final String id;

  /// The price as the store writes it, in the buyer's own currency.
  /// The store's word is the one shown: a review rejects a price the
  /// app wrote itself.
  final String price;

  /// The store's own description of it, to buy it with.
  final Object? native;
}

enum StoreStatus { purchased, restored, pending, cancelled, error }

/// A purchase as the store reports it.
class StorePurchase {
  const StorePurchase({
    required this.product,
    required this.status,
    this.proof = '',
    this.needsFinishing = false,
    this.native,
  });

  final String product;
  final StoreStatus status;

  /// What the service is shown: the App Store's signed transaction, or
  /// Google Play's purchase token. Empty for one not paid yet.
  final String proof;

  /// Whether the store is waiting to be told the purchase was
  /// delivered. Google refunds one never acknowledged.
  final bool needsFinishing;

  final Object? native;
}

/// A phone's store, as this app uses it. The plugin's on a phone
/// (store_buying_io.dart), a test's own in a test.
abstract interface class PhoneStore {
  StoreKind get kind;

  /// Whether the store can take a payment on this device at all.
  Future<bool> available();

  /// The product, or null when the store has no such thing.
  Future<StoreProduct?> product(String id);

  /// Every purchase the store tells the app about: the one just made,
  /// one pending approval, a renewal, one left unfinished last time,
  /// and those a restore brings back.
  Stream<List<StorePurchase>> get purchases;

  /// Opens the store's sheet for [product], recorded against
  /// [account]. What comes of it comes in [purchases]. False when the
  /// sheet did not open.
  Future<bool> buy(StoreProduct product, {required String account});

  /// Asks the store for the purchases this store account already has;
  /// they come in [purchases].
  Future<void> restore();

  /// Tells the store the purchase was dealt with.
  Future<void> finish(StorePurchase purchase);
}

/// The store this build buys in, or null on the web and on a desktop.
PhoneStore? storeHere() => platform.storeHere();

/// The store's proof, shown to the service: the licence it was taken
/// for, or why not. As a household code is claimed (household.dart,
/// [claimCode]), and signed over the proof, so the proof cannot be
/// carried to another key.
Future<Said<Licence>> presentProof(Signer signer, StoreKind store, String proof,
    {Uri? endpoint, String service = serviceKey}) async {
  // The service asks the store in turn, which is slower than a
  // household's question: the wait is a checkout's.
  final answer =
      await askHandler('store', signer, {'store': store.name, 'proof': proof}, endpoint, what: proof, timeout: waits.buy);
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  Licence? licence;
  try {
    final json = jsonDecode(answer!.body);
    if (json is Map) licence = Licence.parse(json['licence']);
  } on FormatException {
    debugPrint('store: the service\'s answer is not JSON');
  }
  if (licence == null || !licence.holdsFor(signer.publicKey, service: service)) {
    return (answer: null, refusal: const Refused('licenceNotForThisDevice'));
  }
  return (answer: licence, refusal: null);
}

/// Refusals that say the proof itself is no good — not from the store,
/// or not paid for — after which the purchase is finished with: it is
/// never going to be taken, and a store that keeps handing it back
/// only says the same thing again. Anything else — a service or a
/// store not answering, a device on another subscription — may go
/// differently next time, so the purchase is left for then.
const _settled = {'notFromStore', 'notPaid'};

/// Buying in the store this build is in: the product, the purchases
/// as they arrive, and what the service made of them.
class StoreShop extends ChangeNotifier {
  StoreShop(this.store);

  /// The one this app buys through. A global, as [Entitlement.current]
  /// is, and settable, so a test can stand its own store behind it.
  static StoreShop current = StoreShop(storeHere());

  static const _boughtHere = 'store_bought';

  final PhoneStore? store;

  Signer? _signer;
  StreamSubscription<List<StorePurchase>>? _listening;
  Future<void> _queue = Future.value();

  StoreProduct? _product;
  bool _busy = false;
  bool _pending = false;
  bool _bought = false;
  Refused? _refusal;
  int _restored = 0;

  /// The product, once the store has said what it costs.
  StoreProduct? get product => _product;

  /// Whether this build buys in a store: there is one, it can take a
  /// payment, and it has the product.
  bool get ready => store != null && _product != null;

  /// A sheet open, a restore asked for, or a proof with the service.
  bool get busy => _busy;

  /// A purchase the store is holding for approval — a parent's, or a
  /// payment method that takes time.
  bool get pending => _pending;

  /// Whether this device's subscription was bought in this store, so
  /// it is managed there.
  bool get boughtHere => _bought;

  /// What the last purchase or restore came to, when it came to
  /// nothing.
  Refused? get refusal => _refusal;

  /// Asks the store what it sells, and listens for purchases. Called
  /// once, behind the first frame: anything the store holds for this
  /// app — a renewal, a purchase the service did not take last time —
  /// comes in as soon as it is listened for.
  Future<void> open(Signer signer) async {
    final store = this.store;
    if (store == null || _signer != null) return;
    _signer = signer;
    try {
      _bought = (await SharedPreferences.getInstance()).getBool(_boughtHere) ?? false;
    } on Exception catch (e) {
      debugPrint('store: whether this device bought cannot be read: $e');
    }
    // One at a time, in the order the store said them; and one that
    // fell over does not stop the next being heard.
    _listening = store.purchases.listen((purchases) {
      _queue = _queue.then((_) => _handle(purchases)).catchError((Object error, StackTrace stack) {
        reportError(error, stack, where: 'store purchases');
      });
    });
    try {
      if (await store.available()) _product = await store.product(store.kind.product);
    } catch (_) {
      _product = null;
    }
    notifyListeners();
  }

  /// Opens the store's sheet. What comes of it arrives as a purchase.
  Future<void> buy() async {
    final store = this.store;
    final product = _product;
    final signer = _signer;
    if (store == null || product == null || signer == null || _busy) return;
    final account = storeAccountFor(signer.publicKey);
    _set(busy: true, clear: true);
    var opened = false;
    try {
      opened = await store.buy(product, account: store.kind == StoreKind.apple ? account.apple : account.play);
    } on Exception catch (e) {
      // Said as storeFailed, below; what the store said is for a trace.
      debugPrint('store: the purchase did not open: $e');
    }
    if (!opened) _set(busy: false, refusal: const Refused('storeFailed'));
  }

  /// Asks the store for this store account's subscription, which the
  /// service then binds to this device as it would a purchase. Apple
  /// requires the button; a new phone needs it.
  Future<void> restore() async {
    final store = this.store;
    if (store == null || _signer == null || _busy) return;
    _set(busy: true, clear: true);
    _restored = 0;
    try {
      await store.restore();
      // What the store found comes on the stream, not back from the
      // call: give it the turn to arrive, and then the service its
      // turn to answer, before saying whether there was anything.
      await Future<void>.delayed(Duration.zero);
      await _queue;
      if (_restored == 0) {
        _set(busy: false, refusal: const Refused('nothingToRestore'));
      } else {
        _set(busy: false);
      }
    } catch (_) {
      _set(busy: false, refusal: const Refused('storeFailed'));
    }
  }

  Future<void> _handle(List<StorePurchase> purchases) async {
    for (final purchase in purchases) {
      // One that falls over is said on the page, as a store that did not
      // finish, and reported: the spinner does not turn for ever, and
      // the purchase stays with the store, unfinished, for next time.
      try {
        await _take(purchase);
      } catch (error, stack) {
        reportError(error, stack, where: 'store purchase');
        _set(busy: false, pending: false, refusal: const Refused('storeFailed'));
      }
    }
  }

  Future<void> _take(StorePurchase purchase) async {
    final store = this.store!;
    final signer = _signer!;
    if (purchase.product != store.kind.product) return;
    switch (purchase.status) {
      case StoreStatus.pending:
        _set(busy: false, pending: true);
      case StoreStatus.cancelled:
        _set(busy: false, pending: false);
      case StoreStatus.error:
        _set(busy: false, pending: false, refusal: const Refused('storeFailed'));
      case StoreStatus.purchased || StoreStatus.restored:
        if (purchase.proof.isEmpty) return;
        if (purchase.status == StoreStatus.restored) _restored++;
        _set(busy: true, pending: false);
        final said = await presentProof(signer, store.kind, purchase.proof, service: Entitlement.current.service);
        final licence = said.answer;
        if (licence != null) {
          await Entitlement.current.adopt(licence);
          _bought = true;
          try {
            await (await SharedPreferences.getInstance()).setBool(_boughtHere, true);
          } on Exception catch (e) {
            debugPrint('store: that this device bought is not kept: $e');
          }
          await _finish(purchase);
          _set(busy: false, clear: true);
        } else {
          if (_settled.contains(said.refusal!.reason)) await _finish(purchase);
          _set(busy: false, refusal: said.refusal);
        }
    }
  }

  Future<void> _finish(StorePurchase purchase) async {
    if (!purchase.needsFinishing) return;
    try {
      await store!.finish(purchase);
    } on Exception catch (e) {
      // Unfinished, the store offers it again at the next start, and it
      // is taken again then.
      debugPrint('store: a purchase not finished: $e');
    }
  }

  /// [clear] takes away what the last attempt was refused for.
  void _set({bool? busy, bool? pending, Refused? refusal, bool clear = false}) {
    if (busy != null) _busy = busy;
    if (pending != null) _pending = pending;
    if (refusal != null || clear) _refusal = refusal;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_listening?.cancel());
    super.dispose();
  }
}
