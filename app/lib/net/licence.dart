/// What a device holds instead of a receipt (docs/06-service.md).
///
/// A licence is a short statement signed by the service's key —
/// this device's key, a date, and the plan — which the app checks
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

class Licence {
  const Licence({required this.key, required this.until, required this.plan, required this.signature});

  /// What the signed text begins with, so a signature over one kind of
  /// statement can never be read as a signature over another.
  static const statement = 'oh-licence/1';

  /// The device the licence is for. A licence is a device's; a
  /// subscription is a person's, and carries several (doc 06).
  final PublicKey key;

  /// The last day this licence is good for, at midnight UTC. It runs to
  /// the end of that day: see [goodAt].
  final DateTime until;

  /// What was bought. One plan so far.
  final String plan;

  /// The service's signature over [digest].
  final String signature;

  /// A day as the statement spells it: an ISO date, UTC.
  static String dayOf(DateTime at) {
    final d = at.toUtc();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Midnight UTC on [day], or null when it is not a day.
  static DateTime? dayFrom(String day) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(day);
    if (m == null) return null;
    final at = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    // A date that does not exist — the thirty-first of February —
    // rolls over rather than failing, so it is caught by spelling it
    // back out.
    return dayOf(at) == day ? at : null;
  }

  /// The text the service signs. A line each, and none of the four can
  /// hold a newline, so there is one way to read it.
  String get canonical => '$statement\n$key\n${dayOf(until)}\n$plan';

  String get digest => sha256Hex(utf8.encode(canonical));

  /// Signed by the holder of [service].
  ///
  /// The curve itself, never [verify]: that one also takes a simulated
  /// table's fake signature, which is a hash of the signer's *public*
  /// key and so is forgeable by anyone who can read one. A fake table
  /// can afford that; the one statement that says what was paid for
  /// cannot.
  bool signedBy(PublicKey service) {
    if (service.length != 64 || signature.length != 128) return false;
    try {
      return schnorrVerifier(service, digest, signature);
    } catch (_) {
      return false;
    }
  }

  /// Still good at [at]: the date is the last day, so it runs to the
  /// end of that day.
  bool goodAt(DateTime at) => at.toUtc().isBefore(until.add(const Duration(days: 1)));

  /// Everything at once, which is the only question the front door
  /// asks: this device's, this service's, and not run out.
  bool holdsFor(PublicKey device, {String service = serviceKey, DateTime? at}) =>
      key == device && signedBy(service) && goodAt(at ?? DateTime.now());

  Map<String, Object?> toJson() => {'key': key, 'until': dayOf(until), 'plan': plan, 'sig': signature};

  /// The licence as it travels and as it is kept on the device.
  String get encoded => jsonEncode(toJson());

  /// A licence off the wire or off the device; null when what is there
  /// is not one. Nothing here trusts it — [holdsFor] does the trusting.
  static Licence? parse(Object? json) {
    if (json is String) {
      try {
        return parse(jsonDecode(json));
      } catch (_) {
        return null;
      }
    }
    if (json is! Map) return null;
    final key = json['key'];
    final until = json['until'];
    final plan = json['plan'];
    final sig = json['sig'];
    if (key is! String || until is! String || plan is! String || sig is! String) return null;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) return null;
    final day = dayFrom(until);
    if (day == null) return null;
    return Licence(key: key, until: day, plan: plan, signature: sig);
  }

  @override
  String toString() => 'Licence(${key.substring(0, 8)}… to ${dayOf(until)}, $plan)';
}

/// Where a licence comes from: the app's origin, which is the site the
/// handlers run beside, over http or https alike — the browser suite
/// serves the app and the handlers together on localhost (doc 06,
/// local mode), and a build with no origin at all asks nobody.
Uri? licenceEndpoint([Uri? base]) {
  final at = base ?? Uri.base;
  if (at.host.isEmpty) return null;
  if (at.scheme != 'https' && at.scheme != 'http') return null;
  return Uri(scheme: at.scheme, host: at.host, port: at.hasPort ? at.port : null, path: '/api/licence');
}

/// This device's licence as the service will give it: the current one,
/// or null when the service says there is no subscription behind the
/// key, when it cannot be reached, or when what comes back is not a
/// licence signed for this device.
///
/// Never throws: a front door that fell over because a handler was slow
/// would be worse than one that waits for the date on the licence it
/// already has.
Future<Licence?> fetchLicence(Signer signer,
    {Uri? endpoint, String service = serviceKey, Duration timeout = const Duration(seconds: 6)}) async {
  final url = endpoint ?? licenceEndpoint();
  if (url == null) return null;
  try {
    final body = await http.postJson(url, jsonEncode({'key': signer.publicKey})).timeout(timeout);
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
