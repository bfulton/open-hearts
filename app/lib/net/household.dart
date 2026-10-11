/// A subscription buys an account, and an account is a person's, not a
/// device's (docs/06-service.md).
///
/// So a second device has to be able to come into the same account. The way
/// that costs nothing to type: the subscribed device shows a code, and
/// the other device arrives carrying it. The code goes in a link and
/// the link goes in a QR, so the phone's own camera can be the scanner;
/// Activate subscription scans it too, or takes it typed, and takes a
/// backup code from the email (activate_page.dart).
///
/// A code is spent the first time it is used, so a photograph of
/// somebody's screen an hour later is worth nothing. Five devices to a
/// subscription, and any of them can drop another: unbounded sharing is
/// a subscription shared with the internet, and five is a household.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:table/table.dart';

import '../l10n/l10n.dart';
import 'address.dart';
import 'licence.dart';
import 'http.dart' as http;
import 'remote_config.dart' show waits;

/// A device of the account, as the service lists them.
class Device {
  const Device({required this.key, this.boundAt, this.inUse = false});

  final PublicKey key;
  final String? boundAt;

  /// Whether it is the account's device in use now (net/in_use.dart).
  final bool inUse;

  /// Enough of the key to tell two devices apart at a glance, which is
  /// all anyone can do: a device has no name here and is not asked for
  /// one.
  String get shortened => key.substring(0, 6);
}

/// The devices on this subscription, and how many it carries.
class Household {
  const Household({required this.devices, required this.most, this.signIn, this.toldSignIn = false});

  final List<Device> devices;
  final int most;

  /// The sign-in the account is linked to (`apple`, `google`), or null
  /// for none — as the service has it, which [toldSignIn] says it did: a
  /// service from before it said so leaves the device's own note.
  final String? signIn;
  final bool toldSignIn;

  bool get full => devices.length >= most;

