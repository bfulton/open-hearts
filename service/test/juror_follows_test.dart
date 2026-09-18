/// A juror following a full table over real sockets: four people at a
/// sealed table on the local relay, the service's juror of last
/// resort drawn for want of anyone else, summoned, and carried forward
/// through a hand it never saw dealt. It has to keep heartbeating
/// while it verifies everything it is handed — a juror that fell
/// silent under the load was never carried to the hand it was needed
/// for — and reach the second hand as the players do.
library;

import 'dart:async';
import 'dart:io';

import 'package:deal/deal.dart';
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

  test('the juror of last resort follows a sealed table of four through its first hand', () async {
    const silence = 10000;
    // Real keys throughout: a signature checked is what an event costs
    // a peer, and the juror's load is the point.
    final signers = [for (var i = 0; i < 4; i++) SchnorrSigner.generate()];
    final spec = TableSpec(id: 'follow-relay', seed: 6, sealed: true, seats: [for (final s in signers) HumanSeat(s.publicKey)]);
    // Every client's trace, the juror's included, at a known path.
    final sink = (File('${Directory.current.path}/build/logs/juror.log')..parent.createSync(recursive: true)).openWrite();
    final juror = LastResortJuror(
        relays: [relay.url],
        signer: SchnorrSigner.generate(),
        silenceAfterMs: silence,
        crypto: crypto,
        log: (l) => sink.writeln('juror $l'))
      ..start();
    final startedAt = DateTime.now();
    final presences = [for (final s in signers) RelayPresence(relays: [relay.url], signer: s)];
    final transports = [for (final s in signers) RelayTransport(relays: [relay.url], signer: s, table: spec.id)];
    await Future.wait(transports.map((t) => t.ready));
    final clients = [
      for (var i = 0; i < 4; i++)
        TableClient(
            spec: spec,
            signer: signers[i],
            transport: transports[i],
            clock: WallClock(),
            presence: presences[i],
            silenceAfterMs: silence,
            crypto: crypto),
    ];
    final players = [for (final c in clients) Player(c)];
    for (final c in clients) {
      c.log = (l) => sink.writeln('seat ${c.mySeat} $l');
    }
    for (final c in clients) {
      c.start();
    }
    // The players reach the second hand on their own.
    final atHandOne = Completer<void>();
    late StreamSubscription<void> sub;
    sub = clients[0].changes.listen((_) {
      if (clients[0].game.handNumber >= 1 && !atHandOne.isCompleted) atHandOne.complete();
    });
    await atHandOne.future.timeout(const Duration(minutes: 5), onTimeout: () {
      fail('the players never reached hand 1:\n${clients[0].describe()}');
    });
    sub.cancel();
    expect(juror.online, isTrue, reason: 'called for, the juror came online');
    // The juror was summoned for hand 0 and is being carried forward:
    // it heartbeats throughout, and gets to hand 1 within a minute and
    // a half of the players.
    final following = juror.duty.clients[spec.id];
    expect(following, isNotNull, reason: 'summoned, it follows the table');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (following!.game.handNumber < 1 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(following.game.handNumber, greaterThanOrEqualTo(1),
        reason: 'the juror was carried to hand 1:\n${following.describe()}\nheartbeats ${following.heartbeatsSent}');
    // A heartbeat every five seconds at most, every second while
    // behind: over the whole time since the table started, at least
    // one every ten is proof they never stopped.
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    expect(following.heartbeatsSent, greaterThanOrEqualTo(seconds ~/ 10),
        reason: 'it kept heartbeating while catching up: ${following.heartbeatsSent} in $seconds s');
    for (final p in players) {
      p.stop();
    }
    for (final t in transports) {
      t.close();
    }
    for (final p in presences) {
      p.close();
    }
    for (final c in clients) {
      c.close();
    }
    juror.close();
    await sink.close();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
