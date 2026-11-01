/// Accounts at the table (docs/explanation/live-play.md, docs/explanation/service.md): a
/// seat is the account its licence names, checked by every peer against
/// the service's key, by every device before it sits, by the house
/// before it serves and by whoever checks the game after; results and
/// ratings are the accounts'; and a device superseded by another of its
/// account is heard as such.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// BIP-340's own published pair: the service of these tests, as of the
/// worker's (service/functions/worker.test.mjs) and the browser rig's.
const _serviceSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
const _ada = '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a';
const _bao = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';

Licence licenceFor(PublicKey key, String account, {String secret = _serviceSecret, DateTime? until}) {
  final day = until ?? DateTime.utc(2099, 1, 1);
  final unsigned = Licence(key: key, account: account, until: day, plan: 'year', signature: '');
  return Licence(key: key, account: account, until: day, plan: 'year', signature: SchnorrSigner.fromSecret(secret).sign(unsigned.digest));
}

Activation activationFor(PublicKey key, String account, int epoch, {int? until}) {
  final at = until ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final unsigned = Activation(account: account, key: key, epoch: epoch, until: at, signature: '');
  return Activation(account: account, key: key, epoch: epoch, until: at, signature: SchnorrSigner.fromSecret(_serviceSecret).sign(unsigned.digest));
}

