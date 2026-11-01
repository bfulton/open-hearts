/// Where the device's secret key is kept (identity.dart,
/// secret_store.dart): on a phone, in a store no backup carries, and
/// moved there from the preferences by a device that kept it among them
/// before; among the preferences where there is no store, as the web has
/// none.
///
/// The store here is a stand-in with failures to order. What each phone's
/// own store does is proved in secret_store_test.dart, and what the
/// phone's backups leave out in identity_backup_test.dart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/crypto/schnorr.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/secret_store.dart';
import 'package:open_hearts/start_afresh.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show PublicKey;

/// A key some earlier build made and kept among the preferences, and
/// another.
final _older = '4a${'1b' * 31}';
final _other = '7c${'2d' * 31}';

/// A secret store that keeps its secret in memory, and fails as told.
class _Store implements SecretStore {
  String? kept;

  /// Throws on a write / on a read / on a delete.
  bool failsToWrite = false;
  bool failsToRead = false;
  bool failsToDelete = false;

  /// Takes a write and keeps nothing / keeps something else.
  bool forgets = false;
  bool garbles = false;

  /// Reads that throw only after a write: the read-back.
  bool failsToReadBack = false;

  int writes = 0;
  int reads = 0;
  int deletes = 0;
  bool _written = false;

  @override
  Future<String?> read() async {
    reads++;
    if (failsToRead || (failsToReadBack && _written)) throw StateError('cannot read');
    return kept;
  }

  @override
  Future<void> write(String secret) async {
    writes++;
    if (failsToWrite) throw StateError('cannot write');
    _written = true;
    if (forgets) return;
    kept = garbles ? secret.replaceRange(0, 1, secret.startsWith('f') ? '0' : 'f') : secret;
  }

  @override
  Future<void> delete() async {
    deletes++;
    if (failsToDelete) throw StateError('cannot delete');
    kept = null;
  }
}

final _hex = RegExp(r'^[0-9a-f]{64}$');

PublicKey _publicOf(String secret) => signerFromSecret(secret).publicKey;

Future<String?> _inPreferences() async => (await SharedPreferences.getInstance()).getString('identity_secret');

