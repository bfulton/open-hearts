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
/// Here it is in Dart, over real sockets, so that a stall — a juror
/// that never makes its seat's keys, a person whose turn goes unplayed
/// — can be read rather than inferred from a screen.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:deal/memo.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto(kept: false));
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
    // To 27, not 50: no hand can take a seat past 26, so every game is
    // at least two hands — a second deal, its bot seats held again by
    // jurors from the other table — and seldom more than three, where
    // fifty is two to six. What is held is the same: both games end,
    // neither stands still, each hand in its time.
    final many = TableSpec(id: 'table-many', seed: 3, sealed: true, target: 27, seats: [
      for (final s in signers.take(3)) HumanSeat(s.publicKey),
      BotSeat(Persona.roster[2]),
    ]);
    final one = TableSpec(id: 'table-one', seed: 4, sealed: true, target: 27, seats: [
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
    // Backup jurors behind them, as the browser suite has: four people are
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
    // Both games, to the end, held to two things. Neither table stands
    // still for a minute: a stopped table — a juror that never made its
    // seat's keys, a person whose turn went unplayed — stops moving long
    // before any clock on the whole game runs out. And a hand takes no
    // more than forty-five seconds on average, a person's wait at a
    // screen. The bound is per hand, not per game, because a game is as
    // many hands as its deal takes to reach the target: two or three
    // here, at thirty-odd seconds a hand.
    final started = DateTime.now();
    final finishedAt = <String, Duration>{};
    final moved = {for (final c in clients) c.spec.id: DateTime.now()};
    final mark = <String, int>{};
    int progress(String table) =>
        clients.where((c) => c.spec.id == table).fold(0, (n, c) => n + c.record.length + c.step + c.game.handNumber * 1000);
    String state() => '${[
          for (final c in clients) '${c.signer.publicKey.substring(0, 4)} ${c.describe()}'
        ].join('\n')}\n'
        'duties: ${[for (final d in duties) '${d.signer.publicKey.substring(0, 4)} serving ${d.serving}'].join(', ')}\n'
        '${[
          for (final d in duties)
            for (final e in d.clients.entries) '${d.signer.publicKey.substring(0, 4)} at ${e.key}: ${e.value.describe()}'
        ].join('\n')}';
    final done = Completer<void>();
    final subs = [
      for (final c in clients)
        c.changes.listen((_) {
          if (c.done) finishedAt.putIfAbsent(c.spec.id, () => DateTime.now().difference(started));
          if (clients.every((c) => c.done) && !done.isCompleted) done.complete();
        }),
    ];
    final watch = Timer.periodic(const Duration(seconds: 5), (_) {
      for (final table in moved.keys) {
        if (clients.where((c) => c.spec.id == table).every((c) => c.done)) continue;
        final now = progress(table);
        if (now != mark[table]) {
          mark[table] = now;
          moved[table] = DateTime.now();
        } else if (DateTime.now().difference(moved[table]!) > const Duration(minutes: 1) && !done.isCompleted) {
          done.completeError(TestFailure('$table stood still for a minute:\n${state()}'));
        }
      }
    });
    await done.future.timeout(const Duration(minutes: 9), onTimeout: () {
      fail('both games finished:\n${state()}');
    });
    watch.cancel();
    for (final c in [clients.first, clients.last]) {
      final hands = c.game.handNumber + 1;
      final each = finishedAt[c.spec.id]!.inMilliseconds / hands;
      expect(each, lessThan(45000), reason: '${c.spec.id}: $hands hands, ${(each / 1000).toStringAsFixed(1)} s a hand');
    }
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
  }, timeout: const Timeout(Duration(minutes: 10)));
}
