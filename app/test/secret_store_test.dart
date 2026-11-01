/// The phones' own stores for the device's secret key
/// (secret_store_io.dart): where each keeps it, and that neither keeps
/// it anywhere a backup reaches. What a device does with a store is in
/// identity_test.dart, and what Android's backup rules leave out in
/// identity_backup_test.dart.
///
/// Neither phone is here. Android's preferences plugin is stood in for
/// by one that files each write as the plugin does (a preferences file
/// by name with the SharedPreferences backend, DataStore's own file
/// without it), and the iPhone's native side by one that answers its two
/// calls as ios/Runner/AppDelegate.swift does. The iPhone's real one is
/// checked on a simulator by integration_test/native_libs_test.dart in
/// CI (.github/workflows/ios.yml).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/secret_store.dart';
import 'package:open_hearts/secret_store_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Android's preferences plugin, as far as the store asks it: the file a
/// call lands in, by the options it carries (shared_preferences_android,
/// SharedPreferencesAsyncAndroid and SharedPreferencesBackend). A file by
/// name is the SharedPreferences backend's; the DataStore backend, which
/// is what the options say by default, has one file of its own and no
/// name to give it.
base class _Phone extends SharedPreferencesAsyncPlatform {
  /// What each file holds, by its name.
  final files = <String, Map<String, String>>{};

  String _file(SharedPreferencesOptions options) {
    if (options is SharedPreferencesAsyncAndroidOptions) {
      if (options.backend == SharedPreferencesAndroidBackendLibrary.DataStore) return 'datastore/FlutterSharedPreferences';
      return options.originalSharedPreferencesOptions?.fileName ?? 'default';
    }
    return 'default';
  }

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) async => files[_file(options)]?[key];

  @override
  Future<void> setString(String key, String value, SharedPreferencesOptions options) async =>
      (files[_file(options)] ??= {})[key] = value;

  @override
  Future<void> clear(ClearPreferencesParameters parameters, SharedPreferencesOptions options) async {
    final allowed = parameters.filter.allowList;
    final file = files[_file(options)];
    if (file == null) return;
    if (allowed == null) {
      file.clear();
    } else {
      file.removeWhere((key, _) => allowed.contains(key));
    }
    if (file.isEmpty) files.remove(_file(options));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('the store asked for ${invocation.memberName}');
}

/// The iPhone's native side, as AppDelegate.swift answers it.
class _Native {
  _Native(this.folder);

  final Directory folder;

  /// What `excludeFromBackup` says: true, false, or an error to throw.
  Object answer = true;

  /// What each file held at the moment it was marked.
  final held = <String>[];

  Future<Object?> call(MethodCall call) async {
    switch (call.method) {
      case 'directory':
        return folder.path;
      case 'excludeFromBackup':
        final file = File(call.arguments as String);
        // The native side marks a file that is there, and no other.
        if (!file.existsSync()) throw PlatformException(code: 'excludeFromBackup', message: 'no such file');
        held.add(file.readAsStringSync());
        final said = answer;
        if (said is PlatformException) throw said;
        return said;
    }
    throw MissingPluginException();
  }
}

final _secret = 'ab${'cd' * 31}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a test run has no store of its own: the host is neither phone', () {
    expect(secretStoreHere(), isNull);
    expect(SecretStore.current, isNull);
  });

  group('Android', () {
    late _Phone phone;

    setUp(() {
      phone = _Phone();
      SharedPreferencesAsyncPlatform.instance = phone;
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() => SharedPreferencesAsyncPlatform.instance = null);

    test('the key is kept in a preferences file of its own, by name, with the backend that has one', () async {
      final store = AndroidSecretStore();
      expect(await store.read(), isNull);
      await store.write(_secret);
      expect(phone.files, {
        identityFile: {'identity_secret': _secret},
      }, reason: 'in the one file the backup rules leave out, and in no other');
      expect(await store.read(), _secret);
      expect(await AndroidSecretStore().read(), _secret, reason: 'by a store made afterwards');
    });

    test('and none of it among the preferences the rest of the app keeps', () async {
      await AndroidSecretStore().write(_secret);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    test('writing again replaces it, and deleting forgets it', () async {
      final store = AndroidSecretStore();
      await store.write(_secret);
      await store.write('ef${'01' * 31}');
      expect(await store.read(), 'ef${'01' * 31}');
      await store.delete();
      expect(await store.read(), isNull);
      expect(phone.files, isEmpty, reason: 'nothing of it is left to be backed up');
      await store.delete();
    });

    test('a store for another file keeps to it', () async {
      await AndroidSecretStore(file: 'identity_test').write(_secret);
      expect(phone.files.keys, {'identity_test'});
    });
  });

  group('iPhone', () {
    late Directory folder;
    late _Native native;
    late IosSecretStore store;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('open_hearts_secret_');
      native = _Native(folder);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(identityChannel), native.call);
      store = IosSecretStore();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel(identityChannel), null);
      folder.deleteSync(recursive: true);
    });

    test('the key is a file in the app\'s folder, marked as not to be backed up before it holds the key', () async {
      expect(await store.read(), isNull);
      await store.write(_secret);
      expect(File('${folder.path}/identity_secret').readAsStringSync(), _secret);
      expect(native.held, [''], reason: 'the file was empty when it was marked, so no unmarked file ever held the key');
      expect(await store.read(), _secret);
      expect(await IosSecretStore().read(), _secret, reason: 'by a store made afterwards');
    });

    test('writing again marks the file again, in the file that is there', () async {
      await store.write(_secret);
      await store.write('ef${'01' * 31}');
      expect(native.held, ['', _secret]);
      expect(await store.read(), 'ef${'01' * 31}');
      expect(folder.listSync().map((e) => e.uri.pathSegments.last), ['identity_secret'], reason: 'one file, not a new one beside it');
    });

    test('a file that does not say it is marked is not given the key, and is not left', () async {
      native.answer = false;
      await expectLater(store.write(_secret), throwsStateError);
      expect(folder.listSync(), isEmpty);
      expect(await store.read(), isNull);
    });

    test('a native side that fails is not given the key either', () async {
      native.answer = PlatformException(code: 'excludeFromBackup', message: 'no');
      await expectLater(store.write(_secret), throwsA(isA<PlatformException>()));
      expect(folder.listSync(), isEmpty);
    });

    test('a key that is there is not lost to a write that could not mark its file', () async {
      await store.write(_secret);
      native.answer = false;
      await expectLater(store.write('ef${'01' * 31}'), throwsStateError);
      expect(await store.read(), _secret);
    });

    test('a native side that is not there is a store that cannot be used, not one that is empty', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel(identityChannel), null);
      await expectLater(store.read(), throwsA(isA<MissingPluginException>()));
      await expectLater(store.write(_secret), throwsA(isA<MissingPluginException>()));
    });

    test('deleting forgets the key, and forgetting nothing is no failure', () async {
      await store.delete();
      await store.write(_secret);
      await store.delete();
      expect(await store.read(), isNull);
      expect(folder.listSync(), isEmpty);
    });

    test('a store for another file keeps to it', () async {
      await IosSecretStore(file: 'identity_secret_test').write(_secret);
      expect(File('${folder.path}/identity_secret_test').existsSync(), isTrue);
      expect(File('${folder.path}/identity_secret').existsSync(), isFalse);
    });
  });
}
