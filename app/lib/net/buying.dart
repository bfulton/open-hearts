/// Buying live play (docs/06-service.md).
///
/// On the web that is Stripe Checkout, in subscription mode: this
/// device asks the service for a session with its own key in the
/// metadata, the browser goes there, and Stripe's webhook lands at the
/// service's entitle handler with that key. Nobody is asked to make an
/// account, and nothing about the card comes back here — what comes
/// back is a licence (licence.dart).
///
/// On a phone it will be the store's own subscription, which needs the
/// app to be in a store first: [canBuyHere] is false there for now, and
/// says so rather than opening a checkout a phone should not be using.
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'licence.dart';
import 'buying_io.dart' if (dart.library.js_interop) 'buying_web.dart' as platform;
import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;

/// What live play costs, as it is written on the front door. The shape
/// of the price is chosen by the fees — a year rather than a month,
/// since a card's fixed thirty cents is paid once (doc 06).
const price = r'$2.99 a year';

/// Whether this build can take money at all: the web can, over Stripe;
/// a phone will over its store, and does not yet.
bool get canBuyHere => platform.canLeaveForCheckout;

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
  ).toString();
}

/// Whether this load is the one coming back from a checkout.
bool boughtJustNow([Uri? at]) => (at ?? Uri.base).queryParameters.containsKey('bought');

/// Why a checkout could not be opened, phrased for the screen; null
/// when one was and the browser is on its way there.
typedef Refusal = String?;

/// Opens a checkout for [signer]'s key and leaves for it. Returns a
/// reason when it could not, which the screen says rather than sitting
/// there having apparently done nothing.
Future<Refusal> buy(Signer signer, {Uri? endpoint, Uri? from, Duration timeout = const Duration(seconds: 12)}) async {
  if (!canBuyHere) return 'Buying is not open on this device yet.';
  final url = endpoint ?? handlerAt('checkout');
  if (url == null) return 'Buying is not open on this device yet.';
  final at = from ?? Uri.base;
  String? body;
  try {
    body = await http
        .postJson(
            url,
            jsonEncode({
              'key': signer.publicKey,
              'back': returnAddress(at, bought: true),
              'cancelled': returnAddress(at, bought: false),
            }))
        .timeout(timeout);
  } catch (_) {
    return 'Could not reach the shop. Try again in a moment.';
  }
  if (body == null) return 'The shop is not open yet.';
  final to = _checkoutUrl(body);
  if (to == null) return 'The shop is not open yet.';
  platform.leaveFor(to);
  return null;
}

/// The checkout's address out of the handler's answer, and only if it
/// is one of Stripe's: this device is about to be sent there, and what
/// it is sent to is not a place a bad answer gets to choose.
String? _checkoutUrl(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final to = json['url'];
    if (to is! String) return null;
    final at = Uri.tryParse(to);
    if (at == null || at.scheme != 'https') return null;
    return at.host == 'checkout.stripe.com' || at.host.endsWith('.checkout.stripe.com') ? to : null;
  } catch (_) {
    return null;
  }
}
