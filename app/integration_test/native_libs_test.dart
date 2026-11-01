/// On a phone or its simulator: the deal and Schnorr libraries the app
/// carries (crypto/build_ios.sh, crypto/build_android.sh) load the way
/// the app loads them at startup (main.dart), make the same bytes as
/// the build every other suite tests, and a shuffle made in the deal's
/// worker checks. Without them this device plays no live table.
///
/// And the phone's own native side for the device's secret key
/// (lib/secret_store_io.dart): that the app has a store on a phone, and
/// that it keeps a secret and gives it back, which on an iPhone is
/// ios/Runner/AppDelegate.swift marking the file as not to be backed up
/// and saying that the file says so. Neither phone's backup is made or
/// restored here.
///
///   `flutter test integration_test/native_libs_test.dart -d <device>`
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deal/deal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/secret_store.dart';
import 'package:open_hearts/secret_store_io.dart';
import 'package:table/table.dart';

Uint8List bytes(int start) => Uint8List.fromList(List.generate(32, (i) => (start + i) & 0xff));

String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Schnorr: the native signer passes its BIP-340 check and is installed', () async {
    expect(await installNativeSchnorr(), isTrue);
  });

  test('the deal loads, makes the bytes the desktop build makes, and its worker shuffles', () async {
    await loadDeal();
    expect(dealReady, isTrue, reason: 'the deal and its worker');
    final c = dealCrypto!;
    final pks = [for (final s in [1, 2]) c.keygen(bytes(s))];
    // From the cdylib on Linux, the build the table's suites play with.
    expect(hex(pks[0]), '5221b039bb94081555562e7338bbe237569ccceba8cc8574e62dc78f6b9a0c01');
    final joint = c.aggregate(pks);
    final deck = c.initialDeck(joint);

    final made = Completer<Object>();
    dealWorker!.run(ShuffleJob(joint, deck, bytes(9)), done: made.complete, failed: made.completeError);
    final s = await made.future as ({Uint8List deck, Uint8List proof});
    expect(sha256.convert(s.deck).toString(), '00c8ed72a9c049666e98acaa93c74531069b7712f8e581b4c75250f1768aa71c');
    expect(sha256.convert(s.proof).toString(), '6ba8f7fe437a84d8b53538b3af63b8e9f24a4ebe55a99217b353ec28c7696e8f');
    expect(c.verifyShuffle(joint, deck, s.deck, s.proof), isTrue);
    final bent = Uint8List.fromList(s.proof)..[0] ^= 1;
    expect(c.verifyShuffle(joint, deck, s.deck, bent), isFalse);
  });

  test('the key store: the app has one on a phone, and it keeps a secret, gives it back and forgets it', () async {
    expect(SecretStore.current, Platform.isIOS ? isA<IosSecretStore>() : isA<AndroidSecretStore>());
    // A store of a name of its own, so that a key this device has made
    // is not touched.
    SecretStore another() => Platform.isIOS ? IosSecretStore(file: 'identity_secret_test') : AndroidSecretStore(file: '${identityFile}_test');
    final store = another();
    final first = hex(bytes(1));
    final second = hex(bytes(2));
    await store.delete();
    expect(await store.read(), isNull);
    // An iPhone's refuses a secret when its file does not say that it is
    // not backed up.
    await store.write(first);
    expect(await another().read(), first, reason: 'by a store made afterwards, as at the next start');
    await store.write(second);
    expect(await another().read(), second);
    await store.delete();
    expect(await another().read(), isNull);
  });
}
