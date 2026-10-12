/// What the service vouches for, and nothing more (docs/explanation/service.md):
/// that a device belongs to an account, and that the account's
/// subscription stands — a [Licence] — and which of the account's
/// devices is the one in use now — an [Activation].
///
/// A device keeps its own key and nothing else of anybody's: no key
/// leaves a device and none is held for it. The service signs, with
/// the key every build carries the public half of, a short statement
/// that names the device's key beside its account's id. So a peer
/// that has never heard of the service's records can check, from what
/// is on the table, that the key at a seat is one of the account's
/// devices — and a seat, a name, a rating and a result are the
/// account's, whichever of its devices sat down.
library;

import 'dart:convert';

import 'signing.dart';

/// An account's id: 32 hex characters, the service's to give out.
typedef AccountId = String;

/// Whether [id] is one the service would give out.
bool validAccount(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

/// The service whose word a licence or an activation is taken on: the
/// public half of its key, 64 hex. Set once at startup — by the app from
/// the key compiled into it, by a juror from its environment — before
/// any table is read.
///
/// Empty in the simulator and in the tests that do not set one, and
/// then an account is taken as stated: nothing is asked of a seat and
/// nothing checked, the same way a fake signature passes only where
/// fake signers exist. A build compiled without a key never gets that
/// far: it is told nothing by anybody, and no live table opens on it
/// (app/lib/net/licence.dart).
String licenceService = '';

/// Whether accounts are checked here: a service is named.
bool get licencesChecked => licenceService.isNotEmpty;

/// A device's licence: its key, its account, the last day it is good
/// for, and the plan, signed by the service.
class Licence {
  const Licence({required this.key, required this.account, required this.until, required this.plan, required this.signature});

  /// What the signed text begins with, so a signature over one kind of
  /// statement can never be read as a signature over another — and
  /// the version, since the first one named no account.
  static const statement = 'oh-licence/2';

  /// The device the licence is for. A licence is a device's; an account
  /// is a person's, and carries several.
  final PublicKey key;

  /// The account the device belongs to.
  final AccountId account;

  /// The last day this licence is good for, at midnight UTC. It runs to
  /// the end of that day: see [goodAt].
  final DateTime until;

  /// What was bought. There is one plan.
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

  /// The text the service signs. A line each, and none of the five can
  /// hold a newline, so there is one way to read it.
  String get canonical => '$statement\n$key\n$account\n${dayOf(until)}\n$plan';

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
  bool holdsFor(PublicKey device, {required String service, DateTime? at}) =>
      key == device && signedBy(service) && goodAt(at ?? DateTime.now());

  Map<String, Object?> toJson() => {'key': key, 'account': account, 'until': dayOf(until), 'plan': plan, 'sig': signature};

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
    final account = json['account'];
    final until = json['until'];
    final plan = json['plan'];
    final sig = json['sig'];
    if (key is! String || account is! String || until is! String || plan is! String || sig is! String) return null;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key) || !validAccount(account)) return null;
    if (plan.contains('\n') || plan.length > 32) return null;
    final day = dayFrom(until);
    if (day == null) return null;
    return Licence(key: key, account: account, until: day, plan: plan, signature: sig);
  }

  @override
  String toString() => 'Licence(${key.substring(0, 8)}… of ${account.substring(0, 8)}… to ${dayOf(until)}, $plan)';
}

/// Whether [licence] is what a seat, a waiter, a watcher or a result
/// line keyed [key] has to show where accounts are checked: a licence
/// for that very key, signed by [licenceService] — and, given [at], not
/// run out then. A record looked at after the game has no clock to
/// hold a licence's date to, and is asked without one. True wherever
/// nothing is checked.
bool licenceFits(Licence? licence, PublicKey key, {DateTime? at}) {
  if (!licencesChecked) return true;
  if (licence == null || licence.key != key || !licence.signedBy(licenceService)) return false;
  return at == null || licence.goodAt(at);
}

/// Which of an account's devices is the one in use: the service's word,
/// given to the newest device to take the account up and renewed while
/// it is in use (docs/explanation/service.md, "One device at a time").
///
/// [epoch] counts the times the account has been taken up, so of two
/// activations for one account the later is plain without asking the
/// service: the relay holds a device to it — a socket whose device has
/// been superseded is closed, and none is opened for it — and every
/// device's presence carries it, so another device of the account
/// coming online is heard as such (presence_relay.dart).
class Activation {
  const Activation({required this.account, required this.key, required this.epoch, required this.until, required this.signature});

  static const statement = 'oh-active/1';

  final AccountId account;
  final PublicKey key;

  /// The how-manyth time the account was taken up.
  final int epoch;

  /// When it runs out, in seconds since the epoch: an hour or so, and
  /// renewed while the device is in use.
  final int until;

  final String signature;

  String get canonical => '$statement\n$account\n$key\n$epoch\n$until';

  String get digest => sha256Hex(utf8.encode(canonical));

  /// Signed by the holder of [service], on the curve itself (see
  /// [Licence.signedBy]).
  bool signedBy(PublicKey service) {
    if (service.length != 64 || signature.length != 128) return false;
    try {
      return schnorrVerifier(service, digest, signature);
    } catch (_) {
      return false;
    }
  }

  /// Not run out at [at], as a [Licence] says it with [Licence.goodAt].
  bool goodAt(DateTime at) => at.millisecondsSinceEpoch ~/ 1000 < until;

  /// For this device, this service's, and not run out at [at] (now
  /// unless given).
  bool holdsFor(PublicKey device, {required String service, DateTime? at}) =>
      key == device && signedBy(service) && goodAt(at ?? DateTime.now());

  /// Later than [other], for the same account.
  bool supersedes(Activation other) => account == other.account && epoch > other.epoch;

  Map<String, Object?> toJson() => {'account': account, 'key': key, 'epoch': epoch, 'until': until, 'sig': signature};

  static Activation? parse(Object? json) {
    if (json is String) {
      try {
        return parse(jsonDecode(json));
      } catch (_) {
        return null;
      }
    }
    if (json is! Map) return null;
    final account = json['account'];
    final key = json['key'];
    final epoch = json['epoch'];
    final until = json['until'];
    final sig = json['sig'];
    if (account is! String || key is! String || epoch is! int || until is! int || sig is! String) return null;
    if (!validAccount(account) || !RegExp(r'^[0-9a-f]{64}$').hasMatch(key) || epoch < 0) return null;
    return Activation(account: account, key: key, epoch: epoch, until: until, signature: sig);
  }

  @override
  String toString() => 'Activation(${key.substring(0, 8)}… of ${account.substring(0, 8)}… #$epoch)';
}

/// The account behind [key], from [activation], where accounts are
/// checked and it holds — or as stated where nothing is checked. Null
/// when there is none to be had, which is a key the relay admitted on
/// the service's own word: the backup jurors, who belong to no account
/// (docs/explanation/live-play.md).
AccountId? accountFrom(Activation? activation, PublicKey key, {DateTime? at}) {
  if (activation == null || activation.key != key) return null;
  if (!licencesChecked) return activation.account;
  return activation.holdsFor(key, service: licenceService, at: at) ? activation.account : null;
}
