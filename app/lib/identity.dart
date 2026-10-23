/// Who this device is: one keypair, made the first time it is needed
/// and kept on the device. The public key is the identity at a table
/// and the secret never leaves (docs/explanation/live-play.md).
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'avatar.dart';
import 'crypto/schnorr.dart';
import 'names.dart';

class Identity {
  static const _key = 'identity_secret';
  static const _nameKey = 'identity_name';

  /// Loads the device's signer, minting a key on first use.
  static Future<Signer> signer() async {
    final prefs = await SharedPreferences.getInstance();
    var secret = prefs.getString(_key);
    if (secret == null || secret.length != 64) {
      final rng = Random.secure();
      secret = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString(_key, secret);
    }
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

  static Future<String?> name() async => (await SharedPreferences.getInstance()).getString(_nameKey);

  /// The longest name, in characters: what a watched table carries
  /// (packages/table, watch.dart), and what the service keeps with the
  /// account (service/functions/profile.mjs, a test holding them equal).
  static const longestName = 60;

  /// [name] as it is kept: trimmed, nothing in it that is not text,
  /// and no longer than [longestName].
  static String nameOf(String name) {
    final chars = name.replaceAll(RegExp('[\u0000-\u001f\u007f-\u009f]'), '').trim().runes.toList();
    return String.fromCharCodes(chars.length > longestName ? chars.sublist(0, longestName) : chars).trim();
  }

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

  static Future<void> setName(String name) async =>
      (await SharedPreferences.getInstance()).setString(_nameKey, nameOf(name));

  static const _agreedKey = 'identity_agreed_terms';

  /// The day this device's player agreed to the terms of use, before
  /// their name and picture first went out at a live table
  /// (home_page.dart, `_agreed`); null until they have.
  static Future<String?> agreedToTerms() async => (await SharedPreferences.getInstance()).getString(_agreedKey);

  static Future<void> agreeToTerms(DateTime at) async =>
      (await SharedPreferences.getInstance()).setString(_agreedKey, at.toUtc().toIso8601String().substring(0, 10));
}
