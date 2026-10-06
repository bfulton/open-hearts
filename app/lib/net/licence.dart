/// What a device holds instead of a receipt (docs/06-service.md).
///
/// A licence is a short statement signed by the service's key —
/// this device's key, its account, a date, and the plan — which the app checks
/// against a key baked into the build, the same way it checks
/// everything else it is told. Three things follow.
///
/// A device that cannot reach us keeps playing until the date on its
/// licence, which is the only sane behaviour for a game people take on
/// a train. Nothing about the purchase is on the device except the
/// statement, so there is nothing on it worth stealing. And the service
/// is never in a game's latency path: a licence is read at the front
/// door, not at a trick.
///
/// The date is short — a month — and renewed while the subscription
/// lives. That is what makes cancellation and refunds work without a
/// revocation list to distribute and check: a cancelled subscription
/// stops being renewed, and the last licence runs out.
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;
import 'remote_config.dart' show waits;

/// The service this build will take a licence from, and no other. A
/// licence signed by anything else is not a licence, which is the whole
/// of what makes the statement worth carrying.
///
/// Named at build time — `--dart-define=OH_SERVICE_KEY=<64 hex>` —
/// from the public half of the pair whose secret lives in the project's
/// secrets and nowhere else (`dart run service:service_key` mints one;
/// deploy.sh passes OH_SERVICE_KEY through; the browser suite names its
/// own rig's, e2e/build.sh). A build that names nobody is told nothing
/// by anybody: every device unlicensed, rather than every device
/// licensed by whoever asks first.
const serviceKey = String.fromEnvironment('OH_SERVICE_KEY');

// The licence itself — this device's key, its account, a date and the
// plan, signed by the service — is the table package's (licence.dart
// there): every peer at a table checks every seat's by it.

/// Where the service's handlers are, by name: the origin this app was
/// served by, which is the site the worker runs beside. Over http as
/// well as https — the browser suite serves the app and the handlers
/// together on localhost (docs/06-service.md) — and nowhere at all
/// when there is no origin, which is a build asking nobody rather than
/// asking anybody.
///
/// Settable, the way the signature verifier is (table's signing.dart):
/// one seam for the tests to stand their own service in, rather than
/// one per call.
Uri? Function(String handler) handlerAt = (handler) => handlerFor(handler, Uri.base);

Uri? handlerFor(String handler, Uri at) {
  if (at.host.isEmpty) return null;
  if (at.scheme != 'https' && at.scheme != 'http') return null;
  return Uri(scheme: at.scheme, host: at.host, port: at.hasPort ? at.port : null, path: '/api/$handler');
}

/// What every handler is asked with: this device's key, the second the
/// request is made, and the key's signature over both and over what is
/// asked for — the code being spent, the device being dropped — or
/// nothing (service/functions/worker.mjs).
///
/// A key is public: it signs every event this device says at a table,
/// and the relays hand those to anybody. So the service acts for a key
/// only on a request the key signed, or anybody who had read it could
/// list this device's household, drop it, or make a code against what
/// it paid for.
Map<String, Object?> signedAsk(Signer signer, String handler, {String what = '', DateTime? now}) {
  final at = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return {'key': signer.publicKey, 'at': at, 'sig': signer.sign(requestDigest(handler, signer.publicKey, at, what))};
}

/// The hash a request's signature is over. A line each, and none of
/// them can hold a newline but the last, so there is one way to read
/// it; the handler is in it, so a licence request is never spent as a
/// request for a code.
String requestDigest(String handler, PublicKey key, int at, [String what = '']) =>
    sha256Hex(utf8.encode('oh-request/1\n$handler\n$key\n$at\n$what'));

/// This device's licence as the service will give it: the current one,
/// or null when the service says there is no subscription behind the
/// key, when it cannot be reached, or when what comes back is not a
/// licence signed for this device.
///
/// Never throws: a front door that fell over because a handler was slow
/// would be worse than one that waits for the date on the licence it
/// already has.
Future<Licence?> fetchLicence(Signer signer,
    {Uri? endpoint, String service = serviceKey, Duration? timeout}) async {
  timeout ??= waits.licence;
  final url = endpoint ?? handlerAt('licence');
  if (url == null) return null;
  try {
    final body = await http.postJson(url, jsonEncode(signedAsk(signer, 'licence'))).timeout(timeout);
    if (body == null) return null;
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final licence = Licence.parse(json['licence']);
    if (licence == null) return null;
    return licence.holdsFor(signer.publicKey, service: service) ? licence : null;
  } catch (_) {
    return null;
  }
}
