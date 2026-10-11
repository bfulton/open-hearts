/// The jury over real sockets, for jury_over_relay_test.dart (a seeded
/// table) and jury_over_relay_sealed_test.dart (a sealed one), which run
/// side by side: two people at a table on the local
/// relay, presence on it, and the service's juror of last resort. One
/// person goes quiet off turn; the other, no majority of two, asks;
/// the juror is called for, drawn, summoned, follows, and rules.
///
/// Silence is shortened from two minutes to ten seconds throughout, so
/// the test runs in under a minute; the protocol is otherwise the
/// app's. Run twice: at a seeded table, with one juror, and at a sealed
/// one, with the bench of four the service runs — a sealed table's bot
/// seats are dealt only to a jury that can hold them ([juryToHoldBots]),
/// so one juror would leave it waiting for good. There the jurors also
/// hold a piece of each person's deal secret and release it so the hand
/// the quiet one left can be played out.
library;


import 'dart:async';

import 'package:deal/deal.dart';
import 'package:deal/memo.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';


void juryOverRelay({required bool sealed}) {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto(kept: false));
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

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
    final bench = LastResortBench(
        signers: [for (var i = 0; i < (sealed ? juryToHoldBots : 1); i++) FakeSigner('last-resort-$i')],
        relays: [relay.url],
        silenceAfterMs: silence,
        crypto: c0)
      ..start();
    final benchKeys = {for (final j in bench.jurors) j.presence.signer.publicKey};
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
    // A quarter of a second a decision: at a seeded table nothing waits
    // for the jury, and a game to fifty played in thirty-millisecond
    // decisions is over before the juror of last resort is so much as
    // called for — ten seconds of nobody else online.
    final players = [for (final c in clients) Player(c, thinkMs: 250)];
    for (final c in clients) {
      c.start();
    }
    // Let the jury be drawn — the juror is called for, comes online,
    // is seen, proposed and carried — then seat 1's process stops
    // answering, off its turn: the moment seat 0 is to play.
    final done = Completer<void>();
    Timer? quiet;
    int? quietHand;
    var opened = false;
    late StreamSubscription<void> sub;
    sub = clients[0].changes.listen((_) {
      final c = clients[0];
      // The quiet seat's hand, opened with the jurors' pieces, in the
      // hand it went quiet in: from the next, the bench holds the seat
      // and its cards are dealt to the holder, as a bot's are.
      if (c.game.handNumber == quietHand && c.game.knowsHand(1)) opened = true;
      if (quiet == null && c.juries.isNotEmpty && c.game.phase == Phase.playing && c.awaitingMyPlay) {
        quietHand = c.game.handNumber;
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
      fail('not finished:\n${clients[0].describe()}\nbench: ${bench.serving} tables, '
          '${bench.jurors.fold(0, (n, j) => n + j.duty.verdicts)} verdicts, online ${bench.online}');
    });
    sub.cancel();
    final c = clients[0];
    expect(c.done, isTrue);
    expect(c.holders[1], isA<BotSeat>());
    expect(c.juries, isNotEmpty, reason: 'a jury was drawn');
    expect(c.juries.first.event.jurors.toSet(), benchKeys, reason: 'the jury is the bench, nobody else being online');
    if (sealed) expect(benchKeys.containsAll(c.botHolders(c.game.handNumber).values), isTrue, reason: 'the bench held the bot seats');
    expect(c.record.any((d) => d.verdict != null), isTrue, reason: 'a verdict settled a turn');
    if (sealed) expect(opened, isTrue, reason: 'the quiet seat\'s hand was opened with the jurors\' pieces');
    final v = verifyRecord(spec, c.record, juries: c.juries, crypto: c0, releases: c.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    expect(bench.online, isTrue);
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
    bench.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
