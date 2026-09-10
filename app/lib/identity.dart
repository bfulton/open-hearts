/// Who this device is: one keypair, made the first time it is needed
/// and kept on the device. No account, no email — the public key is
/// the identity and the secret never leaves (docs/04-live-play.md).
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'crypto/schnorr.dart';

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
    return signerFromSecret(secret);
  }

  static Future<String?> name() async => (await SharedPreferences.getInstance()).getString(_nameKey);

  static Future<void> setName(String name) async =>
      (await SharedPreferences.getInstance()).setString(_nameKey, name.trim());
}
