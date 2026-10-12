/// A bot seat held by a jury, over real sockets.
///
/// The simulator has this cell several times over, but only with its
/// own presence and its own jurors: the summons goes from one object
/// to another in the same isolate. On a relay it is a sealed event
/// that has to be written, matched and read, and what it carries is
/// what a juror acts on — which jury it was summoned into, and
/// whether that jury is the one the hand's bot seats were dealt to
/// (client.dart, `_firstSummons`). A juror that cannot tell holds a
/// seat it does not make keys for, and the hand stops at them.
///
/// So: three people and a bot at a sealed table on the local relay,
/// and backup jurors with nobody else online to draw from. The
/// bot seat has to end up held, the hand has to be dealt, and the
/// table has to reach the hand after it.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
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

  test('a jury drawn over the relay holds the bot seat, and the hand is dealt to it', () async {
    const silence = 30000;
    final signers = [for (var i = 0; i < 3; i++) FakeSigner('p$i')];
    final spec = TableSpec(id: 'bot-seat-relay', seed: 11, sealed: true, seats: [
      for (final s in signers) HumanSeat(s.publicKey),
      BotSeat(Persona.roster[2]),
    ]);
    // Several backup jurors, not one: a table that needs its bot seats
    // held needs [juryToHoldBots] of them, and with nobody else online
    // there is nothing else to make that up (docs/explanation/live-play.md).
    final bench = [
      for (var i = 0; i < juryToHoldBots; i++)
        LastResortJuror(relays: [relay.url], signer: FakeSigner('bench$i'), silenceAfterMs: silence, crypto: crypto)..start(),
    ];
    final presences = [for (final s in signers) RelayPresence(relays: [relay.url], signer: s)];
    final transports = [for (final s in signers) RelayTransport(relays: [relay.url], signer: s, table: spec.id)];
    await Future.wait(transports.map((t) => t.ready));
    final clients = [
      for (var i = 0; i < signers.length; i++)
        TableClient(
            spec: spec,
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
    // Hand 1, which is the whole of hand 0 having gone through: the
    // jury drawn, the bot seat assigned, its keys made by whoever
    // holds it, the deal sealed and the hand played out.
    final c = clients[0];
    final atHandOne = Completer<void>();
    late StreamSubscription<void> sub;
    sub = c.changes.listen((_) {
      if (c.game.handNumber >= 1 && !atHandOne.isCompleted) atHandOne.complete();
    });
    await atHandOne.future.timeout(const Duration(minutes: 5), onTimeout: () {
      fail('the table never reached hand 1:\n${c.describe()}\n'
          'backup jurors: ${[for (final j in bench) '${j.signer.publicKey.substring(0, 4)} '
              'online ${j.online} serving ${j.duty.serving} '
              '${j.duty.clients[spec.id]?.describe() ?? 'not following'}'].join('\n')}');
    });
    sub.cancel();

    // The bot seat was the jury's, not the table's: every peer names
    // the same juror for it, and that juror is a backup juror.
    final held = c.botHolders(0);
    expect(held.keys, [3], reason: 'the jury held the bot seat: ${c.describe()}');
    final holder = held[3];
    expect([for (final j in bench) j.signer.publicKey], contains(holder));
    for (final other in clients.skip(1)) {
      expect(other.botHolders(0)[3], holder, reason: 'every peer reads the same holder for the seat');
    }
    // And the juror holding it knows it does. This is what a summons
    // carries and a redraw must not: a juror that read the seats off
    // the wrong jury would name a different holder here.
    final following = bench.firstWhere((j) => j.signer.publicKey == holder).duty.clients[spec.id];
    expect(following, isNotNull, reason: 'the holder is following the table');
    expect(following!.botHolders(0)[3], holder, reason: 'the holder agrees it holds the seat:\n${following.describe()}');

    // And the record checks out as far as it goes: hand 0 whole, and
    // hand 1 as much of its deal as is in. Partial, because the table
    // is mid-deal at the moment this reads it — reaching hand 1 is
    // what was waited for, not finishing it.
    final v = verifyRecord(spec, c.record, allowPartial: true, juries: c.juries, crypto: crypto, releases: c.releases);
    expect(v.ok, isTrue, reason: v.reason);

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
    for (final j in bench) {
      j.close();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
