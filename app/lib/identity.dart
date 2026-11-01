/// Who this device is: one keypair, made the first time it is needed
/// and kept on the device, on a phone where no backup carries it
/// (secret_store.dart). The public key is the identity at a table and
/// the secret never leaves (docs/explanation/live-play.md).
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'avatar.dart';
import 'crypto/schnorr.dart';
import 'names.dart';
import 'secret_store.dart';

class Identity {
  static const _key = 'identity_secret';
  static const _nameKey = 'identity_name';

  /// Loads the device's signer, minting a key on first use. The first
  /// ask is main.dart's, which waits for it before anything else can ask,
  /// so a device with no key makes one key, not one for each of two asks
  /// that met.
  static Future<Signer> signer() async {
    final secret = await _find();
    // The same signer for the same secret: making one works out its
    // public key on the curve in Dart, a tenth of a second on the page's
    // thread and more on a slow phone, and this is asked for everywhere.
    final made = _made;
    if (made != null && made.secret == secret) return made.signer;
    final signer = signerFromSecret(secret);
    _made = (secret: secret, signer: signer);
    return signer;
  }

  static ({String secret, Signer signer})? _made;

  /// Whether [secret] is a key as it is kept: 64 hex digits.
  static bool _kept(String? secret) => secret != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(secret);

  /// The device's secret, wherever it is kept, made if it is nowhere.
  ///
  /// On a phone it belongs in the secret store, where no backup carries
  /// it (secret_store.dart). A device that kept it among the preferences
  /// before, which a backup carries, has it moved at its first start:
  ///
  /// 1. A valid key in the store is the key.
  /// 2. Otherwise a valid key in the preferences is the key. It is
  ///    written to the store, read back, and taken out of the
  ///    preferences only when the store gives back exactly what was
  ///    written. When any of that fails it stays in the preferences,
  ///    still the key, and is moved at a later start: it is not deleted
  ///    before it is safe, and no key is made while either place holds
  ///    one.
  /// 3. Otherwise a key is made, and kept the same way.
  ///
  /// A store that cannot be read is not an empty one: it may hold the
  /// key, so nothing is written over it this start. Without a store (the
  /// web, and wherever a test has not stood one) the preferences are
  /// where the key lives.
  static Future<String> _find() async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(_key);
    final store = SecretStore.current;
    if (store == null) return _kept(old) ? old! : await _keepNew(prefs);

    String? stored;
    var readable = true;
    try {
      stored = await store.read();
    } on Object catch (e) {
      readable = false;
      debugPrint('identity: the key store could not be read: $e');
    }
    if (_kept(stored)) {
      // A move that was cut short after the store had the key: finish it.
      if (old == stored) await _forget(prefs);
      return stored!;
    }
    if (_kept(old)) {
      if (readable && await _keep(store, old!)) await _forget(prefs);
      return old!;
    }
    final made = _newSecret();
    if (readable && await _keep(store, made)) return made;
    // The store would not keep it: the preferences do, as they always
    // have, and it is moved at a later start like any other.
    await prefs.setString(_key, made);
    return made;
  }

  /// Whether [store] now gives back exactly [secret]. Nothing is
  /// thrown: a key that could not be kept stays where it is.
  static Future<bool> _keep(SecretStore store, String secret) async {
    try {
      await store.write(secret);
      if (await store.read() == secret) return true;
      debugPrint('identity: the key store did not give back the key');
    } on Object catch (e) {
      debugPrint('identity: the key could not be kept in its store: $e');
    }
    return false;
  }

  /// The key out of the preferences, once it is safe in the store.
  static Future<void> _forget(SharedPreferences prefs) async {
    try {
      if (!await prefs.remove(_key)) debugPrint('identity: the key stays in the preferences');
    } on Object catch (e) {
      debugPrint('identity: the key stays in the preferences: $e');
    }
  }

  /// A key made for the preferences, where there is no store.
  static Future<String> _keepNew(SharedPreferences prefs) async {
    final made = _newSecret();
    await prefs.setString(_key, made);
    return made;
  }

  static String _newSecret() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> name() async => (await SharedPreferences.getInstance()).getString(_nameKey);

  static const _avatarKey = 'identity_avatar';

  /// The avatar chosen on this device, as it was saved; none until one
  /// is.
  static Future<Avatar> avatar() async {
    final raw = (await SharedPreferences.getInstance()).getString(_avatarKey);
    if (raw == null) return Avatar.none;
    try {
      return Avatar.fromJson(jsonDecode(raw));
    } catch (_) {
      return Avatar.none;
    }
  }

  static Future<void> setAvatar(Avatar avatar) async =>
      (await SharedPreferences.getInstance()).setString(_avatarKey, jsonEncode(avatar.toJson()));

  /// [name], when the others may see it, and nothing when not: a name
  /// the filter refuses (names.dart) is played as no name, so live play
  /// asks for another on the way in (home_page.dart, `_named`), and the
  /// profile says why. Only a name from before the filter was here, or
  /// taken from the account then, is one.
  static String playable(String? name) => name == null || nameRefused(name) ? '' : name;

  /// Keeps [name] as it may be shown ([cleanName]).
  static Future<void> setName(String name) async =>
      (await SharedPreferences.getInstance()).setString(_nameKey, cleanName(name));

  static const _agreedKey = 'identity_agreed_terms';

  /// The day this device's player agreed to the terms of use, before
  /// their name and picture first went out at a live table
  /// (home_page.dart, `_agreed`); null until they have.
  static Future<String?> agreedToTerms() async => (await SharedPreferences.getInstance()).getString(_agreedKey);

  static Future<void> agreeToTerms(DateTime at) async =>
      (await SharedPreferences.getInstance()).setString(_agreedKey, at.toUtc().toIso8601String().substring(0, 10));
}
