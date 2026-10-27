/// One device at a time, over a real socket to the relay the Cloudflare
/// object runs (service/do/relay.mjs, serviceGate; docs/explanation/service.md):
/// a device the service has not given a current activation is carried
/// nothing, a later device of the account cuts the earlier one off, and
/// the earlier one hears that it was superseded and stops coming back;
/// as does a device told by its account's turn that it is suspended.
library;

import 'dart:async';
import 'dart:convert';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// BIP-340's published pair: the service of these tests.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const _ada = '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a';
const _bao = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';

Activation activationFor(PublicKey key, String account, int epoch) {
  final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final unsigned = Activation(account: account, key: key, epoch: epoch, until: until, signature: '');
  return Activation(account: account, key: key, epoch: epoch, until: until, signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
}

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  final shown = <PublicKey, Activation>{};
  final turnedAway = <String>[];
  setUp(() async {
    relay = Relay(gate: _service);
    await relay.serve();
    shown.clear();
    turnedAway.clear();
    relayCredentials = (key) => shown[key] == null
        ? null
        : [
            ['activation', jsonEncode(shown[key]!.toJson())],
          ];
    relayTurnedAway = turnedAway.add;
  });
  tearDown(() async {
    relayCredentials = null;
    relayTurnedAway = null;
    await relay.close();
  });

  /// The next table message [t] hears, or null within [ms].
  Future<Map<String, Object?>?> next(RelayTransport t, {int ms = 3000}) =>
      t.watch.first.then<Map<String, Object?>?>((m) => m.content).timeout(Duration(milliseconds: ms), onTimeout: () => null);

  test('a device with no activation is carried nothing; one with one is', () async {
    final stranger = SchnorrSigner.generate();
    final ada = SchnorrSigner.generate();
    shown[ada.publicKey] = activationFor(ada.publicKey, _ada, 1);
    final listening = RelayTransport(relays: [relay.url], signer: ada, table: 't1');
    final speaking = RelayTransport(relays: [relay.url], signer: stranger, table: 't1');
    await listening.ready.timeout(const Duration(seconds: 5));
    final heard = next(listening);
    speaking.sayWatch({'from': 'nobody'});
    expect(await heard, isNull, reason: 'a device the service has not vouched for says nothing here');
    shown[stranger.publicKey] = activationFor(stranger.publicKey, _bao, 1);
    final other = RelayTransport(relays: [relay.url], signer: stranger, table: 't1');
    await other.ready.timeout(const Duration(seconds: 5));
    final heardNow = next(listening);
    other.sayWatch({'from': 'bao'});
    expect(await heardNow, {'from': 'bao'});
    for (final t in [listening, speaking, other]) {
      t.close();
    }
  });

  test('a later device of the account cuts the earlier one off, and it hears why and stays away', () async {
    final phone = SchnorrSigner.generate();
    final laptop = SchnorrSigner.generate();
    final bao = SchnorrSigner.generate();
    shown[phone.publicKey] = activationFor(phone.publicKey, _ada, 1);
    shown[bao.publicKey] = activationFor(bao.publicKey, _bao, 1);
    final onPhone = RelayTransport(relays: [relay.url], signer: phone, table: 't2');
    final atBao = RelayTransport(relays: [relay.url], signer: bao, table: 't2');
    await Future.wait([onPhone.ready, atBao.ready]).timeout(const Duration(seconds: 5));
    final first = next(atBao);
    onPhone.sayWatch({'n': 1});
    expect(await first, {'n': 1});

    // The laptop takes the account up.
    shown[laptop.publicKey] = activationFor(laptop.publicKey, _ada, 2);
    final onLaptop = RelayTransport(relays: [relay.url], signer: laptop, table: 't2');
    await onLaptop.ready.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 40 && turnedAway.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(turnedAway, [startsWith('superseded:')], reason: 'the phone is told, once');
    final after = next(atBao, ms: 1500);
    onPhone.sayWatch({'n': 2});
    expect(await after, isNull, reason: 'and carried nothing from then on');
    final fromLaptop = next(atBao);
    onLaptop.sayWatch({'n': 3});
    expect(await fromLaptop, {'n': 3});
    // Nor does it come back on what it was given: it does not try, and
    // the relay holds the other two.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(relay.connections, 2);
    for (final t in [onPhone, atBao, onLaptop]) {
      t.close();
    }
  });

  test('told by the account\'s turn, wherever the old device is, before the new one is seen there', () async {
    final phone = SchnorrSigner.generate();
    shown[phone.publicKey] = activationFor(phone.publicKey, _ada, 1);
    final onPhone = RelayTransport(relays: [relay.url], signer: phone, table: 't3');
    await onPhone.ready.timeout(const Duration(seconds: 5));
    relay.revoke(_ada, 2);
    for (var i = 0; i < 40 && turnedAway.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(turnedAway, [startsWith('superseded:')]);
    onPhone.close();
  });

  test('told it is suspended, by the account\'s turn, and stays away', () async {
    final phone = SchnorrSigner.generate();
    shown[phone.publicKey] = activationFor(phone.publicKey, _ada, 1);
    final onPhone = RelayTransport(relays: [relay.url], signer: phone, table: 't4');
    await onPhone.ready.timeout(const Duration(seconds: 5));
    relay.revoke(_ada, 2, why: 'suspended: this account is suspended from live play');
    for (var i = 0; i < 40 && turnedAway.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(turnedAway, ['suspended: this account is suspended from live play']);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(relay.connections, 0, reason: 'it does not come back on the activation it holds');
    onPhone.close();
  });
}