  static Household? parse(Object? json) {
    if (json is! Map) return null;
    final list = json['devices'];
    final most = json['most'];
    if (list is! List || most is! int) return null;
    return Household(
      devices: [
        for (final d in list)
          if (d is Map && d['key'] is String) Device(key: d['key'] as String, boundAt: d['bound_at'] as String?, inUse: d['active'] == true),
      ],
      most: most,
      signIn: json['signIn'] is String ? json['signIn'] as String : null,
      toldSignIn: json.containsKey('signIn'),
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

/// The link a code travels in: the app's own address — the front door,
/// not the page showing it (router.dart) — carrying the code and
/// nothing that belonged to this device's session.
String claimLink(String code, [Uri? base]) {
  final at = base ?? Uri.base;
  // The app's own address, which on a phone is not the page's (it has
  // none): address_io.dart.
  final root = base ?? appBase();
  final params = Map<String, String>.from(at.queryParameters)
    ..remove('room')
    ..remove('bought')
    ..['claim'] = code;
  return Uri(
    scheme: root.scheme,
    host: root.host,
    port: root.hasPort ? root.port : null,
    path: root.path.isEmpty ? '/' : root.path,
    queryParameters: params,
  ).toString();
}

/// The code this load is carrying, if it is carrying one.
String? claimInAddress([Uri? at]) {
  final code = (at ?? Uri.base).queryParameters['claim'];
  return code != null && RegExp(r'^[0-9a-f]{2,64}$').hasMatch(code) ? code : null;
}

/// What a person typed, pasted or scanned, as a code the service takes:
/// a link carrying one, a code off another device's screen (32 hex), or
/// a backup code — or null when it is none of them. Read generously, as
/// the service reads it (worker.mjs, `backupCodeOf`).
String? codeIn(String text) {
  final t = text.trim();
  if (t.isEmpty || t.length > 2048) return null;
  final link = Uri.tryParse(t);
  if (link != null && link.hasScheme && link.queryParameters.containsKey('claim')) return claimInAddress(link);
  final compact = t.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
  if (RegExp(r'^[0-9a-f]{32}$').hasMatch(compact)) return compact;
  return backupCodeOf(t);
}

/// [text] as a backup code, XXXX-XXXX-XXXX-XXXX, or null: Crockford's
/// base32, case and spaces and dashes ignored, an O, I or L taken as
/// the 0 or 1 it looks like.
String? backupCodeOf(String text) {
  if (text.length > 64) return null;
  final plain = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
  if (!RegExp(r'^[0-9A-HJKMNP-TV-Z]{16}$').hasMatch(plain)) return null;
  return [for (var i = 0; i < 16; i += 4) plain.substring(i, i + 4)].join('-');
}

/// [text] as the code field shows it: a backup code in its groups of
/// four, XXXX-XXXX-XXXX-XXXX, as far as it has been typed; anything else
/// — a device's thirty-two-character code, a link — as it is.
String codeAsTyped(String text) {
  if (!_codeSoFar(text)) return text;
  final plain = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return [for (var i = 0; i < plain.length; i += 4) plain.substring(i, i + 4 > plain.length ? plain.length : i + 4)].join('-');
}

/// Whether [text] could be a backup code typed so far: up to sixteen
/// letters and digits, with spaces and dashes anywhere.
bool _codeSoFar(String text) {
  final plain = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return plain.isNotEmpty && plain.length <= 16 && RegExp(r'^[0-9A-Z]+$').hasMatch(plain);
}

/// The code field's dashes, put in as a backup code is typed or pasted,
/// with the cursor kept after the same characters it was after. Deleting
/// a dash deletes the character before it, so backspace never sticks.
class CodeFormatter extends TextInputFormatter {
  const CodeFormatter();

  static String _plain(String s) => s.replaceAll(RegExp(r'[\s-]'), '');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue next) {
    var text = next.text;
    var cursor = next.selection.isValid ? next.selection.extentOffset : text.length;
    // A dash and nothing else taken out: take the character before it too.
    if (_codeSoFar(old.text) && text.length < old.text.length && _plain(text) == _plain(old.text) && cursor > 0) {
      final before = _plain(text.substring(0, cursor));
      final kept = before.isEmpty ? '' : before.substring(0, before.length - 1);
      text = kept + _plain(text.substring(cursor));
      cursor = kept.length;
    } else {
      cursor = _plain(text.substring(0, cursor.clamp(0, text.length))).length;
    }
    final shown = codeAsTyped(text);
    if (shown == text && text == next.text) return next;
    // The cursor after as many of the code's own characters as before.
    var at = 0;
    for (var seen = 0; at < shown.length && seen < cursor; at++) {
      if (shown[at] != '-' && shown[at].trim().isNotEmpty) seen++;
    }
    return TextEditingValue(text: shown, selection: TextSelection.collapsed(offset: at));
  }
}

/// A subscription's backup codes, as a device on it is shown them.
class BackupCodes {
  const BackupCodes({required this.codes, this.madeAt, this.emailed = false, this.unsent});

  final List<({String code, bool used})> codes;
  final DateTime? madeAt;

  /// Whether asking to send them sent them to the payer's email.
  final bool emailed;

  /// Why they were not sent, when they were asked to be: `no address`
  /// (a subscription bought in a store), or the service's trouble.
  final String? unsent;

  Iterable<String> get unused => codes.where((c) => !c.used).map((c) => c.code);

  static BackupCodes? parse(Object? json) {
    if (json is! Map || json['codes'] is! List) return null;
    return BackupCodes(
      codes: [
        for (final c in json['codes'] as List)
          if (c is Map && c['code'] is String) (code: c['code'] as String, used: c['used'] == true),
      ],
      madeAt: DateTime.tryParse(json['made_at'] as String? ?? ''),
      emailed: json['emailed'] == true,
      unsent: json['unsent'] as String?,
    );
  }
}

/// This subscription's backup codes; with [replace], five new ones in
/// place of them; with [send], the ones still good emailed to the
/// payer, and [BackupCodes.emailed] or [BackupCodes.unsent] says how
/// that went.
Future<Said<BackupCodes>> backupCodes(Signer signer, {bool replace = false, bool send = false, Uri? endpoint}) async {
  final answer = await askHandler('backups', signer, {if (replace) 'rotate': true, if (send && !replace) 'send': true}, endpoint,
      what: replace ? 'rotate' : (send ? 'send' : ''));
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  final codes = BackupCodes.parse(jsonDecode(answer!.body));
  return codes == null ? (answer: null, refusal: _unreachable) : (answer: codes, refusal: null);
}

/// What the service said, or why it did not answer.
typedef Said<T> = ({T? answer, Refused? refusal});

/// Why the service did not do what it was asked: one of the reasons
/// the screen has words for, or else what the service said in its own.
class Refused {
  const Refused(this.reason, [this.said]);

  /// What the service answered with an error it named, read off its
  /// answer; one the app has no words for keeps the service's own.
  factory Refused.from(String said) => Refused(_named[said] ?? 'other', said);

  /// `unreachable`, `notForThisDevice`, one of the store's own
  /// (store_buying.dart), one of the service's own named in [_named],
  /// or `other`.
  final String reason;

  /// The service's own words, in English.
  final String? said;

  /// The service's errors the app has words for (worker.mjs).
  static const _named = {
    'no subscription': 'noSubscription',
    'five devices already': 'fiveDevices',
    'not a code': 'notACode',
    'no such code': 'noSuchCode',
    'that code has been used': 'codeUsed',
    'that code has run out': 'codeRunOut',
    'not a device on this subscription': 'notADevice',
    'this device is on another subscription: drop it there first': 'onAnotherSubscription',
    "this device's clock is out by more than five minutes": 'clockOff',
    // A sign-in brought to the service (sign_in.dart).
    'that sign-in does not check out': 'signInRefused',
    'that sign-in is linked to another account': 'accountElsewhere',
    'that sign-in is not linked to an account': 'accountNowhere',
    'this account is linked to another sign-in': 'otherSignIn',
    'service not configured: OH_ID_HMAC': 'signInNotSetUp',
    // A store's purchase brought to the service (store_buying.dart).
    'not a store': 'notAStore',
    'no proof': 'noProof',
    'not from the store': 'notFromStore',
    'not paid': 'notPaid',
    'the store is not answering': 'storeNotAnswering',
    'the store is not set up yet': 'storeNotSetUp',
  };

  /// The refusal as the player is told it.
  String say([AppLocalizations? words]) {
    final say = words ?? english;
    return switch (reason) {
      'unreachable' => say.serviceUnreachable,
      'notForThisDevice' => say.codeNotForThisDevice,
      'licenceNotForThisDevice' => say.licenceNotForThisDevice,
      'storeFailed' => say.storeFailed,
      'nothingToRestore' => say.nothingToRestore,
      'other' => '${said![0].toUpperCase()}${said!.substring(1)}.',
      _ => say.serviceRefusal(reason),
    };
  }

  @override
  bool operator ==(Object other) => other is Refused && other.reason == reason && other.said == said;

  @override
  int get hashCode => Object.hash(reason, said);

  @override
  String toString() => say();
}

/// How a handler is asked: one JSON POST. Settable, like [handlerAt]
/// and the signature verifier before it — a widget test cannot reach a
/// socket at all (the test binding answers 400 to every request), so
/// the service it stands up has to go here rather than on a port.
Future<({int status, String body})> Function(Uri url, String body) askService = http.post;

/// [what] is the part of [more] the request asks for beyond itself,
/// which the signature covers (licence.dart, [signedAsk]). Null when
/// nobody answered in [timeout] — a household's wait, unless said.
Future<({int status, String body})?> askHandler(String handler, Signer signer, Map<String, Object?> more, Uri? endpoint,
    {String what = '', Duration? timeout}) async {
  final url = endpoint ?? handlerAt(handler);
  if (url == null) return null;
  try {
    return await askService(url, jsonEncode({...signedAsk(signer, handler, what: what), ...more}))
        .timeout(timeout ?? waits.household);
  } catch (_) {
    return null;
  }
}

/// What a refusal said, in its own words where it gave any.
Refused refusalOf(({int status, String body})? answer) {
  if (answer == null) return _unreachable;
  try {
    final json = jsonDecode(answer.body);
    if (json is Map && json['error'] is String) {
      final said = json['error'] as String;
      return said.isEmpty ? _unreachable : Refused.from(said);
    }
  } catch (_) {}
  return _unreachable;
}

const _unreachable = Refused('unreachable');

/// A code for another device to arrive with.
Future<Said<Ticket>> askForCode(Signer signer, {Uri? endpoint}) async {
  final answer = await askHandler('ticket', signer, const {}, endpoint);
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  final ticket = Ticket.parse(jsonDecode(answer!.body));
  return ticket == null ? (answer: null, refusal: _unreachable) : (answer: ticket, refusal: null);
}

/// Arriving with a code: the licence it was claimed for, or why not.
Future<Said<Licence>> claimCode(Signer signer, String code, {Uri? endpoint, String service = serviceKey}) async {
  final answer = await askHandler('claim', signer, {'ticket': code}, endpoint, what: code);
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  final licence = Licence.parse(jsonDecode(answer!.body)['licence']);
  if (licence == null || !licence.holdsFor(signer.publicKey, service: service)) {
    return (answer: null, refusal: const Refused('notForThisDevice'));
  }
  return (answer: licence, refusal: null);
}

/// The devices on this subscription; with [drop], one fewer.
Future<Said<Household>> devicesOn(Signer signer, {PublicKey? drop, Uri? endpoint}) async {
  final answer = await askHandler('devices', signer, {'drop': ?drop}, endpoint, what: drop ?? '');
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  final household = Household.parse(jsonDecode(answer!.body));
  return household == null ? (answer: null, refusal: _unreachable) : (answer: household, refusal: null);
}
