/// The licence, as the app reads one (docs/explanation/service.md).
///
/// The service signs it and the app checks it, in two languages on one
/// curve. So the pin here is a licence the worker actually minted —
/// `service/functions/licence.mjs`, `licenceFor` — rather than one this
/// side made for itself: a canonical statement that drifted apart would
/// otherwise pass on both sides and fail between them.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:table/table.dart';

/// BIP-340's own published pair, which the worker's tests sign with.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const _device = 'abababababababababababababababababababababababababababababababab';
const _account = '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a';

/// Minted by the worker for this test, and not to be regenerated to
/// make it pass: it failing means the two sides have drifted.
const _fromTheWorker = '{"key":"$_device","account":"$_account","until":"2026-10-17","plan":"year",'
    '"sig":"185b2a33fba5f4d0f5efacd8f7c115ccf53c209fd355af56c70b0a8a82b2b08ca5b2fe52225d45a2183092e11b555f83'
    '7ba28ec060d9b21de8be115bfa732927"}';

Licence _for(String device, DateTime until, {String secret = _serviceSecret, String plan = 'year', String account = _account}) {
  final unsigned = Licence(key: device, account: account, until: until, plan: plan, signature: '');
  return Licence(
    key: device,
    account: account,
    until: until,
    plan: plan,
    signature: SchnorrSigner.fromSecret(secret).sign(unsigned.digest),
  );
}

