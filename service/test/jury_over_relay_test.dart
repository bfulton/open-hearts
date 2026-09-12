/// The jury over real sockets: two people at a table on the local
/// relay, presence on it, and the service's juror of last resort. One
/// person goes quiet off turn; the other, no majority of two, asks;
/// the juror is called for, drawn, summoned, follows, and rules.
///
/// Silence is shortened from two minutes to ten seconds throughout, so
/// the test runs in under a minute; the protocol is otherwise the
/// app's. Run twice: at a seeded table, and at a sealed one, where the
/// juror also holds a piece of each person's deal secret and releases
/// it so the hand the quiet one left can be played out.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

import 'table_over_relay_test.dart' show Player;

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

  for (final sealed in [false, true]) {
  test('a ${sealed ? 'sealed' : 'seeded'} table of two with one gone quiet is finished by the juror of last resort', () async {
    const silence = 10000;
    final signers = [FakeSigner('a'), FakeSigner('b')];
    final spec = TableSpec(id: 'jury-relay', seed: 5, sealed: sealed, seats: [
      HumanSeat(signers[0].publicKey),
      HumanSeat(signers[1].publicKey),
      BotSeat(Persona.roster[3]),
      BotSeat(Persona.roster[4]),
    ]);
    final c0 = sealed ? crypto : null;
    final juror = LastResortJuror(relays: [relay.url], signer: FakeSigner('last-resort'), silenceAfterMs: silence, crypto: c0)..start();
    final presences = [for (final s in signers) RelayPresence(relays: [relay.url], signer: s)];
    final transports = [for (final s in signers) RelayTransport(relays: [relay.url], signer: s, table: spec.id)];
    await Future.wait(transports.map((t) => t.ready));
    final clients = [
      for (var i = 0; i < 2; i++)
        TableClient(
            spec: spec,
            signer: signers[i],
            transport: transports[i],
            clock: WallClock(),
            presence: presences[i],
            silenceAfterMs: silence,
            crypto: c0),
    ];
    final players = [for (final c in clients) Player(c)];
    for (final c in clients) {
      c.start();
    }
    // Let the jury be drawn — the juror is called for, comes online,
    // is seen, proposed and carried — then seat 1's process stops
    // answering, off its turn: the moment seat 0 is to play.
    final done = Completer<void>();
    Timer? quiet;
    late StreamSubscription<void> sub;
    sub = clients[0].changes.listen((_) {
      final c = clients[0];
      if (quiet == null && c.juries.isNotEmpty && c.game.phase == Phase.playing && c.awaitingMyPlay) {
        quiet = Timer(Duration.zero, () {
          players[1].stop();
          transports[1].close();
          presences[1].close();
          clients[1].close();
        });
      }
      if (c.done && !done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(minutes: 4), onTimeout: () {
      fail('not finished:\n${clients[0].describe()}\njuror: ${juror.duty.serving} tables, ${juror.duty.verdicts} verdicts, online ${juror.online}');
    });
    sub.cancel();
    final c = clients[0];
    expect(c.done, isTrue);
    expect(c.holders[1], isA<BotSeat>());
    expect(c.juries, isNotEmpty, reason: 'a jury was drawn');
    expect(c.juries.first.event.jurors, [juror.presence.signer.publicKey]);
    expect(c.record.any((d) => d.verdict != null), isTrue, reason: 'a verdict settled a turn');
    if (sealed) expect(c.game.knowsHand(1), isTrue, reason: 'the quiet seat\'s hand was opened with the juror\'s piece');
    final v = verifyRecord(spec, c.record, juries: c.juries, crypto: c0, releases: c.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    expect(juror.online, isTrue);
    for (final p in players) {
      p.stop();
    }
    for (final t in transports) {
      t.close();
    }
    for (final p in presences) {
      p.close();
    }
    for (final cl in clients) {
      cl.close();
    }
    juror.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