void main() {
  final phone = SchnorrSigner.generate();
  final laptop = SchnorrSigner.generate();
  final other = SchnorrSigner.generate();

  setUp(() => licenceService = _service);
  tearDown(() => licenceService = '');

  test('the worker\'s own activation reads here (service/functions/licence.mjs, activationFor)', () {
    // Minted by the worker for this test, and not to be regenerated to
    // make it pass: it failing means the two sides have drifted.
    final act = Activation.parse({
      'account': _ada,
      'key': 'ab' * 32,
      'epoch': 3,
      'until': 1791000000,
      'sig':
          'f057c3fdfcb5ff1d195ce9cf4c3044a9f2141cf39d30672ae7ce3263fc6684309ed08cd852ca4e5d61acc00f8ac5ea3cc0159618cb8d9659e09ac99d5b81c82a',
    })!;
    expect(act.signedBy(_service), isTrue);
    expect(act.holdsFor('ab' * 32, service: _service, at: DateTime.fromMillisecondsSinceEpoch(1790999999 * 1000)), isTrue);
    expect(act.holdsFor('ab' * 32, service: _service, at: DateTime.fromMillisecondsSinceEpoch(1791000000 * 1000)), isFalse, reason: 'run out');
    final moved = Activation(account: _bao, key: act.key, epoch: act.epoch, until: act.until, signature: act.signature);
    expect(moved.signedBy(_service), isFalse, reason: 'another account is another statement');
  });

  test('a seat is the account its licence names, and every seat must show one that holds', () {
    final good = TableSpec(seed: 1, seats: [
      HumanSeat(phone.publicKey, licence: licenceFor(phone.publicKey, _ada)),
      HumanSeat(other.publicKey, licence: licenceFor(other.publicKey, _bao)),
      const BotSeat(Persona.romeo),
      const BotSeat(Persona.juliet),
    ]);
    expect(good.licenceProblem(at: DateTime.utc(2026, 10, 6)), isNull);
    expect(good.accounts, {_ada, _bao});
    expect(good.seatOfAccount(_bao), 1);
    // Through the wire and back, licences and all.
    final back = TableSpec.parse(jsonDecode(jsonEncode(good.toJson())))!;
    expect((back.seats[0] as HumanSeat).account, _ada);
    expect(back.licenceProblem(), isNull);

    TableSpec seated(List<SeatHolder> people) =>
        TableSpec(seed: 1, seats: [...people, for (var i = people.length; i < 4; i++) const BotSeat(Persona.westley)]);
    for (final (why, spec) in [
      ('no licence', seated([HumanSeat(phone.publicKey)])),
      ('another key\'s', seated([HumanSeat(phone.publicKey, licence: licenceFor(laptop.publicKey, _ada))])),
      ('not the service\'s', seated([HumanSeat(phone.publicKey, licence: licenceFor(phone.publicKey, _ada, secret: '${'0' * 63}3'))])),
      ('one account twice', seated([
        HumanSeat(phone.publicKey, licence: licenceFor(phone.publicKey, _ada)),
        HumanSeat(laptop.publicKey, licence: licenceFor(laptop.publicKey, _ada)),
      ])),
    ]) {
      expect(spec.licenceProblem(), isNotNull, reason: why);
    }
    final ranOut = seated([HumanSeat(phone.publicKey, licence: licenceFor(phone.publicKey, _ada, until: DateTime.utc(2026, 1, 1)))]);
    expect(ranOut.licenceProblem(at: DateTime.utc(2026, 10, 6)), isNotNull, reason: 'run out, to sit down');
    expect(ranOut.licenceProblem(), isNull, reason: 'a record is read long after: no clock to hold it to');

    // A licence whose account was changed is not the service's word.
    final l = licenceFor(phone.publicKey, _ada);
    final swapped = Licence(key: l.key, account: _bao, until: l.until, plan: l.plan, signature: l.signature);
    expect(seated([HumanSeat(phone.publicKey, licence: swapped)]).licenceProblem(), isNotNull);
  });

  group('a sealed table of one hand', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    // Two people, each with a licence for their own key unless [without]
    // names their place, and two bots the house holds.
    SimTable table({int? without}) {
      const seed = 41;
      final second = FakeSigner('p1-$seed').publicKey;
      return SimTable(
        humans: 2,
        seed: seed,
        target: 1,
        crypto: crypto,
        licenceOf: (key) => without == 1 && key == second ? null : licenceFor(key, key.substring(0, 32)),
      );
    }

    test('whose seats all show their licences is served by the house, played out, and believed', () {
      final t = table()..start();
      expect(t.run(), isTrue);
      expect(t.following.map((c) => c.state), everyElement(TableState.finished));
      expect(t.results, hasLength(1), reason: 'the house said how it came out');
      final verdict = verifyRecord(GameRecord(spec: t.spec, log: t.referee.log), crypto: crypto, house: t.houseSigner.publicKey);
      expect(verdict.ok, isTrue, reason: verdict.reason);
      t.close();
    });

    test('with a seat that shows none is not served by the house, fails at the house\'s first turn, and is not believed', () {
      final t = table(without: 1)..start();
      // The house is not there to say how it came out: the run waits for
      // that word, and the table is over long before the limit.
      t.run(limitMs: 10 * 60 * 1000);
      expect(t.following.map((c) => c.state), everyElement(TableState.failed));
      expect(t.house!.serving, isEmpty, reason: 'the house let the table go');
      expect(t.results, isEmpty, reason: 'nobody is rated on it');
      expect(t.referee.log.where((e) => e.event?.author == t.houseSigner.publicKey), isEmpty, reason: 'the house said nothing at it');
      final verdict = verifyRecord(GameRecord(spec: t.spec, log: t.referee.log), crypto: crypto, house: t.houseSigner.publicKey, allowUnfinished: true);
      expect(verdict.ok, isFalse);
      expect(verdict.reason, 'seat 1 has no licence for its key');
      t.close();
    });
  });

  test('a rating is the account\'s, whichever device sat; a result is vouched for by the device that sat, and one from before accounts is not folded', () {
    final spec = TableSpec(seed: 1, rated: true, seats: [
      HumanSeat(phone.publicKey, licence: licenceFor(phone.publicKey, _ada)),
      HumanSeat(other.publicKey, licence: licenceFor(other.publicKey, _bao)),
      const BotSeat(Persona.romeo),
      const BotSeat(Persona.juliet),
    ]);
    final result = GameResult.of(spec, spec.seats, [10, 50, 60, 80]);
    NostrEvent say(Signer s, Map<String, Object?> content, int at) =>
        NostrEvent.sign(s, kind: TableKinds.lobby, content: jsonEncode(content), tags: [
          ['t', GameResult.tag]
        ], createdAt: at);
    final both = Ledger.from([say(phone, result.toJson(), 1), say(other, result.toJson(), 2)]);
    expect(both.gamesOf(_ada), 1);
    expect(both.of(_ada).mu, greaterThan(1500));
    expect(both.gamesOf(phone.publicKey), 0, reason: 'a device has no rating of its own');
    // The account's other device did not sit there, and vouches for nothing.
    expect(Ledger.from([say(laptop, result.toJson(), 1), say(other, result.toJson(), 2)]).gamesOf(_ada), 0);
    // Device-keyed, from before accounts: not a result here.
    final old = result.toJson()
      ..remove('v')
      ..['seats'] = [
        for (final s in result.seats) {'key': ?s.key, 'bot': ?s.bot, 'total': s.total, 'fromStart': s.fromStart}
      ];
    expect(Ledger.from([say(phone, old, 1), say(other, old, 2)]).standing, isEmpty);
    // A line whose licence is not the service's word is no line.
    final forged = result.toJson();
    ((forged['seats'] as List)[0] as Map)['licence'] = licenceFor(phone.publicKey, _ada, secret: '${'0' * 63}3').toJson();
    expect(Ledger.from([say(phone, forged, 1), say(other, forged, 2)]).standing, isEmpty);
  });

  test('a watcher is a licensed device of an account not at the table', () {
    final w = WatchBroadcast(heard: const Stream.empty(), say: (_) {}, view: () => throw UnimplementedError(), answering: () => true, seated: {_ada});
    expect(w.admits(other.publicKey, {'watching': true, 'licence': licenceFor(other.publicKey, _bao).toJson()}), isTrue);
    expect(w.admits(laptop.publicKey, {'watching': true, 'licence': licenceFor(laptop.publicKey, _ada).toJson()}), isFalse,
        reason: 'the player\'s own laptop, watching their own game');
    expect(w.admits(other.publicKey, {'watching': true}), isFalse, reason: 'no subscription');
    expect(w.admits(other.publicKey, {'watching': true, 'licence': licenceFor(laptop.publicKey, _bao).toJson()}), isFalse,
        reason: 'somebody else\'s licence');
  });

  test('presence: a device says whose it is, and a later one of the account outdoes the earlier at once', () async {
    final mine = activationFor(phone.publicKey, _ada, 1);
    final presence = RelayPresence(relays: [Uri.parse('ws://127.0.0.1:9')], signer: phone, activation: () => mine);
    addTearDown(presence.close);
    final superseded = <Activation>[];
    presence.superseded.listen(superseded.add);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Map<String, Object?> beat(Signer s, Activation? a) => NostrEvent.sign(s, kind: TableKinds.presence, content: jsonEncode({
          'kind': 'here',
          'activation': ?a?.toJson(),
        }), tags: [
          ['t', RelayPresence.topic]
        ], createdAt: now).toJson();

    presence.receive(beat(other, activationFor(other.publicKey, _bao, 4)));
    // Somebody claiming the account with an activation the service did
    // not sign takes nothing up, however late its epoch.
    final forged = Activation(account: _ada, key: laptop.publicKey, epoch: 9, until: now + 600, signature: 'ab' * 64);
    presence.receive(beat(laptop, forged));
    await Future<void>.delayed(Duration.zero);
    expect(superseded, isEmpty);

    // The laptop takes the account up, and says so.
    presence.receive(beat(laptop, activationFor(laptop.publicKey, _ada, 2)));
    await Future<void>.delayed(Duration.zero);
    expect(superseded.single.key, laptop.publicKey, reason: 'this device hears it has been superseded');

    // And of two devices of one account, the later is online and the
    // earlier is not, from the moment the later is heard.
    final third = SchnorrSigner.generate();
    final watcher = RelayPresence(relays: [Uri.parse('ws://127.0.0.1:9')], signer: third);
    addTearDown(watcher.close);
    watcher.receive(beat(phone, mine));
    expect(watcher.online(withinMs: 15000), contains(phone.publicKey));
    watcher.receive(beat(laptop, forged));
    expect(watcher.online(withinMs: 15000), contains(phone.publicKey), reason: 'a forged activation outdoes nobody');
    watcher.receive(beat(laptop, activationFor(laptop.publicKey, _ada, 2)));
    expect(watcher.online(withinMs: 15000), contains(laptop.publicKey));
    expect(watcher.online(withinMs: 15000), isNot(contains(phone.publicKey)));
  });
}
