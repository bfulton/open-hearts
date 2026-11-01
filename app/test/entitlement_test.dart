/// Asking for the licence until the service answers (entitlement.dart):
/// a start on a slow network, or with none, is not a start without a
/// subscription.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/net/backoff.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/network.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

/// BIP-340's own published pair, which the worker's tests sign with.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// A month's licence for [device], signed by the service.
Licence _licenceFor(PublicKey device) {
  final day = DateTime.now().toUtc().add(const Duration(days: 30));
  final until = DateTime.utc(day.year, day.month, day.day);
  final unsigned = Licence(key: device, account: '0a' * 16, until: until, plan: 'year', signature: '');
  return Licence(
    key: device,
    account: '0a' * 16,
    until: until,
    plan: 'year',
    signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest),
  );
}

const LicenceAnswer _down = (answered: false, licence: null, suspended: false);
const LicenceAnswer _none = (answered: true, licence: null, suspended: false);

/// The service standing in: the nth ask answered by [answers]' nth
/// entry — after its delay, or never when it is null, and like the
/// last entry once they run out. Each ask's time on the test clock is
/// kept in [at].
class _Service {
  _Service(this.clock, this.answers);

  final FakeAsync clock;
  final List<({Duration after, LicenceAnswer said})?> answers;
  final at = <Duration>[];

  Future<LicenceAnswer> ask(Signer signer, {String service = serviceKey}) {
    final answer = answers[at.length < answers.length ? at.length : answers.length - 1];
    at.add(clock.elapsed);
    if (answer == null) return Completer<LicenceAnswer>().future;
    return Future.delayed(answer.after, () => answer.said);
  }

  /// When each ask went, in whole seconds.
  List<int> get seconds => [for (final t in at) t.inSeconds];
}

