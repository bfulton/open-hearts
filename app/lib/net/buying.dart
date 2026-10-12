/// Buying live play (docs/explanation/service.md).
///
/// On the web that is Stripe Checkout, in subscription mode: this
/// device asks the service for a session with its own key in the
/// metadata, the browser goes there, and Stripe's webhook lands at the
/// service's entitle handler with that key. Nobody is asked to make an
/// account, and nothing about the card comes back here — what comes
/// back is a licence (licence.dart).
///
/// On a phone it is the store's own subscription (store_buying.dart),
/// and never a checkout: [canBuyHere] is true there once the store has
/// said what the product costs, and false until then, saying so rather
/// than opening a checkout a phone should not be using.
library;

import 'dart:convert';

import 'package:table/table.dart';

import '../l10n/l10n.dart';
import 'buying_io.dart' if (dart.library.js_interop) 'buying_web.dart' as platform;
import 'household.dart' show askService;
import 'http.dart' as http;
import 'licence.dart';
import 'remote_config.dart';
import 'store_buying.dart';

/// What live play costs a year, as it is written on the front door
/// (`pricePerYear`, l10n). The shape of the price is chosen by the fees
/// — a year rather than a month, since a card's fixed thirty cents is
/// paid once (docs/explanation/service.md).
const priceAmount = r'$5.99';

/// The price as shown: the store's, in a store build, since it is the
/// store's price that is charged and in the buyer's own currency; else
/// the operator's, when remote config gives one with a new Stripe
/// price; and the build's otherwise.
String get priceShown => StoreShop.current.product?.price ?? RemoteSettings.current.config.price ?? priceAmount;

/// Whether this build can take money at all: the web can, over Stripe;
/// a phone can over its store, once the store has the product.
bool get canBuyHere => canLeaveForStripe || StoreShop.current.ready;

/// Whether this build can be sent to Stripe and brought back, and how
/// it goes: the platform's, and a test's to replace.
bool canLeaveForStripe = platform.canLeaveForCheckout;
void Function(String url) leaveFor = platform.leaveFor;

/// The app's own address, which is where a purchase comes back to.
/// Kept whole — a driven build stays driven across the round trip
/// (net/address.dart).
String returnAddress(Uri at, {required bool bought}) {
  final params = Map<String, String>.from(at.queryParameters)..remove('bought');
  if (bought) params['bought'] = '1';
  return Uri(
    scheme: at.scheme,
    host: at.host,
    port: at.hasPort ? at.port : null,
    path: at.path.isEmpty ? '/' : at.path,
    queryParameters: params.isEmpty ? null : params,
    // The page that left (pages.dart): Stripe's link home comes back to
    // it, as the back button does.
    fragment: at.fragment.isEmpty ? null : at.fragment,
  ).toString();
}

/// Whether this load is the one coming back from a checkout.
bool boughtJustNow([Uri? at]) => (at ?? Uri.base).queryParameters.containsKey('bought');

/// Why a checkout could not be opened.
enum BuyRefusal {
  /// This build has no way to take money.
  notHere,

  /// The shop's handler did not answer.
  unreachable,

  /// It answered, with no checkout to go to.
  shut,

  /// The subscription was bought in a store, and is managed there.
  elsewhere;

  /// As the player is told it.
  String say([AppLocalizations? words]) {
    final say = words ?? english;
    return switch (this) {
      notHere => say.buyingNotOpen,
      unreachable => say.shopUnreachable,
      shut => say.shopNotOpen,
      elsewhere => say.managedWhereBought,
    };
  }
}

/// Opens a checkout for [signer]'s key and leaves for it. Returns a
/// reason when it could not, which the screen says rather than sitting
/// there having apparently done nothing; null when the browser is on
/// its way there.
Future<BuyRefusal?> buy(Signer signer, {Uri? endpoint, Uri? from, Duration? timeout}) async {
  timeout ??= waits.buy;
  if (!canLeaveForStripe) return BuyRefusal.notHere;
  final url = endpoint ?? handlerAt('checkout');
  if (url == null) return BuyRefusal.notHere;
  final at = from ?? Uri.base;
  String? body;
  try {
    body = await http
        .postJson(
            url,
            jsonEncode({
              ...signedAsk(signer, 'checkout'),
              'back': returnAddress(at, bought: true),
              'cancelled': returnAddress(at, bought: false),
            }))
        .timeout(timeout);
  } catch (_) {
    return BuyRefusal.unreachable;
  }
  if (body == null) return BuyRefusal.shut;
  final to = _checkoutUrl(body);
  if (to == null) return BuyRefusal.shut;
  leaveFor(to);
  return null;
}

/// Opens Stripe's billing portal for the web subscription [signer]'s
/// device is on — to cancel, change the card, read an invoice — and
/// leaves for it, coming back to where it was. A reason when it could
/// not; null when the browser is on its way.
Future<BuyRefusal?> manageSubscription(Signer signer, {Uri? endpoint, Uri? from, Duration? timeout}) async {
  timeout ??= waits.buy;
  if (!canLeaveForStripe) return BuyRefusal.notHere;
  final url = endpoint ?? handlerAt('manage');
  if (url == null) return BuyRefusal.notHere;
  final at = from ?? Uri.base;
  ({int status, String body}) answer;
  try {
    answer = await askService(url, jsonEncode({...signedAsk(signer, 'manage'), 'back': returnAddress(at, bought: false)}))
        .timeout(timeout);
  } catch (_) {
    return BuyRefusal.unreachable;
  }
  if (answer.status == 409) return BuyRefusal.elsewhere;
  if (answer.status != 200) return BuyRefusal.shut;
  final to = _stripeUrl(answer.body, (host) => host == 'billing.stripe.com');
  if (to == null) return BuyRefusal.shut;
  leaveFor(to);
  return null;
}

/// The checkout's address out of the handler's answer, and only if it
/// is one of Stripe's: this device is about to be sent there, and what
/// it is sent to is not a place a bad answer gets to choose.
String? _checkoutUrl(String body) =>
    _stripeUrl(body, (host) => host == 'checkout.stripe.com' || host.endsWith('.checkout.stripe.com'));

/// The `url` of a handler's answer, over https to a host [ours] takes.
String? _stripeUrl(String body, bool Function(String host) ours) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final to = json['url'];
    if (to is! String) return null;
    final at = Uri.tryParse(to);
    if (at == null || at.scheme != 'https') return null;
    return ours(at.host) ? to : null;
  } catch (_) {
    return null;
  }
}
