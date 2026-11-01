/// The phones' stores for the device's secret key (secret_store.dart).
library;

import 'dart:io' show File, FileSystemException, Platform;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'secret_store.dart';

SecretStore? secretStoreHere() => Platform.isAndroid
    ? AndroidSecretStore()
    : Platform.isIOS
        ? IosSecretStore()
        : null;

/// Android: a preferences file of its own, [identityFile], which the
/// backup and transfer rules leave out (res/xml/data_extraction_rules.xml
/// for Android 12 and later, res/xml/backup_rules.xml for 11 and
/// earlier). The plugin keeps a file of that name only with the
/// SharedPreferences backend; the DataStore it uses by default has no
/// file name, and would keep the key in a file no rule names.
class AndroidSecretStore implements SecretStore {
  AndroidSecretStore({this.file = identityFile});

  /// The file's name, without `.xml`. Only a test asks for another.
  final String file;

  static const _key = 'identity_secret';

  /// Made when first used, not when the store is: a store that cannot
  /// be made then fails where the failure is handled (identity.dart).
  late final SharedPreferencesAsync _prefs = SharedPreferencesAsync(
    options: SharedPreferencesAsyncAndroidOptions(
      backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
      originalSharedPreferencesOptions: AndroidSharedPreferencesStoreOptions(fileName: file),
    ),
  );

  @override
  Future<String?> read() => _prefs.getString(_key);

  @override
  Future<void> write(String secret) => _prefs.setString(_key, secret);

  @override
  Future<void> delete() => _prefs.remove(_key);
}

/// What the iPhone's native side answers to, in ios/Runner/AppDelegate.swift:
/// `directory`, the path of the app's Application Support folder, made
/// if it is not there; and `excludeFromBackup`, given a path, marks the
/// file there as not to be backed up and says whether the file itself
/// then says so.
const identityChannel = 'game.openhearts/identity';

/// The iPhone: a file in Application Support marked as not to be backed
/// up (NSURLIsExcludedFromBackupKey), which neither an iCloud backup nor
/// a computer's carries, and which goes with the app when it is deleted.
/// The Keychain does not: its items outlive the app.
class IosSecretStore implements SecretStore {
  IosSecretStore({this.file = 'identity_secret'});

  /// The file's name. Only a test asks for another.
  final String file;

  static const _channel = MethodChannel(identityChannel);

  Future<File> _where() async {
    final directory = await _channel.invokeMethod<String>('directory');
    if (directory == null) throw StateError('the app\'s Application Support folder has no path');
    return File('$directory/$file');
  }

  @override
  Future<String?> read() async {
    final where = await _where();
    if (!await where.exists()) return null;
    return where.readAsString();
  }

  /// The file is made empty and marked first, and the secret goes into
  /// it only once it says it is not backed up, so that no copy of the
  /// secret ever sits in a file a backup could carry. It is written in
  /// place, not by renaming another file over it, which would leave a
  /// file that is not marked.
  @override
  Future<void> write(String secret) async {
    final where = await _where();
    final made = !await where.exists();
    if (made) await where.create();
    try {
      if (await _channel.invokeMethod<bool>('excludeFromBackup', where.path) != true) {
        throw StateError('the file is not marked as not to be backed up');
      }
      await where.writeAsString(secret, flush: true);
    } catch (_) {
      if (made) {
        try {
          await where.delete();
        } on FileSystemException {
          // Empty, and the failure that matters is the one rethrown.
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> delete() async {
    final where = await _where();
    if (await where.exists()) await where.delete();
  }
}
