/// The profile is the account's, not the device's (docs/06-service.md).
///
/// The name the others see, the icon and colour or picture they see it
/// on: an account is a person, and a person is the same on every device
/// they play on. So a subscribed device keeps its profile with the
/// service as well as on itself. It is still kept here first — the
/// front door draws it before anything is asked, and a device on a train
/// has a name — and the service's copy is the one every device of the
/// account comes round to:
///
/// - **Read** when the app starts, behind the licence, and each time this
///   device becomes the one in use: a profile newer than the one this
///   device last had is taken, over whatever is here.
/// - **Written** when the profile page is left changed: kept here at
///   once and sent. A device that cannot reach the service, or is not
///   the one in use, keeps it marked as unsent and sends it the next
///   time it can. The service numbers each write, and the last one
///   sent is the profile.
/// - **Joined**: a device brought into an account — a code, a backup
///   code, a sign-in, a purchase restored — takes the account's profile
///   in place of its own; an account with none yet (one from before
///   profiles were kept) takes this device's.
///
/// A device with no subscription has only its own, as before; one that
/// leaves an account, or is dropped from one, keeps the last it had.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../avatar.dart';
import '../entitlement.dart';
import '../identity.dart';
import 'household.dart' show askHandler;
import 'in_use.dart';

class AccountProfile extends ChangeNotifier {
  /// The one this app keeps. A global, like the entitlement it follows.
  static AccountProfile current = AccountProfile();

  /// The account this device's profile was last the same as the
  /// service's for, and that copy's version.
  static const _syncedAccount = 'profile_account';
  static const _syncedVersion = 'profile_version';

  /// The account a change made here has yet to reach, while it has not.
  static const _unsent = 'profile_unsent';

  /// Changes made here since this app started, so a write that comes
  /// back after another change does not mark that one sent.
  int _changes = 0;

  Future<void>? _running;
  bool _again = false;

  String? _account;
  Use? _standing;
  Entitlement? _entitlement;
  InUse? _inUse;

  /// Follows the licence and the device's standing with its account
  /// from here on: a device brought into another account takes that
  /// account's profile, and one that becomes the device in use reads
  /// the account's — or sends what it could not before.
  void watch() {
    _entitlement?.removeListener(_licensed);
    _inUse?.removeListener(_used);
    _entitlement = Entitlement.current..addListener(_licensed);
    _inUse = InUse.current..addListener(_used);
    _account = Entitlement.current.licence?.account;
    _standing = InUse.current.standing;
  }

  void _licensed() {
    final account = Entitlement.current.licence?.account;
    final joined = account != null && account != _account;
    _account = account;
    if (joined) unawaited(sync());
  }

  void _used() {
    final standing = InUse.current.standing;
    final became = standing == Use.here && _standing != Use.here;
    _standing = standing;
    if (became) unawaited(sync());
  }

  /// A change made on the profile page: kept on this device, and marked
  /// to go to the account's, which [sync] sends.
  Future<void> keep(String name, Avatar avatar) async {
    await Identity.setName(name);
    await Identity.setAvatar(avatar);
    final account = Entitlement.current.licence?.account;
    if (account == null) return;
    _changes++;
    await (await SharedPreferences.getInstance()).setString(_unsent, account);
  }

  /// Sends a change that has not gone yet, if there is one: for the
  /// moments the app comes back to, when the network may have too.
  Future<void> retry() async {
    final account = Entitlement.current.licence?.account;
    if (account != null && (await SharedPreferences.getInstance()).getString(_unsent) == account) await sync();
  }

  /// This device's profile and its account's brought together: a change
  /// made here sent, or else the account's read and taken if it is
  /// newer. One at a time; asked again while one runs, it runs once more
  /// after. Never throws, and a service that does not answer changes
  /// nothing.
  Future<void> sync() async {
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = _running = () async {
      do {
        _again = false;
        try {
          await _once();
        } catch (_) {
          // Asked again at the next start, or the next time this device
          // is the one in use.
        }
      } while (_again);
    }();
    try {
      await run;
    } finally {
      _running = null;
    }
  }

  Future<void> _once() async {
    final account = Entitlement.current.licence?.account;
    if (account == null) return;
    final prefs = await SharedPreferences.getInstance();
    final unsent = prefs.getString(_unsent);
    // A change made here for this account goes, and is the profile: the
    // last write is.
    if (unsent == account) return _send(account);
    // One made for another account stays with that account's past.
    if (unsent != null) await prefs.remove(_unsent);
    final signer = await Identity.signer();
    final answer = await askHandler('profile', signer, const {}, null);
    if (answer == null || answer.status != 200) return;
    final json = jsonDecode(answer.body);
    if (json is! Map) return;
    final profile = json['profile'];
    final version = json['version'];
    if (profile is Map && version is int) {
      // A change made here while the account's was on its way wins: it
      // is the later, and goes on the next round.
      if (prefs.getString(_unsent) == account) return;
      final had = prefs.getString(_syncedAccount) == account ? prefs.getInt(_syncedVersion) ?? 0 : -1;
      if (version > had) await _take(profile, account, version);
      return;
    }
    if (profile == null) {
      // The account has none yet: this device's becomes it — the first
      // device of an account from before profiles were kept, or the one
      // that brought it its first name.
      final name = await Identity.name() ?? '';
      if (name.isEmpty && (await Identity.avatar()).isDefault) return;
      await _send(account);
    }
  }

  /// This device's profile, sent as the account's.
  Future<void> _send(String account) async {
    final changes = _changes;
    final name = Identity.nameOf(await Identity.name() ?? '');
    final text = jsonEncode({'name': name, ...(await Identity.avatar()).toJson()});
    final signer = await Identity.signer();
    // The text is what is signed: nobody else's request writes it.
    final answer = await askHandler('profile', signer, {'profile': text}, null, what: text);
    // Unanswered, superseded, or over the hour's allowance: still
    // unsent, and tried again.
    if (answer == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (answer.status == 400 && _malformed.contains(_errorOf(answer.body))) {
      // A profile the service will never take is not sent again and
      // again; it stays this device's own.
      if (_changes == changes) await prefs.remove(_unsent);
      return;
    }
    if (answer.status != 200) return;
    final version = (jsonDecode(answer.body) as Map)['version'];
    if (version is! int) return;
    await prefs.setString(_syncedAccount, account);
    await prefs.setInt(_syncedVersion, version);
    if (_changes == changes && prefs.getString(_unsent) == account) await prefs.remove(_unsent);
  }

  /// What the service says of a profile it will never take
  /// (worker.mjs, `profileOf`). Any other refusal — a service part way
  /// through a deploy among them — is asked again.
  static const _malformed = {'not a profile', 'not a name', 'not one of the icons', 'not one of the colours', 'not a picture'};

  static String? _errorOf(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map && json['error'] is String ? json['error'] as String : null;
    } catch (_) {
      return null;
    }
  }

  /// The account's profile, over this device's.
  Future<void> _take(Map<Object?, Object?> profile, String account, int version) async {
    final name = profile['name'];
    await Identity.setName(name is String ? name : '');
    await Identity.setAvatar(Avatar.fromJson(profile));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_syncedAccount, account);
    await prefs.setInt(_syncedVersion, version);
    notifyListeners();
  }

  /// For a test: as new.
  @visibleForTesting
  void reset() {
    _entitlement?.removeListener(_licensed);
    _inUse?.removeListener(_used);
    _entitlement = null;
    _inUse = null;
    _account = null;
    _standing = null;
    _changes = 0;
    _again = false;
    _running = null;
  }
}
