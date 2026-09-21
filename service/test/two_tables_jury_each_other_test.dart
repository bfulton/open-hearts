/// Two tables at once, each playing for the other's jury.
///
/// This is the browser suite's first cell without the browsers
/// (e2e/run.mjs): four devices are matched into two tables — three
/// people with a bot, and one person with three bots — and the bot
/// seats of each are held by jurors drawn from the people at the
/// other. Every device is therefore a player at one table and a juror
/// at another, in one process, and the two tables can only finish
/// together: a device that stops doing either stops both.
///
/// That cell is the one that stalls in the browsers, and what stalls
/// is never the same thing twice — once a juror that never made its
/// seat's keys, once a person whose turn went unplayed. Here it is in
/// Dart, over real sockets, so that a stall can be read rather than
/// inferred from a screen.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

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

  test('two tables whose bot seats are held by each other\'s people both finish a game', () async {
    const silence = 30000;
    final signers = [for (var i = 0; i < 4; i++) FakeSigner('device$i')];
    // Three together with a bot, and one alone with three: the shapes
    // matchmaking makes of four people who asked for different games.
    final many = TableSpec(id: 'table-many', seed: 3, sealed: true, seats: [
      for (final s in signers.take(3)) HumanSeat(s.publicKey),
      BotSeat(Persona.roster[2]),
    ]);
    final one = TableSpec(id: 'table-one', seed: 4, sealed: true, seats: [
      HumanSeat(signers[3].publicKey),
      for (var i = 0; i < 3; i++) BotSeat(Persona.roster[i]),
    ]);
    // Presence is one per device and does both jobs: it is how a
    // device is seen to be online and drawable, and how a summons
    // reaches it.
    final presences = [for (final s in signers) RelayPresence(relays: [relay.url], signer: s)];
    // And every device serves, because at the table next door it is a
    // stranger like any other (app/lib/net/duty.dart).
    final duties = [
      for (var i = 0; i < 4; i++)
        JurorDuty(relays: [relay.url], signer: signers[i], presence: presences[i], silenceAfterMs: silence, crypto: crypto)..start(),
    ];
    // A bench behind them, as the browser suite has: four people are
    // not enough to hold seven bot seats between two tables.
    final bench = [
      for (var i = 0; i < juryToHoldBots; i++)
        LastResortJuror(relays: [relay.url], signer: FakeSigner('bench$i'), silenceAfterMs: silence, crypto: crypto)..start(),
    ];
    final transports = [
      for (var i = 0; i < 4; i++)
        RelayTransport(relays: [relay.url], signer: signers[i], table: i < 3 ? many.id : one.id),
    ];
    await Future.wait(transports.map((t) => t.ready));
    final clients = [
      for (var i = 0; i < 4; i++)
        TableClient(
            spec: i < 3 ? many : one,
            signer: signers[i],
            transport: transports[i],
            clock: WallClock(),
            presence: presences[i],
            silenceAfterMs: silence,
            crypto: crypto),
    ];
    final players = [for (final c in clients) Player(c, thinkMs: 250)];
    for (final c in clients) {
      c.start();
    }
    // Both games, to the end. The browser suite gives this cell three
    // minutes and that is the number worth holding to: it is what a
    // person waiting on a screen is being asked to sit through.
    final done = Completer<void>();
    final subs = [
      for (final c in clients)
        c.changes.listen((_) {
          if (clients.every((c) => c.done) && !done.isCompleted) done.complete();
        }),
    ];
    await done.future.timeout(const Duration(minutes: 3), onTimeout: () {
      fail('both games finished:\n${[
        for (final c in clients) '${c.signer.publicKey.substring(0, 4)} ${c.describe()}'
      ].join('\n')}\n'
          'duties: ${[for (final d in duties) '${d.signer.publicKey.substring(0, 4)} serving ${d.serving}'].join(', ')}\n'
          '${[
        for (final d in duties)
          for (final e in d.clients.entries) '${d.signer.publicKey.substring(0, 4)} at ${e.key}: ${e.value.describe()}'
      ].join('\n')}');
    });
    for (final s in subs) {
      s.cancel();
    }
    for (final c in clients) {
      expect(c.done, isTrue);
      final v = verifyRecord(c.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
      expect(v.ok && v.complete, isTrue, reason: '${c.signer.publicKey.substring(0, 4)}: ${v.reason}');
    }
    for (final p in players) {
      p.stop();
    }
    for (final t in transports) {
      t.close();
    }
    for (final d in duties) {
      d.close();
    }
    for (final p in presences) {
      p.close();
    }
    for (final c in clients) {
      c.close();
    }
    for (final j in bench) {
      j.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