void main() {
  test('the worker\'s own licence reads here, and is this device\'s and this service\'s', () {
    final licence = Licence.parse(_fromTheWorker)!;
    expect(licence.key, _device);
    expect(licence.account, _account);
    expect(Licence.dayOf(licence.until), '2026-10-17');
    expect(licence.plan, 'year');
    expect(licence.signedBy(_service), isTrue, reason: 'the statement the two sides sign is the same statement');
    expect(licence.holdsFor(_device, service: _service, at: DateTime.utc(2026, 10, 17, 23, 59)), isTrue);
  });

  test('a licence is nothing to any other device, or under any other service key', () {
    final licence = Licence.parse(_fromTheWorker)!;
    final at = DateTime.utc(2026, 9, 16);
    expect(licence.holdsFor('cd' * 32, service: _service, at: at), isFalse, reason: 'not this device');
    expect(licence.holdsFor(_device, service: 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9', at: at), isFalse,
        reason: 'not this service');
    expect(licence.holdsFor(_device, service: '', at: at), isFalse, reason: 'a build that cannot name the service is told nothing');
  });

  test('a signature over one day is not a signature over another', () {
    final licence = Licence.parse(_fromTheWorker)!;
    final stretched = Licence(key: licence.key, account: licence.account, until: DateTime.utc(2027, 10, 17), plan: licence.plan, signature: licence.signature);
    expect(stretched.signedBy(_service), isFalse);
  });

  test('a signature naming one account is not a signature naming another', () {
    final licence = Licence.parse(_fromTheWorker)!;
    final moved = Licence(key: licence.key, account: '0b' * 16, until: licence.until, plan: licence.plan, signature: licence.signature);
    expect(moved.signedBy(_service), isFalse);
  });

  test('the date is the last day, and it runs to the end of it', () {
    final licence = _for(_device, DateTime.utc(2026, 10, 17));
    expect(licence.goodAt(DateTime.utc(2026, 10, 17, 0, 0)), isTrue);
    expect(licence.goodAt(DateTime.utc(2026, 10, 17, 23, 59, 59)), isTrue);
    expect(licence.goodAt(DateTime.utc(2026, 10, 18, 0, 0)), isFalse);
    // The clock the device keeps is its own, whatever zone it is in.
    expect(licence.goodAt(DateTime.utc(2026, 10, 17, 22).toLocal()), isTrue);
  });

  test('what is not a licence is not half a licence', () {
    expect(Licence.parse(null), isNull);
    expect(Licence.parse('not json'), isNull);
    expect(Licence.parse('{}'), isNull);
    expect(Licence.parse({'key': _device, 'account': _account, 'until': '2026-10-17', 'plan': 'year'}), isNull, reason: 'no signature');
    expect(Licence.parse({'key': _device, 'until': '2026-10-17', 'plan': 'year', 'sig': 'x'}), isNull, reason: 'no account');
    expect(Licence.parse({'key': _device, 'account': 'short', 'until': '2026-10-17', 'plan': 'year', 'sig': 'x'}), isNull);
    expect(Licence.parse({'key': 'short', 'until': '2026-10-17', 'plan': 'year', 'sig': 'x'}), isNull);
    expect(Licence.parse({'key': _device, 'until': '17/10/2026', 'plan': 'year', 'sig': 'x'}), isNull);
    expect(Licence.parse({'key': _device, 'until': '2026-02-31', 'plan': 'year', 'sig': 'x'}), isNull,
        reason: 'a day that does not exist is not a day');
    expect(Licence.parse({'key': _device, 'until': '2026-13-01', 'plan': 'year', 'sig': 'x'}), isNull);
  });

  test('a licence goes to the device and comes back the same', () {
    final licence = _for(_device, DateTime.utc(2027, 1, 1));
    final back = Licence.parse(licence.encoded)!;
    expect(back.encoded, licence.encoded);
    expect(back.holdsFor(_device, service: _service, at: DateTime.utc(2026, 12, 31)), isTrue);
  });

  test('a fake table\'s signature is not a licence, however well it is made', () {
    // A FakeSigner's signature is a hash of the signer's *public* key
    // and the digest, so anyone who can read a key can make one — and
    // the service's key is printed in every build. Everything else
    // signed here is checked with verify(), which takes them so that a
    // simulated table and a real one share every line of protocol
    // code. A licence is not, and this is why.
    final licence = _for(_device, DateTime.utc(2027, 1, 1));
    final forged = sha256Hex(utf8.encode('$_service|${licence.digest}')).substring(0, FakeSigner.length);
    final passedOff = Licence(key: licence.key, account: licence.account, until: licence.until, plan: licence.plan, signature: forged);
    final was = fakeSignaturesPass;
    fakeSignaturesPass = true; // as it is wherever a simulation runs
    try {
      expect(verify(_service, passedOff.digest, forged), isTrue, reason: 'the general check takes it');
      expect(passedOff.signedBy(_service), isFalse, reason: 'and a licence does not, even here');
      expect(passedOff.holdsFor(_device, service: _service, at: DateTime.utc(2026, 12, 31)), isFalse);
    } finally {
      fakeSignaturesPass = was;
    }
  });

  test('a request is signed over the statement the worker checks, by the key it names', () {
    // The same figure is pinned in service/functions/worker.test.mjs:
    // BIP-340's first key asking for a code at 1700000000.
    const first = 'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
    expect(requestDigest('ticket', first, 1700000000), '2c77f32dd54af71c904ab632f9d33a5c9fe47242fb2525ced9a01a0988629761');
    final me = SchnorrSigner.fromSecret('${'0' * 63}3');
    expect(me.publicKey, first);
    final asked = signedAsk(me, 'claim', what: 'ab12', now: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    expect(asked['key'], first);
    expect(asked['at'], 1700000000);
    final sig = asked['sig'] as String;
    expect(schnorrVerifier(first, requestDigest('claim', first, 1700000000, 'ab12'), sig), isTrue);
    expect(schnorrVerifier(first, requestDigest('claim', first, 1700000000, 'cd34'), sig), isFalse, reason: 'another code');
    expect(schnorrVerifier(first, requestDigest('ticket', first, 1700000000, 'ab12'), sig), isFalse, reason: 'another handler');
  });

  test('where the handlers are: the origin the app was served by, or nobody', () {
    expect(handlerFor('licence', Uri.parse('https://open-hearts.pages.dev/play/')).toString(),
        'https://open-hearts.pages.dev/api/licence');
    expect(handlerFor('claim', Uri.parse('http://127.0.0.1:8123/index.html')).toString(), 'http://127.0.0.1:8123/api/claim');
    expect(handlerFor('licence', Uri.parse('file:///tmp/index.html')), isNull);
    expect(handlerFor('licence', Uri.parse('/play/')), isNull);
  });
}