void main() {
  final device = SchnorrSigner.generate();
  final originalOffline = deviceOffline;
  final originalOnline = whenOnline;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deviceOffline = () => false;
    whenOnline = (_) {};
  });
  tearDown(() {
    deviceOffline = originalOffline;
    whenOnline = originalOnline;
  });

  /// An entitlement over [answers], loaded for the device, and the
  /// service it asks.
  (Entitlement, _Service) start(FakeAsync clock, List<({Duration after, LicenceAnswer said})?> answers) {
    final service = _Service(clock, answers);
    final e = Entitlement(service: _service, ask: service.ask);
    e.load(device.publicKey);
    clock.flushMicrotasks();
    return (e, service);
  }

  test('a licence run out still says the device is in an account, until the device forgets it; another device\'s says nothing', () async {
    final day = DateTime.now().toUtc().subtract(const Duration(days: 3));
    final until = DateTime.utc(day.year, day.month, day.day);
    Licence lapsedFor(PublicKey key) {
      final unsigned = Licence(key: key, account: '0a' * 16, until: until, plan: 'year', signature: '');
      return Licence(key: key, account: '0a' * 16, until: until, plan: 'year', signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
    }

    SharedPreferences.setMockInitialValues({'licence': lapsedFor(device.publicKey).encoded});
    final lapsed = Entitlement(service: _service);
    await lapsed.load(device.publicKey);
    expect(lapsed.live, isFalse);
    expect(lapsed.inAnAccount, isTrue, reason: 'a lapsed subscriber\'s account is still there');
    await lapsed.forget();
    expect(lapsed.inAnAccount, isFalse, reason: 'forgotten, as when its account is deleted');

    SharedPreferences.setMockInitialValues({'licence': lapsedFor(SchnorrSigner.generate().publicKey).encoded});
    final other = Entitlement(service: _service);
    await other.load(device.publicKey);
    expect(other.inAnAccount, isFalse);
  });

  test('a start the service does not answer asks again, further apart each time, until it does', () {
    fakeAsync((clock) {
      final licence = (after: Duration.zero, said: (answered: true, licence: _licenceFor(device.publicKey), suspended: false) as LicenceAnswer);
      final (e, service) = start(clock, [
        null, // never answered: given up on after the few seconds
        (after: Duration.zero, said: _down), // a 503
        null,
        licence,
      ]);
      e.keepAsking(device);
      clock.elapse(const Duration(minutes: 1));
      // At once; given up on at 6 s and asked 2 s later; refused at
      // once and asked 4 s later; given up on at 18 s and asked 8 s
      // later — and answered.
      expect(service.seconds, [0, 8, 12, 26]);
      expect(e.live, isTrue);
      // And not asked again: the service has said.
      clock.elapse(const Duration(hours: 1));
      expect(service.at, hasLength(4));
    });
  });

  test('the waits between asks stop growing at two minutes', () {
    fakeAsync((clock) {
      final (e, service) = start(clock, [(after: Duration.zero, said: _down)]);
      e.keepAsking(device);
      clock.elapse(const Duration(minutes: 20));
      final gaps = [for (var i = 1; i < service.at.length; i++) service.at[i] - service.at[i - 1]];
      expect(gaps.take(7).map((g) => g.inSeconds), [2, 4, 8, 16, 32, 64, 120]);
      expect(gaps.skip(6), everyElement(Backoff.most), reason: 'no shorter, and no longer');
      expect(e.live, isFalse);
    });
  });

  test('an answer that comes after the wait for it is still taken, and ends the asking', () {
    fakeAsync((clock) {
      final (e, service) = start(clock, [
        (after: const Duration(seconds: 10), said: (answered: true, licence: _licenceFor(device.publicKey), suspended: false)),
        null,
      ]);
      final first = e.keepAsking(device);
      bool? answeredInTime;
      first.then((v) => answeredInTime = v);
      clock.elapse(const Duration(seconds: 7));
      expect(answeredInTime, isFalse, reason: 'the start stopped waiting at 6 s');
      expect(e.live, isFalse);
      clock.elapse(const Duration(seconds: 4));
      // Asked again at 8 s, and the first answer in at 10 s.
      expect(service.seconds, [0, 8]);
      expect(e.live, isTrue, reason: 'a slow answer is an answer');
      clock.elapse(const Duration(hours: 1));
      expect(service.at, hasLength(2));
    });
  });

  test('that there is no subscription is an answer: asked once', () {
    fakeAsync((clock) {
      final (e, service) = start(clock, [(after: Duration.zero, said: _none)]);
      e.keepAsking(device);
      clock.elapse(const Duration(hours: 1));
      expect(service.at, hasLength(1));
      expect(e.live, isFalse);
      // Nor does the foreground ask it again.
      e.askAgain();
      clock.elapse(const Duration(minutes: 1));
      expect(service.at, hasLength(1));
    });
  });

  test('a suspended account is an answer: the licence comes off the device, and the suspension is said until one is held again', () {
    fakeAsync((clock) {
      final suspended = (answered: true, licence: null, suspended: true) as LicenceAnswer;
      final (e, service) = start(clock, [(after: Duration.zero, said: suspended)]);
      e.adopt(_licenceFor(device.publicKey));
      clock.flushMicrotasks();
      expect(e.live, isTrue, reason: 'held from before, with a date to come');
      var told = 0;
      e.addListener(() => told++);
      e.keepAsking(device);
      clock.elapse(const Duration(minutes: 1));
      expect(service.at, hasLength(1), reason: 'answered, so asked once');
      expect(e.suspended, isTrue);
      expect(e.live, isFalse, reason: 'whatever its date, not a licence to play on');
      expect(told, greaterThan(0));
      SharedPreferences.getInstance().then((prefs) => expect(prefs.getString('licence'), isNull));
      clock.flushMicrotasks();
      // Let back: a licence held again is live play open, and no
      // suspension said.
      e.adopt(_licenceFor(device.publicKey));
      clock.flushMicrotasks();
      expect(e.suspended, isFalse);
      expect(e.live, isTrue);
    });
  });

  test('no network, no asking; a network back, or the app back in front, asks at once and the waits start short', () {
    fakeAsync((clock) {
      var offline = true;
      final back = <void Function()>[];
      deviceOffline = () => offline;
      whenOnline = back.add;
      final (e, service) = start(clock, [(after: Duration.zero, said: _down)]);
      e.keepAsking(device);
      clock.elapse(const Duration(minutes: 10));
      expect(service.at, isEmpty, reason: 'nobody to ask with no network');

      offline = false;
      for (final then in back) {
        then();
      }
      clock.elapse(const Duration(seconds: 15));
      // At once, and 2, 4 and 8 s after.
      expect(service.seconds, [600, 602, 606, 614]);

      // Back in front between two asks: one now, and the next 2 s after.
      clock.elapse(const Duration(seconds: 3));
      e.askAgain();
      clock.elapse(const Duration(seconds: 3));
      expect(service.seconds.skip(4), [618, 620]);
    });
  });

  group('what the service said', () {
    /// A stand-in for the licence handler, answering [status] with [body].
    Future<({Uri url, Future<void> Function() stop})> handler(int status, String body) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await req.drain<void>();
        req.response.statusCode = status;
        req.response.write(body);
        await req.response.close();
      });
      return (url: Uri.parse('http://127.0.0.1:${server.port}/api/licence'), stop: () => server.close(force: true));
    }

    /// The licence asked for of [url].
    Future<LicenceAnswer> askAt(Uri url) async {
      final was = handlerAt;
      handlerAt = (_) => url;
      try {
        return await askLicence(device, service: _service);
      } finally {
        handlerAt = was;
      }
    }

    Future<LicenceAnswer> asked(int status, String body) async {
      final h = await handler(status, body);
      try {
        return await askAt(h.url);
      } finally {
        await h.stop();
      }
    }

    test('a licence, or that there is none, is an answer; a service down, busy or not there is not', () async {
      final licence = _licenceFor(device.publicKey);
      final given = await asked(200, jsonEncode({'licence': jsonDecode(licence.encoded)}));
      expect(given.answered, isTrue);
      expect(given.licence?.encoded, licence.encoded);
      expect(await asked(402, '{"error":"no subscription"}'), _none);
      expect(
        await asked(403, '{"error":"suspended: this account is suspended from live play","suspended":true}'),
        (answered: true, licence: null, suspended: true),
      );
      expect(await asked(403, '{"error":"not allowed"}'), _none, reason: 'only the service saying so is a suspension');
      expect(await asked(401, '{"error":"bad signature"}'), _none, reason: 'asked again, the same request is refused again');
      expect(await asked(503, '{"error":"service not configured: OH_STORE"}'), _down);
      expect(await asked(429, ''), _down);
      expect(await asked(200, '<html>a captive portal</html>'), _down, reason: 'not the service talking');
      expect(await askAt(Uri.parse('http://127.0.0.1:1/api/licence')), _down);
      // Somebody else's licence, from the service, is still its answer.
      final theirs = await asked(200, jsonEncode({'licence': jsonDecode(_licenceFor('cd' * 32).encoded)}));
      expect(theirs, _none);
    });
  });
}