void main() {
  tearDown(() => SecretStore.current = null);

  group('on a phone', () {
    late _Store store;

    setUp(() {
      store = _Store();
      SecretStore.current = store;
      SharedPreferences.setMockInitialValues({});
    });

    test('a fresh device makes its key into the store, and none among the preferences', () async {
      final me = await Identity.signer();
      expect(store.kept, matches(_hex));
      expect(me.publicKey, _publicOf(store.kept!), reason: 'the key it signs with is the one kept');
      expect(await _inPreferences(), isNull, reason: 'which a backup would carry');
      expect((await Identity.signer()).publicKey, me.publicKey, reason: 'and is the same at the next ask');
      expect(store.writes, 1);
    });

    test('an upgraded device is the same player after the move, and the preference is gone', () async {
      SharedPreferences.setMockInitialValues({'identity_secret': _older, 'identity_name': 'Ada', 'game_target': 100});
      final me = await Identity.signer();
      expect(me.publicKey, _publicOf(_older), reason: 'the key it had');
      expect(store.kept, _older, reason: 'now in the store');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('identity_secret'), isFalse, reason: 'and out of the preferences');
      expect(prefs.getKeys(), {'identity_name', 'game_target'}, reason: 'the rest of the preferences are not touched');
      expect((await Identity.signer()).publicKey, me.publicKey, reason: 'and it is that key at the next start');
    });

    test('a device that has moved reads the store, and writes nothing', () async {
      store.kept = _older;
      final me = await Identity.signer();
      expect(me.publicKey, _publicOf(_older));
      expect(store.writes, 0);
      expect(await _inPreferences(), isNull);
    });

    test('a key that cannot be written to the store stays in the preferences, and the player stays the same', () async {
      store.failsToWrite = true;
      SharedPreferences.setMockInitialValues({'identity_secret': _older});
      final me = await Identity.signer();
      expect(me.publicKey, _publicOf(_older), reason: 'no new key');
      expect(await _inPreferences(), _older, reason: 'and the old preference kept');
      expect(store.kept, isNull);
      expect((await Identity.signer()).publicKey, me.publicKey, reason: 'at every ask');
      // Tried again at the next start, and then it goes.
      store.failsToWrite = false;
      expect((await Identity.signer()).publicKey, me.publicKey);
      expect(store.kept, _older);
      expect(await _inPreferences(), isNull);
    });

    for (final (why, set) in <(String, void Function(_Store))>[
      ('a store that keeps nothing of it', (s) => s.forgets = true),
      ('a store that gives back something else', (s) => s.garbles = true),
      ('a store whose read-back fails', (s) => s.failsToReadBack = true),
    ]) {
      test('$why: the preference is kept, and no new key is made', () async {
        set(store);
        SharedPreferences.setMockInitialValues({'identity_secret': _older});
        final me = await Identity.signer();
        expect(me.publicKey, _publicOf(_older));
        expect(await _inPreferences(), _older, reason: 'removed only once the store gave the key back');
      });
    }

    test('a store that cannot be read is not an empty one: nothing is written over it', () async {
      store
        ..kept = _older
        ..failsToRead = true;
      SharedPreferences.setMockInitialValues({'identity_secret': _other});
      final me = await Identity.signer();
      expect(me.publicKey, _publicOf(_other), reason: 'the preference, as it was before the store');
      expect(store.writes, 0, reason: 'and the key that may be in the store is left alone');
      expect(await _inPreferences(), _other);
      store.failsToRead = false;
      expect((await Identity.signer()).publicKey, _publicOf(_older), reason: 'the store speaks again, and is believed');
    });

    test('a device whose store cannot be read, with no key anywhere, still gets one, kept as it was before the store', () async {
      store.failsToRead = true;
      final me = await Identity.signer();
      final kept = await _inPreferences();
      expect(kept, matches(_hex));
      expect(me.publicKey, _publicOf(kept!));
      expect(store.writes, 0);
      // And the store answering again takes it in.
      store.failsToRead = false;
      expect((await Identity.signer()).publicKey, me.publicKey);
      expect(store.kept, kept);
      expect(await _inPreferences(), isNull);
    });

    test('a fresh device whose store will not keep its key keeps it among the preferences, and moves it at a later start', () async {
      store.failsToWrite = true;
      final me = await Identity.signer();
      final kept = await _inPreferences();
      expect(kept, matches(_hex));
      expect(me.publicKey, _publicOf(kept!));
      expect((await Identity.signer()).publicKey, me.publicKey, reason: 'one key, not one for each ask');
      store.failsToWrite = false;
      expect((await Identity.signer()).publicKey, me.publicKey);
      expect(store.kept, kept);
      expect(await _inPreferences(), isNull);
    });

    test('a move cut short after the store had the key is finished: the copy among the preferences goes', () async {
      store.kept = _older;
      SharedPreferences.setMockInitialValues({'identity_secret': _older});
      expect((await Identity.signer()).publicKey, _publicOf(_older));
      expect(await _inPreferences(), isNull);
      expect(store.writes, 0);
    });

    test('the store\'s key is the key; a different one among the preferences is left where it is', () async {
      store.kept = _older;
      SharedPreferences.setMockInitialValues({'identity_secret': _other});
      expect((await Identity.signer()).publicKey, _publicOf(_older));
      expect(await _inPreferences(), _other, reason: 'never deleted, only not believed');
      expect(store.kept, _older);
    });

    test('what is in the store but is not a key is no key', () async {
      for (final junk in ['', 'not a key', 'ab' * 31, 'zz' * 32, '${'ab' * 32}\n']) {
        store.kept = junk;
        SharedPreferences.setMockInitialValues({'identity_secret': _older});
        expect((await Identity.signer()).publicKey, _publicOf(_older), reason: 'the preference is the key over "$junk"');
        expect(store.kept, _older, reason: 'and replaces it');
      }
      store.kept = 'junk';
      SharedPreferences.setMockInitialValues({});
      await Identity.signer();
      expect(store.kept, matches(_hex), reason: 'with nothing else, a key is made over it');
    });

    test('starting afresh deletes the store\'s key as well as clearing the preferences', () async {
      SharedPreferences.setMockInitialValues({'identity_secret': _older, 'identity_name': 'Ada'});
      final me = await Identity.signer();
      expect(store.kept, _older);
      expect(await startAfresh(now: DateTime.utc(2026, 11, 1)), isTrue);
      expect(store.kept, isNull, reason: 'the key is not left behind in its store');
      expect(store.deletes, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {startedAfreshKey}, reason: 'nor among the preferences');
      expect((await Identity.signer()).publicKey, isNot(me.publicKey), reason: 'a new player');
    });

    test('starting afresh with a key still among the preferences clears that too', () async {
      store.failsToWrite = true;
      SharedPreferences.setMockInitialValues({'identity_secret': _older});
      await Identity.signer();
      store.failsToWrite = false;
      await startAfresh();
      expect(await _inPreferences(), isNull);
      expect(store.kept, isNull);
    });

    test('a key that cannot be deleted is thrown, not left behind unsaid', () async {
      SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
      await Identity.signer();
      store.failsToDelete = true;
      await expectLater(startAfresh(), throwsStateError);
      expect(store.kept, isNotNull);
      expect(await Identity.name(), 'Ada', reason: 'and nothing else is wiped under a key that stayed');
    });
  });

  group('with no store (the web, and a test that has not stood one)', () {
    setUp(() {
      SecretStore.current = null;
      SharedPreferences.setMockInitialValues({});
    });

    test('the key is made into the preferences, and is the same at every ask', () async {
      final me = await Identity.signer();
      final kept = await _inPreferences();
      expect(kept, matches(_hex));
      expect(me.publicKey, _publicOf(kept!));
      expect((await Identity.signer()).publicKey, me.publicKey);
    });

    test('a key among the preferences is the key', () async {
      SharedPreferences.setMockInitialValues({'identity_secret': _older});
      expect((await Identity.signer()).publicKey, _publicOf(_older));
      expect(await _inPreferences(), _older);
    });

    test('what is among the preferences but is not a key is replaced', () async {
      for (final junk in ['', 'short', 'zz' * 32]) {
        SharedPreferences.setMockInitialValues({'identity_secret': junk});
        final me = await Identity.signer();
        final kept = await _inPreferences();
        expect(kept, matches(_hex), reason: '"$junk"');
        expect(me.publicKey, _publicOf(kept!));
      }
    });

    test('starting afresh clears the key with the rest', () async {
      final me = await Identity.signer();
      await startAfresh();
      expect(await _inPreferences(), isNull);
      expect((await Identity.signer()).publicKey, isNot(me.publicKey));
    });
  });
}
