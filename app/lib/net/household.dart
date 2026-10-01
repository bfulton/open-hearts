/// A subscription is a person's, not a device's (docs/06-service.md).
///
/// So a second device has to be able to hold the same licence. The way
/// that costs nothing to type: the subscribed device shows a code, and
/// the other device arrives carrying it. The code goes in a link and
/// the link goes in a QR, so the phone's own camera is the scanner —
/// there is no camera in this app, and no permission to ask for.
///
/// A code is spent the first time it is used, so a photograph of
/// somebody's screen an hour later is worth nothing. Five devices to a
/// subscription, and any of them can drop another: unbounded sharing is
/// a subscription shared with the internet, and five is a household.
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'licence.dart';
import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;

/// A device on a subscription, as the service lists them.
class Device {
  const Device({required this.key, this.boundAt});

  final PublicKey key;
  final String? boundAt;

  /// Enough of the key to tell two devices apart at a glance, which is
  /// all anyone can do: a device has no name here and is not asked for
  /// one.
  String get shortened => key.substring(0, 6);
}

/// The devices on this subscription, and how many it carries.
class Household {
  const Household({required this.devices, required this.most});

  final List<Device> devices;
  final int most;

  bool get full => devices.length >= most;

  static Household? parse(Object? json) {
    if (json is! Map) return null;
    final list = json['devices'];
    final most = json['most'];
    if (list is! List || most is! int) return null;
    return Household(
      devices: [
        for (final d in list)
          if (d is Map && d['key'] is String) Device(key: d['key'] as String, boundAt: d['bound_at'] as String?),
      ],
      most: most,
    );
  }
}

/// A code another device can arrive with, and how long it is worth
/// anything for.
class Ticket {
  const Ticket({required this.code, required this.expires});

  final String code;
  final DateTime? expires;

  static Ticket? parse(Object? json) {
    if (json is! Map) return null;
    final code = json['ticket'];
    if (code is! String || code.isEmpty) return null;
    return Ticket(code: code, expires: DateTime.tryParse(json['expires_at'] as String? ?? ''));
  }
}

/// The link a code travels in: this app's own address, carrying the
/// code and nothing that belonged to this device's session.
String claimLink(String code, [Uri? base]) {
  final at = base ?? Uri.base;
  final params = Map<String, String>.from(at.queryParameters)
    ..remove('room')
    ..remove('bought')
    ..['claim'] = code;
  return Uri(
    scheme: at.scheme,
    host: at.host,
    port: at.hasPort ? at.port : null,
    path: at.path.isEmpty ? '/' : at.path,
    queryParameters: params,
  ).toString();
}

/// The code this load is carrying, if it is carrying one.
String? claimInAddress([Uri? at]) {
  final code = (at ?? Uri.base).queryParameters['claim'];
  return code != null && RegExp(r'^[0-9a-f]{2,64}$').hasMatch(code) ? code : null;
}

/// What the service said, or a sentence about why it did not answer.
typedef Said<T> = ({T? answer, String? refusal});

/// How a handler is asked: one JSON POST. Settable, like [handlerAt]
/// and the signature verifier before it — a widget test cannot reach a
/// socket at all (the test binding answers 400 to every request), so
/// the service it stands up has to go here rather than on a port.
Future<({int status, String body})> Function(Uri url, String body) askService = http.post;

/// [what] is the part of [more] the request asks for beyond itself,
/// which the signature covers (licence.dart, [signedAsk]).
Future<({int status, String body})?> _ask(String handler, Signer signer, Map<String, Object?> more, Uri? endpoint,
    {String what = ''}) async {
  final url = endpoint ?? handlerAt(handler);
  if (url == null) return null;
  try {
    return await askService(url, jsonEncode({...signedAsk(signer, handler, what: what), ...more}))
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
}

/// What a refusal said, in its own words where it gave any.
String _why(({int status, String body})? answer, String otherwise) {
  if (answer == null) return otherwise;
  try {
    final json = jsonDecode(answer.body);
    if (json is Map && json['error'] is String) {
      final said = json['error'] as String;
      return said.isEmpty ? otherwise : '${said[0].toUpperCase()}${said.substring(1)}.';
    }
  } catch (_) {}
  return otherwise;
}

const _unreachable = 'Could not reach the service. Try again in a moment.';

/// A code for another device to arrive with.
Future<Said<Ticket>> askForCode(Signer signer, {Uri? endpoint}) async {
  final answer = await _ask('ticket', signer, const {}, endpoint);
  if (answer?.status != 200) return (answer: null, refusal: _why(answer, _unreachable));
  final ticket = Ticket.parse(jsonDecode(answer!.body));
  return ticket == null ? (answer: null, refusal: _unreachable) : (answer: ticket, refusal: null);
}

/// Arriving with a code: the licence it was claimed for, or why not.
Future<Said<Licence>> claimCode(Signer signer, String code, {Uri? endpoint, String service = serviceKey}) async {
  final answer = await _ask('claim', signer, {'ticket': code}, endpoint, what: code);
  if (answer?.status != 200) return (answer: null, refusal: _why(answer, _unreachable));
  final licence = Licence.parse(jsonDecode(answer!.body)['licence']);
  if (licence == null || !licence.holdsFor(signer.publicKey, service: service)) {
    return (answer: null, refusal: 'That code is not for this device.');
  }
  return (answer: licence, refusal: null);
}

/// The devices on this subscription; with [drop], one fewer.
Future<Said<Household>> devicesOn(Signer signer, {PublicKey? drop, Uri? endpoint}) async {
  final answer = await _ask('devices', signer, {'drop': ?drop}, endpoint, what: drop ?? '');
  if (answer?.status != 200) return (answer: null, refusal: _why(answer, _unreachable));
  final household = Household.parse(jsonDecode(answer!.body));
  return household == null ? (answer: null, refusal: _unreachable) : (answer: household, refusal: null);
}
