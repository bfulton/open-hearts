/// Where a phone keeps the device's secret key: apart from the
/// settings, in a place the phone's backups leave out (identity.dart).
///
/// A phone backs up an app's preferences, to the player's Google or
/// iCloud account and to the next phone, and a key that went with them
/// would be a copy of the device somewhere else, which the privacy
/// policy says the secret half never is. So the key is not kept among
/// the preferences on a phone. Android keeps it in a preferences file
/// of its own, which `res/xml/data_extraction_rules.xml` and
/// `res/xml/backup_rules.xml` leave out of both kinds of backup and of a
/// transfer to a new phone; the iPhone keeps it in a file marked as not
/// to be backed up (secret_store_io.dart). Both are deleted with the
/// app, as the preferences were, so deleting the app still removes the
/// key. The Keychain would not: its items outlive the app.
///
/// A phone restored from a backup or moved to a new phone comes back
/// without its key, as a new player, and gets its account back with a
/// backup code, a sign-in or Restore purchases. Everything else the
/// backup holds, the settings among it, comes back.
///
/// The web keeps no store: its key is among the page's preferences, in
/// the browser's storage (web/carry.js brings it along from the app's
/// old address).
library;

import 'secret_store_io.dart' if (dart.library.js_interop) 'secret_store_web.dart' as platform;

/// The Android preferences file the key is kept in, `identity.xml` in
/// the app's `shared_prefs`, and the name that
/// `res/xml/data_extraction_rules.xml` and `res/xml/backup_rules.xml`
/// leave out of backups (a test holds the three to one another).
const identityFile = 'identity';

/// A place to keep the device's secret key, apart from the preferences.
abstract class SecretStore {
  /// The one this app keeps its key in: the phone's, or none on the
  /// web and wherever a test has not stood one. A global, as
  /// StoreReview.current is, and settable, so a test can stand its own
  /// behind it.
  static SecretStore? current = platform.secretStoreHere();

  /// The secret as it was kept, whatever it is; null when nothing was
  /// kept. Throws when the store cannot be read, which is not the same
  /// as nothing being in it.
  Future<String?> read();

  /// Keeps [secret], over any other. Throws when it cannot be kept
  /// where no backup carries it.
  Future<void> write(String secret);

  /// Forgets the secret. Nothing kept is no failure.
  Future<void> delete();
}
